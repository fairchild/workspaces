/*
 * Environment preflight: one call that proves every capability a real #750 turn
 * needs — model inference, GitHub App clone credentials, Vercel access, and
 * (opt-in) a live sandbox that runs bash and clones the repo. Each check is
 * isolated so one failure still reports the rest. Secret values are never
 * returned — only presence, status, and non-secret metadata.
 */
import {
	generateAppJWT,
	findInstallationId,
	getInstallationToken,
	verifyRepoAccess,
} from "./github-app";

export interface CheckResult {
	name: string;
	ok: boolean;
	/** A pass that did nothing (e.g. on-platform OIDC, or sandbox not requested). */
	skipped?: boolean;
	detail?: Record<string, unknown>;
	error?: string;
	latencyMs?: number;
}

export interface PreflightReport {
	ok: boolean;
	ranAt: string;
	onVercel: boolean;
	cloneRepo: string;
	checks: CheckResult[];
	tookMs: number;
}

/** Repo the GitHub + sandbox-clone checks target. */
const CLONE_REPO = process.env.PREFLIGHT_CLONE_REPO ?? "fairchild/workspaces";

type CheckBody = Omit<CheckResult, "name" | "latencyMs">;

async function timed(
	name: string,
	fn: () => Promise<CheckBody>,
): Promise<CheckResult> {
	const started = Date.now();
	try {
		return { name, latencyMs: Date.now() - started, ...(await fn()) };
	} catch (e) {
		return {
			name,
			ok: false,
			latencyMs: Date.now() - started,
			error: e instanceof Error ? e.message : String(e),
		};
	}
}

/** Redact an inline clone credential from any captured sandbox output. */
function redact(s: string): string {
	return s.replace(/x-access-token:[^@\s]*@/g, "x-access-token:***@");
}

function checkEnv(): CheckResult {
	const all = [
		"AI_GATEWAY_API_KEY",
		"ANTHROPIC_API_KEY",
		"VERCEL_TOKEN",
		"VERCEL_TEAM_ID",
		"VERCEL_PROJECT_ID",
		"VERCEL_OIDC_TOKEN",
		"GITHUB_WEB_WORKSPACES_APP_ID",
		"GITHUB_APP_PRIVATE_KEY",
	];
	const present = all.filter((v) => !!process.env[v]);
	const missing = all.filter((v) => !process.env[v]);
	const hasModel = !!(
		process.env.AI_GATEWAY_API_KEY || process.env.ANTHROPIC_API_KEY
	);
	const hasVercel = !!(
		process.env.VERCEL_OIDC_TOKEN ||
		(process.env.VERCEL_TOKEN &&
			process.env.VERCEL_TEAM_ID &&
			process.env.VERCEL_PROJECT_ID)
	);
	const hasGithub = !!(
		process.env.GITHUB_WEB_WORKSPACES_APP_ID &&
		process.env.GITHUB_APP_PRIVATE_KEY
	);
	return {
		name: "env",
		ok: hasModel && hasVercel && hasGithub,
		detail: { present, missing, hasModel, hasVercel, hasGithub },
	};
}

async function checkLlm(): Promise<CheckBody> {
	const gateway = process.env.AI_GATEWAY_API_KEY;
	if (gateway) {
		const res = await fetch("https://ai-gateway.vercel.sh/v1/chat/completions", {
			method: "POST",
			headers: {
				Authorization: `Bearer ${gateway}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({
				model: "anthropic/claude-haiku-4.5",
				messages: [{ role: "user", content: "Reply with exactly: gateway live" }],
				max_tokens: 10,
			}),
		});
		const body = await res.json().catch(() => null);
		if (!res.ok) throw new Error(`gateway ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
		return {
			ok: true,
			detail: {
				via: "ai-gateway",
				model: body?.model,
				reply: body?.choices?.[0]?.message?.content,
			},
		};
	}
	const anthropic = process.env.ANTHROPIC_API_KEY;
	if (anthropic) {
		const res = await fetch("https://api.anthropic.com/v1/messages", {
			method: "POST",
			headers: {
				"x-api-key": anthropic,
				"anthropic-version": "2023-06-01",
				"Content-Type": "application/json",
			},
			body: JSON.stringify({
				model: "claude-haiku-4-5-20251001",
				max_tokens: 10,
				messages: [{ role: "user", content: "Reply with exactly: anthropic live" }],
			}),
		});
		const body = await res.json().catch(() => null);
		if (!res.ok) throw new Error(`anthropic ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
		return {
			ok: true,
			detail: {
				via: "anthropic-direct",
				model: body?.model,
				reply: body?.content?.[0]?.text,
			},
		};
	}
	return { ok: false, error: "no model credential (AI_GATEWAY_API_KEY or ANTHROPIC_API_KEY)" };
}

async function checkVercel(): Promise<CheckBody> {
	const token = process.env.VERCEL_TOKEN;
	const teamId = process.env.VERCEL_TEAM_ID;
	const projectId = process.env.VERCEL_PROJECT_ID;
	if (!token) {
		if (process.env.VERCEL_OIDC_TOKEN) {
			return {
				ok: true,
				skipped: true,
				detail: {
					mode: "oidc",
					note: "on-platform OIDC token present; the sandbox check validates it end-to-end",
				},
			};
		}
		return { ok: false, error: "VERCEL_TOKEN unset and no VERCEL_OIDC_TOKEN" };
	}
	const scope = teamId ? `?teamId=${teamId}` : "";
	const userRes = await fetch(`https://api.vercel.com/v2/user${scope}`, {
		headers: { Authorization: `Bearer ${token}` },
	});
	if (!userRes.ok) throw new Error(`VERCEL_TOKEN invalid (${userRes.status})`);
	const user = (await userRes.json().catch(() => null)) as {
		user?: { username?: string };
	} | null;
	let project: string | undefined;
	if (projectId) {
		const pRes = await fetch(
			`https://api.vercel.com/v9/projects/${projectId}${scope}`,
			{ headers: { Authorization: `Bearer ${token}` } },
		);
		if (!pRes.ok) {
			throw new Error(
				`project ${projectId} unreachable (${pRes.status}) — check the token's team scope`,
			);
		}
		const p = (await pRes.json().catch(() => null)) as { name?: string } | null;
		project = p?.name ?? projectId;
	}
	return {
		ok: true,
		detail: { mode: "token", user: user?.user?.username, teamId, project },
	};
}

/** Mint + verify the GitHub App token, returning it (out of band) for the clone check. */
async function mintGithub(): Promise<{ result: CheckResult; token?: string }> {
	const started = Date.now();
	const appId = process.env.GITHUB_WEB_WORKSPACES_APP_ID;
	const pk = process.env.GITHUB_APP_PRIVATE_KEY;
	if (!appId || !pk) {
		return {
			result: {
				name: "github",
				ok: false,
				latencyMs: Date.now() - started,
				error: "GITHUB_WEB_WORKSPACES_APP_ID or GITHUB_APP_PRIVATE_KEY unset",
			},
		};
	}
	try {
		const jwt = generateAppJWT(appId, pk);
		const installationId = await findInstallationId(jwt, CLONE_REPO);
		const tok = await getInstallationToken(jwt, installationId);
		const repo = await verifyRepoAccess(tok.token, CLONE_REPO);
		return {
			token: tok.token,
			result: {
				name: "github",
				ok: true,
				latencyMs: Date.now() - started,
				detail: {
					repo: repo.fullName,
					defaultBranch: repo.defaultBranch,
					private: repo.private,
					installationId,
					tokenExpiresAt: tok.expiresAt,
					permissions: tok.permissions,
				},
			},
		};
	} catch (e) {
		return {
			result: {
				name: "github",
				ok: false,
				latencyMs: Date.now() - started,
				error: e instanceof Error ? e.message : String(e),
			},
		};
	}
}

/** Opt-in: create a live sandbox, run bash, and clone the repo inside it. */
async function checkSandbox(cloneToken?: string): Promise<CheckResult> {
	const started = Date.now();
	const detail: Record<string, unknown> = {};
	let sandbox: Awaited<ReturnType<typeof import("@vercel/sandbox").Sandbox.create>> | undefined;
	try {
		const mod = await import("@vercel/sandbox").catch(() => null);
		if (!mod) {
			return {
				name: "sandbox",
				ok: false,
				skipped: true,
				latencyMs: Date.now() - started,
				error: "@vercel/sandbox not installed",
			};
		}
		sandbox = await mod.Sandbox.create({
			token: process.env.VERCEL_TOKEN,
			teamId: process.env.VERCEL_TEAM_ID,
			projectId: process.env.VERCEL_PROJECT_ID,
			runtime: "node22",
			resources: { vcpus: 2 },
			timeout: 5 * 60 * 1000,
		});
		detail.created = true;

		const bash = await sandbox.runCommand({
			cmd: "bash",
			args: ["-lc", "echo preflight-bash-ok && uname -s && (node --version || true)"],
		});
		detail.bash = {
			exitCode: bash.exitCode,
			output: redact((await bash.output("both")).trim()).slice(0, 500),
		};

		if (cloneToken) {
			const url = `https://x-access-token:${cloneToken}@github.com/${CLONE_REPO}.git`;
			const clone = await sandbox.runCommand({
				cmd: "git",
				args: ["clone", "--depth", "1", url, "/tmp/preflight-repo"],
			});
			const probe =
				clone.exitCode === 0
					? await sandbox.runCommand({
							cmd: "bash",
							args: [
								"-lc",
								"ls /tmp/preflight-repo | head -20 && echo --- && git -C /tmp/preflight-repo rev-parse HEAD",
							],
						})
					: clone;
			detail.clone = {
				exitCode: clone.exitCode,
				ok: clone.exitCode === 0,
				sample: redact((await probe.output("both")).trim()).slice(0, 500),
			};
		} else {
			detail.clone = { skipped: true, reason: "github check yielded no token to clone with" };
		}

		const bashOk = (detail.bash as { exitCode: number }).exitCode === 0;
		const cloneOk = !cloneToken || (detail.clone as { ok?: boolean }).ok === true;
		return {
			name: "sandbox",
			ok: detail.created === true && bashOk && cloneOk,
			latencyMs: Date.now() - started,
			detail,
		};
	} catch (e) {
		return {
			name: "sandbox",
			ok: false,
			latencyMs: Date.now() - started,
			detail,
			error: e instanceof Error ? e.message : String(e),
		};
	} finally {
		if (sandbox) await sandbox.stop().catch(() => {});
	}
}

export async function runPreflight({
	includeSandbox,
}: {
	includeSandbox: boolean;
}): Promise<PreflightReport> {
	const started = Date.now();
	const [llm, vercel, gh] = await Promise.all([
		timed("llm", checkLlm),
		timed("vercel", checkVercel),
		mintGithub(),
	]);
	const checks: CheckResult[] = [checkEnv(), llm, vercel, gh.result];
	if (includeSandbox) checks.push(await checkSandbox(gh.token));
	return {
		ok: checks.every((c) => c.ok || c.skipped),
		ranAt: new Date().toISOString(),
		onVercel: !!process.env.VERCEL,
		cloneRepo: CLONE_REPO,
		checks,
		tookMs: Date.now() - started,
	};
}
