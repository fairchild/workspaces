/*
 * Provider-aware environment preflight. Vercel targets prove model, GitHub
 * App, Vercel, and optional sandbox access; host targets prove the local
 * Claude binary, git, and a writable owned-workspace root. Inactive-provider
 * checks remain visible as informational skips, never as false failures.
 */
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdir, mkdtemp, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import {
	curatedClaudeEnv,
	resolveClaudeBinary,
} from "@/lib/agent-runtime/host-provider";
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
	provider: string;
	cloneRepo: string;
	checks: CheckResult[];
	tookMs: number;
}

/** Repo the GitHub + sandbox-clone checks target. */
function cloneRepo(env: NodeJS.ProcessEnv): string {
	return env.PREFLIGHT_CLONE_REPO ?? "fairchild/workspaces";
}

type CheckBody = Omit<CheckResult, "name" | "latencyMs">;

type VersionProbe = (
	command: string,
	env: NodeJS.ProcessEnv,
) => Promise<string>;

interface HostPreflightDependencies {
	resolveClaude?: typeof resolveClaudeBinary;
	version?: VersionProbe;
}

async function timed(
	name: string,
	fn: () => Promise<CheckBody>,
): Promise<CheckResult> {
	const started = Date.now();
	try {
		const result = await fn();
		return { name, latencyMs: Date.now() - started, ...result };
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

function checkEnv(env: NodeJS.ProcessEnv): CheckResult {
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
	const present = all.filter((v) => !!env[v]);
	const missing = all.filter((v) => !env[v]);
	const hasModel = !!(
		env.AI_GATEWAY_API_KEY || env.ANTHROPIC_API_KEY
	);
	const hasVercel = !!(
		env.VERCEL_OIDC_TOKEN ||
		(env.VERCEL_TOKEN && env.VERCEL_TEAM_ID && env.VERCEL_PROJECT_ID)
	);
	const hasGithub = !!(
		env.GITHUB_WEB_WORKSPACES_APP_ID && env.GITHUB_APP_PRIVATE_KEY
	);
	return {
		name: "env",
		ok: hasModel && hasVercel && hasGithub,
		detail: { present, missing, hasModel, hasVercel, hasGithub },
	};
}

function informational(name: string, activeProvider: string): CheckResult {
	return {
		name,
		ok: true,
		skipped: true,
		detail: {
			informational: true,
			reason: `inactive for ${activeProvider} compute provider`,
		},
	};
}

function defaultVersionProbe(
	command: string,
	env: NodeJS.ProcessEnv,
): Promise<string> {
	return new Promise((resolveProbe, rejectProbe) => {
		execFile(
			command,
			["--version"],
			{
				encoding: "utf8",
				env,
				timeout: 10_000,
			},
			(error, stdout) => {
				if (error) rejectProbe(error);
				else resolveProbe(stdout.trim());
			},
		);
	});
}

/** Host-provider readiness without exposing credentials or touching user repos. */
export async function checkHostProvider(
	env: NodeJS.ProcessEnv = process.env,
	dependencies: HostPreflightDependencies = {},
): Promise<CheckResult[]> {
	const resolveBinary = dependencies.resolveClaude ?? resolveClaudeBinary;
	const version = dependencies.version ?? defaultVersionProbe;
	const claude = await timed("host:claude", async () => {
		const binary = await resolveBinary(env);
		if (typeof binary !== "string") {
			return { ok: false, error: binary.message };
		}
		return {
			ok: true,
			detail: {
				binary,
				version: await version(binary, curatedClaudeEnv(env)),
			},
		};
	});
	const git = await timed("host:git", async () => ({
		ok: true,
		detail: {
			version: await version("git", curatedClaudeEnv(env)),
		},
	}));
	const workspace = await timed("host:workspace", async () => {
		const configured = env.WEB_NEXT_HOST_WORKSPACE_ROOT?.trim();
		if (!configured) {
			return {
				ok: false,
				error: "WEB_NEXT_HOST_WORKSPACE_ROOT unset",
			};
		}
		const root = resolve(configured);
		await mkdir(root, { recursive: true });
		await access(root, constants.R_OK | constants.W_OK | constants.X_OK);
		const probe = await mkdtemp(join(root, ".preflight-"));
		await rm(probe, { recursive: true, force: true });
		return { ok: true, detail: { root, writable: true } };
	});
	return [claude, git, workspace];
}

async function checkLlm(env: NodeJS.ProcessEnv): Promise<CheckBody> {
	const gateway = env.AI_GATEWAY_API_KEY;
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
	const anthropic = env.ANTHROPIC_API_KEY;
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

async function checkVercel(env: NodeJS.ProcessEnv): Promise<CheckBody> {
	const token = env.VERCEL_TOKEN;
	const teamId = env.VERCEL_TEAM_ID;
	const projectId = env.VERCEL_PROJECT_ID;
	if (!token) {
		if (env.VERCEL_OIDC_TOKEN) {
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
async function mintGithub(
	env: NodeJS.ProcessEnv,
	repo: string,
): Promise<{ result: CheckResult; token?: string }> {
	const started = Date.now();
	const appId = env.GITHUB_WEB_WORKSPACES_APP_ID;
	const pk = env.GITHUB_APP_PRIVATE_KEY;
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
		const installationId = await findInstallationId(jwt, repo);
		const tok = await getInstallationToken(jwt, installationId);
		const accessibleRepo = await verifyRepoAccess(tok.token, repo);
		return {
			token: tok.token,
			result: {
				name: "github",
				ok: true,
				latencyMs: Date.now() - started,
				detail: {
					repo: accessibleRepo.fullName,
					defaultBranch: accessibleRepo.defaultBranch,
					private: accessibleRepo.private,
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
async function checkSandbox(
	cloneToken: string | undefined,
	env: NodeJS.ProcessEnv,
	repo: string,
): Promise<CheckResult> {
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
			token: env.VERCEL_TOKEN,
			teamId: env.VERCEL_TEAM_ID,
			projectId: env.VERCEL_PROJECT_ID,
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
			const url = `https://x-access-token:${cloneToken}@github.com/${repo}.git`;
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
	provider = process.env.WEB_NEXT_COMPUTE_PROVIDER ?? "mock",
	env = process.env,
	hostDependencies,
}: {
	includeSandbox: boolean;
	provider?: string;
	env?: NodeJS.ProcessEnv;
	hostDependencies?: HostPreflightDependencies;
}): Promise<PreflightReport> {
	const started = Date.now();
	const repo = cloneRepo(env);
	if (provider === "host") {
		const checks = [
			informational("env", provider),
			informational("llm", provider),
			informational("vercel", provider),
			informational("github", provider),
			...(await checkHostProvider(env, hostDependencies)),
		];
		if (includeSandbox) checks.push(informational("sandbox", provider));
		return {
			ok: checks.every((check) => check.ok || check.skipped),
			ranAt: new Date().toISOString(),
			onVercel: !!env.VERCEL,
			provider,
			cloneRepo: repo,
			checks,
			tookMs: Date.now() - started,
		};
	}
	if (provider !== "vercel") {
		const checks = [
			{
				name: "provider",
				ok: true,
				skipped: true,
				detail: {
					provider,
					note: "no real-runtime preflight required for this provider",
				},
			},
		];
		return {
			ok: true,
			ranAt: new Date().toISOString(),
			onVercel: !!env.VERCEL,
			provider,
			cloneRepo: repo,
			checks,
			tookMs: Date.now() - started,
		};
	}
	const [llm, vercel, gh] = await Promise.all([
		timed("llm", () => checkLlm(env)),
		timed("vercel", () => checkVercel(env)),
		mintGithub(env, repo),
	]);
	const checks: CheckResult[] = [checkEnv(env), llm, vercel, gh.result];
	if (includeSandbox) checks.push(await checkSandbox(gh.token, env, repo));
	return {
		ok: checks.every((c) => c.ok || c.skipped),
		ranAt: new Date().toISOString(),
		onVercel: !!env.VERCEL,
		provider,
		cloneRepo: repo,
		checks,
		tookMs: Date.now() - started,
	};
}
