#!/usr/bin/env node
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const DEFAULT_QA_HOST = "qa.spaces-preview.cloudcompute.com";
const PREVIEW_COMMENT_MARKER = "<!-- spaces-web-preview -->";

function usage() {
	return [
		"usage: node scripts/preview-alias.mjs (--pr <number> | --url <raw-preview-url>) [--host <host>] [--scope <scope>]",
		"",
		"Assigns the reusable OAuth QA hostname to a deployed Vercel preview.",
	].join("\n");
}

function parseArgs(argv) {
	const args = {
		host: process.env.PREVIEW_QA_ALIAS_HOST ?? DEFAULT_QA_HOST,
		pr: "",
		scope: process.env.VERCEL_SCOPE ?? "",
		url: "",
	};

	for (let i = 0; i < argv.length; i += 1) {
		const arg = argv[i];
		if (arg === "--pr") {
			args.pr = argv[++i] ?? "";
		} else if (arg === "--url") {
			args.url = argv[++i] ?? "";
		} else if (arg === "--host") {
			args.host = argv[++i] ?? "";
		} else if (arg === "--scope") {
			args.scope = argv[++i] ?? "";
		} else if (arg === "--help" || arg === "-h") {
			console.log(usage());
			process.exit(0);
		} else {
			throw new Error(`unknown argument: ${arg}`);
		}
	}

	if (args.pr && args.url)
		throw new Error("pass either --pr or --url, not both");
	if (!args.pr && !args.url) throw new Error("missing --pr or --url");
	if (args.pr && !/^\d+$/.test(args.pr))
		throw new Error("--pr must be a PR number");
	if (!args.host) throw new Error("missing --host");
	return args;
}

async function rawPreviewUrlForPr(pr) {
	const { stdout } = await execFileAsync("gh", [
		"pr",
		"view",
		pr,
		"--json",
		"comments",
	]);
	const data = JSON.parse(stdout);
	const previewComment = [...data.comments]
		.reverse()
		.find((comment) => comment.body?.includes(PREVIEW_COMMENT_MARKER));
	if (!previewComment) {
		throw new Error(`PR #${pr} does not have a spaces web preview comment`);
	}

	const match = previewComment.body.match(
		/- Raw deployment:\s+(https:\/\/\S+)/,
	);
	if (!match) {
		throw new Error(
			`PR #${pr} preview comment does not include a raw deployment URL`,
		);
	}
	return match[1];
}

async function main() {
	const args = parseArgs(process.argv.slice(2));
	const rawUrl = args.url || (await rawPreviewUrlForPr(args.pr));
	new URL(rawUrl);

	console.log(`Assigning https://${args.host} to ${rawUrl}`);
	const aliasArgs = ["--yes", "vercel@51", "alias", "set", rawUrl, args.host];
	if (args.scope) aliasArgs.push("--scope", args.scope);

	await execFileAsync("npx", aliasArgs, {
		stdio: "inherit",
	});
	console.log(`Preview QA URL: https://${args.host}`);
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : String(error));
	process.exit(1);
});
