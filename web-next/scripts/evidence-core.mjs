/*
 * Gate logic for scripts/evidence.mjs — the manifest of captures a run owes,
 * the completion check that makes a zero- or partial-PNG success impossible,
 * the run deadline that turns a stall into a diagnosable failure, and the latch
 * that turns a silent exit into a loud one (#976). The manifest and the check
 * are pure like validate-core.mjs / clean-core.mjs; the deadline and the latch
 * are not — they own a timer and a process listener — so both take those
 * collaborators as parameters and stay testable without a real process.
 */

/** Every capture is taken once per theme. */
export const THEMES = ["light", "dark"];

/**
 * The three first-class error surfaces (#753) and the mock-provider triggers
 * that produce them. Lives here so the manifest and the walk name them once.
 */
export const ERROR_SURFACE_CASES = [
	["session-error-provisioning", "Build the importer __mock_provision_error__"],
	["session-error-sandbox-died", "Fix the flaky test __mock_sandbox_died__"],
	["session-error-stream", "Refactor the adapter __mock_stream_error__"],
];

/**
 * Every capture the walk owes, per theme. Declared independently of the walk
 * so a run that dies halfway fails the check instead of passing on what it
 * happened to reach; evidence-core.test.mjs holds this list and the walk's
 * own shot() calls to each other.
 */
export const EXPECTED_CAPTURE_NAMES = [
	"home-empty",
	"session-empty",
	"compose-empty",
	"compose-multiline",
	"session-turn-streaming",
	"compose-disabled",
	"session-turn-midstream",
	"session-turn-final",
	"session-turn-reloaded",
	"session-terminal-drawer",
	"session-turn-failed",
	"session-turn-failed-retried",
	...ERROR_SURFACE_CASES.map(([name]) => name),
	"session-turn-stopping",
	"session-turn-stopped",
	"session-mobile-turn",
	"session-mobile-diff",
	"resume-midturn",
	"resume-catchup",
	"resume-complete",
	"home-populated",
	"sessions-demo",
	"prototype-folio",
];

/** The manifest as filenames: every capture in every theme. */
export function expectedCaptureFiles(
	names = EXPECTED_CAPTURE_NAMES,
	themes = THEMES,
) {
	return names.flatMap((name) => themes.map((theme) => `${name}-${theme}.png`));
}

/** The first 8 bytes of every PNG. A file that lacks them is not a capture. */
export const PNG_SIGNATURE = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);

function hasPNGSignature(header) {
	return (
		header?.length >= PNG_SIGNATURE.length &&
		PNG_SIGNATURE.every((byte, index) => header[index] === byte)
	);
}

/**
 * Captures the run owed but never wrote, wrote empty, or wrote as something
 * that is not a PNG. `captures` maps filename → { size, header }, the header
 * being the file's first bytes; checking the signature rather than only the
 * size means a truncated or half-written screenshot fails the gate too.
 */
export function findMissingCaptures(expected, captures) {
	return expected.flatMap((file) => {
		const capture = captures.get(file);
		if (capture === undefined) return [{ file, reason: "never written" }];
		if (capture.size === 0) return [{ file, reason: "written empty" }];
		if (!hasPNGSignature(capture.header)) {
			return [{ file, reason: "not a PNG" }];
		}
		return [];
	});
}

export function describeMissingCaptures(outputDir, missing, expectedCount) {
	const captured = expectedCount - missing.length;
	const listed = missing.slice(0, 12);
	const elided = missing.length - listed.length;
	return [
		`Evidence run produced ${captured}/${expectedCount} captures in ${outputDir} — the walk did not finish.`,
		...listed.map(({ file, reason }) => `  ${file} — ${reason}`),
		...(elided > 0 ? [`  …and ${elided} more`] : []),
		"A partial walk is not evidence: fix the run rather than uploading what it reached.",
	].join("\n");
}

/**
 * A ref'd timer that does double duty: it keeps the event loop non-empty for
 * the whole run — an empty loop is how the walk used to exit 0 having done
 * nothing (#976) — and it rejects with a diagnosable error when the run
 * outlives its budget. Always cancel it, or it holds the process open.
 */
export function createRunDeadline(
	timeoutMs,
	{ timers = globalThis, envVar = "EVIDENCE_TIMEOUT_MS" } = {},
) {
	let timer;
	const expired = new Promise((_, reject) => {
		timer = timers.setTimeout(
			() =>
				reject(
					new Error(
						`Evidence run exceeded ${timeoutMs}ms without finishing. The last capture logged above is where it stalled; raise ${envVar} if the walk legitimately needs longer.`,
					),
				),
			timeoutMs,
		);
	});
	return { expired, cancel: () => timers.clearTimeout(timer) };
}

/**
 * Last line of defense against a false green. Any exit that reports success
 * without the walk having finished — a silently emptied event loop, a stray
 * process.exit() — is turned red here; Node honors process.exitCode set from
 * inside an 'exit' handler.
 */
export function installCompletionLatch({
	proc = process,
	log = console.error,
} = {}) {
	let completed = false;
	proc.once("exit", (code) => {
		if (completed || code !== 0) return;
		log(
			"Evidence run exited reporting success without finishing the walk and without an error — failing the run rather than letting a silent exit read as a green gate (#976).",
		);
		proc.exitCode = 1;
	});
	return { markCompleted: () => (completed = true) };
}
