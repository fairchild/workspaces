/*
 * Pure logic for the #818 real-agentic-turn validation stage: the probe
 * prompt/title, the gate classifiers (preflight, create), the event-log
 * assertions, the teardown/leak semantics, and the orchestrating
 * `runRealTurnProbe` — which takes an injected API client so the teardown
 * guarantee (delete the probe session even when an assertion throws) is
 * unit-testable without a network. I/O lives in real-turn.mjs.
 */

/** One probe file the scripted turn writes; nonce makes each run verifiable. */
export const PROBE_FILE = "VALIDATION-PROBE.md";

export function buildProbeTitle(nowIso) {
	return `validation: real-turn probe ${nowIso}`;
}

/**
 * The scripted coding change, kept tiny (one file write + one cat) so a
 * scheduled run costs cents: the nonce in the file content is what the log
 * assertions later look for in tool output/diffs, proving the change actually
 * landed in the sandbox workspace rather than being narrated.
 */
export function buildProbePrompt(nonce) {
	return [
		`Create a file named ${PROBE_FILE} at the repository root containing exactly one line:`,
		"",
		`real-turn probe ${nonce}`,
		"",
		`Then run \`cat ${PROBE_FILE}\` to show its content. Do not commit, push, or open a pull request. Do not do anything else.`,
	].join("\n");
}

/** Read-only host probe: exercises local Claude + workspace + durable resume. */
export function buildHostProbePrompt(nonce) {
	return [
		"Read package.json from the repository root and report its package name.",
		`End your answer with exactly: host-turn probe ${nonce}`,
		"Do not edit files, run commands, commit, push, or open a pull request.",
	].join("\n");
}

/**
 * Interprets `/api/diag/preflight` (cheap, no sandbox spin-up) as the stage's
 * runtime-credential gate. Only a failing env-presence check is a *skip* — a
 * target that was never provisioned for the real runtime. Any other failing
 * check (model inference, GitHub App, Vercel access) means the target claims
 * the credentials but they don't work: a real finding, reported as `fail`.
 */
export function classifyPreflightGate(probe) {
	if (probe.status === 401 || probe.status === 403) {
		return { skip: true, reason: "validation session expired — re-seed" };
	}
	if (probe.status === 404) {
		return {
			skip: true,
			reason: "target has no /api/diag/preflight — deployment predates the real runtime",
		};
	}
	if (probe.status === 200) {
		return { ok: true, provider: probe.body?.provider ?? "vercel" };
	}
	const checks = Array.isArray(probe.body?.checks) ? probe.body.checks : [];
	const failing = checks.filter((c) => c.ok === false);
	const envCheck = failing.find((c) => /env/i.test(String(c.name)));
	if (probe.status === 503 && envCheck) {
		// Missing credentials cascade into the dependent checks; the env check
		// is the root cause worth naming.
		return {
			skip: true,
			reason: `target runtime not provisioned: ${envCheck.error ?? JSON.stringify(envCheck.detail ?? {})}`,
		};
	}
	return {
		fail: true,
		detail:
			failing.length > 0
				? `preflight failing checks: ${failing.map((c) => `${c.name}: ${c.error ?? "failed"}`).join("; ")}`
				: `preflight → HTTP ${probe.status}`,
	};
}

/**
 * Interprets the create-session response as a gate. A 404/405 means the
 * target deployment predates these routes (web-next deploys are manual, so
 * prod can lag main) — a deployment-gap skip, not an app failure. Auth
 * bounces skip with the shared expired-session wording.
 */
export function classifyCreateGate(probe) {
	if (probe.status === 404 || probe.status === 405) {
		return {
			skip: true,
			reason: "target has no POST /api/sessions — deploy a revision with the #818 probe routes",
		};
	}
	if (probe.status === 401 || probe.status === 403) {
		return { skip: true, reason: "validation session expired — re-seed" };
	}
	return { ok: true };
}

function check(id, pass, detail) {
	return { id, status: pass ? "pass" : "fail", detail };
}

/** The created session must start on the app's DEFAULT model (assertion 1). */
export function checkDefaultModel(created, defaultModel) {
	return check(
		"session_default_model",
		created?.model === defaultModel,
		`created session model ${JSON.stringify(created?.model)} (default: ${defaultModel})`,
	);
}

const isAssistant = (e) => e.role === "assistant";

/**
 * The event-log assertions over the durable projection (GET
 * /api/sessions/[id] events, StreamChunk-shaped). `events` may be a partial
 * log when the poll deadline passed — every assertion then reports what it
 * saw, so a hung turn fails with detail instead of a bare timeout.
 */
export function evaluateRealTurnEvents(events, nonce, { deadlineMs } = {}) {
	const checks = [];
	const assistant = events.filter(isAssistant);

	const statuses = assistant.filter((e) => e.kind === "status");
	const bootStatus = statuses.find((e) =>
		/booting claude code in sandbox|resuming session/i.test(e.content ?? ""),
	);
	checks.push(
		check(
			"sandbox_created",
			!!bootStatus,
			bootStatus
				? `sandbox lifecycle observed: ${JSON.stringify(bootStatus.content)}`
				: `no sandbox boot/resume status event (saw: ${statuses.map((e) => JSON.stringify(e.content)).join(", ") || "none"})`,
		),
	);

	const streamed = assistant.filter(
		(e) => (e.kind === "text" || e.kind === "reasoning") && (e.content ?? "").length > 0,
	);
	checks.push(
		check(
			"streamed_output",
			streamed.length > 0,
			`${streamed.length} text/reasoning event(s) in the durable log`,
		),
	);

	const toolUses = assistant.filter((e) => e.kind === "tool_use");
	const resultWithNonce = assistant.find(
		(e) => e.kind === "tool_result" && (e.content ?? "").includes(nonce),
	);
	const diffWithNonce = assistant.find(
		(e) =>
			e.kind === "tool_result" &&
			e.metadata?.diff &&
			JSON.stringify(e.metadata.diff).includes(nonce),
	);
	const inputWithFile = toolUses.find((e) =>
		JSON.stringify(e.metadata?.input ?? {}).includes(PROBE_FILE),
	);
	checks.push(
		check(
			"coding_change_landed",
			!!(resultWithNonce || diffWithNonce),
			resultWithNonce
				? `tool output carries the nonce (via ${toolUses.length} tool call(s))`
				: diffWithNonce
					? "workspace diff carries the nonce"
					: `no tool output or diff contains the nonce (${toolUses.length} tool call(s)${inputWithFile ? `, an input names ${PROBE_FILE}` : ""})`,
		),
	);

	const errors = assistant.filter((e) => e.kind === "error");
	checks.push(
		check(
			"no_turn_errors",
			errors.length === 0,
			errors.length === 0
				? "no error events"
				: `error event(s): ${errors.map((e) => JSON.stringify((e.content ?? "").slice(0, 200))).join("; ")}`,
		),
	);

	const done = assistant.find((e) => e.kind === "done");
	const aborted = done?.metadata?.aborted === true;
	checks.push(
		check(
			"turn_done",
			!!done && !aborted,
			done
				? aborted
					? "turn closed as aborted (synthesized terminal after a failure)"
					: `terminal done arrived (durationMs=${done.metadata?.durationMs ?? "?"})`
				: `no terminal done${deadlineMs ? ` within ${Math.round(deadlineMs / 1000)}s — the in-flight sandbox will expire at its own lifetime cap` : ""}`,
		),
	);

	return checks;
}

/** Host turn contract: local lifecycle, read-only tool use, durable completion. */
export function evaluateHostTurnEvents(events, nonce, { deadlineMs } = {}) {
	const assistant = events.filter(isAssistant);
	const statuses = assistant.filter((event) => event.kind === "status");
	const localLifecycle = statuses.some((event) =>
		/preparing host workspace|starting local claude code/i.test(event.content ?? ""),
	);
	const toolUses = assistant.filter((event) => event.kind === "tool_use");
	const readUsed = toolUses.some((event) => {
		const name = event.metadata?.toolName ?? event.content;
		return String(name ?? "").toLowerCase() === "read";
	});
	const streamed = assistant.filter(
		(event) =>
			(event.kind === "text" || event.kind === "reasoning") &&
			(event.content ?? "").length > 0,
	);
	const marker = streamed.some((event) =>
		(event.content ?? "").includes(`host-turn probe ${nonce}`),
	);
	const errors = assistant.filter((event) => event.kind === "error");
	const done = assistant.find((event) => event.kind === "done");
	const aborted = done?.metadata?.aborted === true;
	return [
		check(
			"host_lifecycle_started",
			localLifecycle,
			localLifecycle ? "host workspace/Claude lifecycle observed" : "no host lifecycle status event",
		),
		check(
			"read_only_tool_used",
			readUsed,
			readUsed ? "Read tool observed" : `no Read tool among ${toolUses.length} tool call(s)`,
		),
		check(
			"streamed_output",
			streamed.length > 0 && marker,
			`${streamed.length} text/reasoning event(s); marker ${marker ? "observed" : "missing"}`,
		),
		check(
			"no_turn_errors",
			errors.length === 0,
			errors.length === 0
				? "no error events"
				: `error event(s): ${errors.map((event) => JSON.stringify((event.content ?? "").slice(0, 200))).join("; ")}`,
		),
		check(
			"turn_done",
			!!done && !aborted,
			done
				? aborted
					? "turn closed as aborted"
					: `terminal done arrived (durationMs=${done.metadata?.durationMs ?? "?"})`
				: `no terminal done${deadlineMs ? ` within ${Math.round(deadlineMs / 1000)}s` : ""}`,
		),
	];
}

/**
 * The no-leak verdict from the DELETE response (assertion 6). `state` is what
 * the probe observed: `turnCompleted` (a terminal done landed) and `parked`
 * (the session held a resume handle afterward). A turn that never closed can
 * have a live UNPARKED sandbox no disposition can vouch for (nothing was
 * persisted to find it by — codex finding, gpt-5.5 xhigh), so only a
 * completed turn can pass; then a parked session must yield a stopped (or
 * already-expired) sandbox and an unparked one has nothing to stop. A 502
 * (`stop-failed`/`unreachable`) is the leak — a live sandbox we could neither
 * stop nor disprove — and any other non-2xx leaves the probe session behind,
 * which is litter and equally a failure.
 */
export function classifyTeardown(state, del) {
	const { parked, turnCompleted, provider = "vercel" } = state;
	if (del.status === 200 && del.body?.deleted === true) {
		const sandbox = del.body.sandbox;
		if (!turnCompleted) {
			return check(
				"no_leaked_sandbox",
				false,
				`session deleted but the turn never closed — an unparked live sandbox may persist until its lifetime cap (disposition: ${sandbox})`,
			);
		}
		const ok =
			provider === "host"
				? sandbox === "none"
				: parked
					? sandbox === "stopped" || sandbox === "expired"
					: sandbox === "none" || sandbox === "stopped" || sandbox === "expired";
		return check(
			"no_leaked_sandbox",
			ok,
			`session deleted; sandbox disposition: ${sandbox}${parked ? " (session was parked)" : ""}`,
		);
	}
	if (del.status === 502 && (del.body?.sandbox === "stop-failed" || del.body?.sandbox === "unreachable")) {
		return check(
			"no_leaked_sandbox",
			false,
			`LEAK: live sandbox could not be released — ${del.body.error ?? "no detail"} (session retained for retry)`,
		);
	}
	return check(
		"no_leaked_sandbox",
		false,
		`probe session not deleted: DELETE → HTTP ${del.status} ${JSON.stringify(del.body ?? {}).slice(0, 200)}`,
	);
}

const hasDone = (events) =>
	events.some((e) => e.role === "assistant" && e.kind === "done");

/**
 * Orchestrates one probe: create (default model) → send the scripted turn →
 * poll the durable log until its terminal `done` (or the deadline) → assert →
 * ALWAYS tear down. The client is injected:
 *   createSession({title, provider}) / sendChat(id, text) /
 *   getSession(id) / deleteSession(id)
 * each resolving `{ status, body }` (body JSON-parsed or undefined) and never
 * throwing for HTTP errors. Teardown runs in a `finally`, so a thrown
 * assertion or client fault can't leak the probe session; the teardown check
 * is appended even on that path so the report shows what happened to it.
 */
async function runProviderTurnProbe(client, options, specification) {
	const {
		nonce,
		defaultModel,
		nowIso = new Date().toISOString(),
		deadlineMs = 480_000,
		pollMs = 3_000,
		sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
		now = Date.now,
	} = options;

	const created = await client.createSession({
		title: buildProbeTitle(nowIso),
		provider: specification.provider,
	});
	const gate = classifyCreateGate(created);
	if (gate.skip) return { status: "skip", reason: gate.reason };

	const checks = [];
	if (created.status !== 201 || !created.body?.id) {
		// A status-0 create is a client-side fault; the create may still have
		// landed server-side, so name the possible litter instead of implying
		// there is nothing to clean (codex finding, gpt-5.5 xhigh).
		const litterNote =
			created.status === 0
				? " (request failed client-side — if the create landed anyway, a probe-titled session may remain)"
				: "";
		return {
			status: "run",
			checks: [
				check(
					"session_created",
					false,
					`POST /api/sessions → HTTP ${created.status} ${JSON.stringify(created.body ?? {}).slice(0, 200)}${litterNote}`,
				),
			],
		};
	}
	const sessionId = created.body.id;
	checks.push(check("session_created", true, `probe session ${sessionId}`));
	checks.push(checkDefaultModel(created.body, defaultModel));

	let parked = false;
	let turnCompleted = false;
	let aborted = false;
	try {
		const chat = await client.sendChat(sessionId, specification.prompt(nonce));
		if (chat.status !== 200) {
			checks.push(
				check(
					"turn_started",
					false,
					`POST chat → HTTP ${chat.status} ${JSON.stringify(chat.body ?? {}).slice(0, 200)}`,
				),
			);
			aborted = true;
			return { status: "run", checks };
		}
		checks.push(check("turn_started", true, "chat accepted, turn streaming"));

		let events = [];
		const deadline = now() + deadlineMs;
		while (now() < deadline) {
			const res = await client.getSession(sessionId);
			if (res.status === 200 && Array.isArray(res.body?.events)) {
				events = res.body.events;
				if (hasDone(events)) {
					turnCompleted = true;
					parked = res.body.session?.parked === true;
					break;
				}
			}
			await sleep(pollMs);
		}
		checks.push(...specification.evaluate(events, nonce, { deadlineMs }));
		if (specification.requireResume) {
			checks.push(
				check(
					"resume_handle_persisted",
					turnCompleted && parked,
					turnCompleted
						? parked
							? "completed host turn retained a durable resume handle"
							: "completed host turn did not retain a resume handle"
						: "turn did not complete, so no resume handle could be verified",
				),
			);
		}
	} catch (error) {
		// Never rethrow: an escaped client fault would otherwise discard every
		// accumulated check — including the teardown verdict below — from the
		// stage report (codex finding, gpt-5.5 xhigh).
		checks.push(
			check("probe_error", false, error instanceof Error ? error.message : String(error)),
		);
	} finally {
		let del;
		try {
			del = await client.deleteSession(sessionId);
		} catch (error) {
			del = { status: 0, body: { error: String(error) } };
		}
		// A probe aborted before its turn ever started has no turn to hold
		// against the teardown — only the delete itself is asserted.
		checks.push(
			classifyTeardown(
				{
					parked,
					turnCompleted: turnCompleted || aborted,
					provider: specification.provider,
				},
				del,
			),
		);
	}
	return { status: "run", checks };
}

export async function runRealTurnProbe(client, options) {
	return runProviderTurnProbe(client, options, {
		provider: "vercel",
		prompt: buildProbePrompt,
		evaluate: evaluateRealTurnEvents,
		requireResume: false,
	});
}

export async function runHostTurnProbe(client, options) {
	return runProviderTurnProbe(client, options, {
		provider: "host",
		prompt: buildHostProbePrompt,
		evaluate: evaluateHostTurnEvents,
		requireResume: true,
	});
}
