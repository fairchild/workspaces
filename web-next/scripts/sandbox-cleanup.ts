/*
 * Deletes leftover harness session sandboxes left running by local drive-turn
 * smoke runs (they park with detach() and live until their timeout, costing
 * money). Pass sandbox names, or a name prefix to match. Not part of the app.
 *
 *   node --env-file=.env.local --import tsx scripts/sandbox-cleanup.ts <name...>
 *   node --env-file=.env.local --import tsx scripts/sandbox-cleanup.ts ai-sdk-harness-session-local-drive
 */
import { Sandbox } from "@vercel/sandbox";

// Sandbox.get is scoped by credentials; pass them explicitly (name-only 404s
// against a team-scoped sandbox, the same gap the provider's resume shim fixes).
const creds = {
	token: process.env.VERCEL_TOKEN,
	teamId: process.env.VERCEL_TEAM_ID,
	projectId: process.env.VERCEL_PROJECT_ID,
};

async function main() {
	const names = process.argv.slice(2);
	if (names.length === 0) {
		console.log("usage: sandbox-cleanup.ts <sandbox-name-or-exact-name>…");
		return;
	}
	for (const name of names) {
		try {
			const sandbox = await Sandbox.get({ name, ...creds } as never);
			await sandbox.stop().catch(() => {});
			await sandbox.delete();
			console.log(`deleted ${name}`);
		} catch (err) {
			console.log(`skip ${name}: ${(err as Error)?.message ?? err}`);
		}
	}
}

main().catch((err) => {
	console.error("fatal:", err);
	process.exit(1);
});
