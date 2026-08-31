/*
 * Owner-local production server entrypoint. It builds when needed, mints the
 * local sign-in token under WEB_NEXT_DATA_DIR, prints the bearer URL, then
 * starts Next in WEB_NEXT_LOCAL_MODE with the token exported for middleware.
 */
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	ensureLocalSignInToken,
	localSignInUrl,
	localTokenPath,
} from "../src/lib/auth/local-token";
import {
	assertAuthModeConfig,
	parseExtraLocalOrigins,
} from "../src/lib/auth/config";
import { parseDotEnv } from "../src/lib/env/parse-dotenv";

const WEB_NEXT_ROOT = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);

function run(command: string, args: string[], env: NodeJS.ProcessEnv): Promise<void> {
	return new Promise((resolve, reject) => {
		const child = spawn(command, args, {
			cwd: WEB_NEXT_ROOT,
			stdio: "inherit",
			env,
		});
		child.on("exit", (code) => {
			if (code === 0) resolve();
			else reject(new Error(`${command} ${args.join(" ")} exited ${code ?? "unknown"}`));
		});
		child.on("error", reject);
	});
}

function loadDotEnvLocal(): void {
	const file = path.join(WEB_NEXT_ROOT, ".env.local");
	if (!existsSync(file)) return;
	// Parse with multi-line-quote awareness: a GitHub App key is a multi-line
	// PEM, and a line-by-line splitter truncates it to its BEGIN header (which
	// then fails crypto.sign). Preserve the pre-set-wins precedence so an
	// explicit process env still overrides the file.
	for (const [key, value] of Object.entries(parseDotEnv(readFileSync(file, "utf8")))) {
		if (process.env[key] === undefined) process.env[key] = value;
	}
}

loadDotEnvLocal();

async function main(): Promise<void> {
	const port = process.env.PORT ?? process.env.E2E_PORT ?? "3100";
	const localEnv = {
		...process.env,
		WEB_NEXT_LOCAL_MODE: "1",
	};

	assertAuthModeConfig(localEnv);

	if (!existsSync(path.join(WEB_NEXT_ROOT, ".next", "BUILD_ID"))) {
		await run("pnpm", ["run", "build"], {
			...process.env,
			WEB_NEXT_LOCAL_MODE: "",
		});
	}

	const token = ensureLocalSignInToken(localEnv);
	const serverEnv = {
		...localEnv,
		NODE_ENV: "production" as const,
		WEB_NEXT_LOCAL_TOKEN: token,
	};

	console.log(`Local sign-in: ${localSignInUrl(port, token)}`);
	console.log(`Local token: ${localTokenPath(localEnv)}`);
	const extraOrigins = parseExtraLocalOrigins(serverEnv);
	if (extraOrigins.size === 0) {
		console.log("Local mode accepts only localhost, 127.0.0.1, or ::1 Host headers.");
	} else {
		for (const origin of extraOrigins) {
			const proxyUrl = new URL("/sign-in", origin);
			proxyUrl.searchParams.set("token", token);
			console.log(`Proxy sign-in: ${proxyUrl}`);
		}
		console.log(
			"Local mode accepts loopback Host headers plus WEB_NEXT_EXTRA_LOCAL_ORIGINS (exact match).",
		);
	}

	await run(
		"pnpm",
		["exec", "next", "start", "-H", "127.0.0.1", "--port", port],
		serverEnv,
	);
}

void main();
