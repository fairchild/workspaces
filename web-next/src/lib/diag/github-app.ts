/*
 * GitHub App auth, hand-rolled with node:crypto (no external dep). Mints an App
 * JWT, discovers the target repo's installation, and exchanges it for a
 * short-lived, repo-scoped installation token — the credential a sandbox uses
 * to clone. Used by the preflight probe now; reusable by the #750 provider.
 */
import crypto from "node:crypto";

function base64url(input: Buffer | string): string {
	const buf = typeof input === "string" ? Buffer.from(input) : input;
	return buf.toString("base64url");
}

/**
 * Accepts either a raw PEM (optionally single-line with escaped `\n`, as `web/`
 * stores it) or a base64-encoded PEM (as web-next's `.env.local.example`
 * prescribes). Returns a real multi-line PEM either way.
 */
export function normalizePrivateKey(raw: string): string {
	const s = raw.trim();
	if (s.includes("BEGIN")) return s.replace(/\\n/g, "\n");
	return Buffer.from(s, "base64").toString("utf8");
}

export function generateAppJWT(appId: string, privateKeyPem: string): string {
	const now = Math.floor(Date.now() / 1000);
	const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
	const payload = base64url(
		JSON.stringify({ iss: appId, iat: now - 60, exp: now + 600 }),
	);
	const data = `${header}.${payload}`;
	const signature = crypto.sign(
		"sha256",
		Buffer.from(data),
		normalizePrivateKey(privateKeyPem),
	);
	return `${data}.${base64url(signature)}`;
}

const GH = "https://api.github.com";
const HEADERS = {
	Accept: "application/vnd.github+json",
	"User-Agent": "web-next-preflight",
	"X-GitHub-Api-Version": "2022-11-28",
};

async function ghError(res: Response, label: string): Promise<never> {
	const body = await res.text().catch(() => "");
	throw new Error(`${label} (${res.status}): ${body.slice(0, 300)}`);
}

/** Which installation covers this repo — avoids needing an installation-id env var. */
export async function findInstallationId(jwt: string, repo: string): Promise<number> {
	const res = await fetch(`${GH}/repos/${repo}/installation`, {
		headers: { Authorization: `Bearer ${jwt}`, ...HEADERS },
	});
	if (!res.ok) return ghError(res, `installation lookup for ${repo}`);
	const json = (await res.json()) as { id: number };
	return json.id;
}

export interface InstallationToken {
	token: string;
	expiresAt: string;
	permissions: Record<string, string>;
}

export async function getInstallationToken(
	jwt: string,
	installationId: number,
): Promise<InstallationToken> {
	const res = await fetch(
		`${GH}/app/installations/${installationId}/access_tokens`,
		{ method: "POST", headers: { Authorization: `Bearer ${jwt}`, ...HEADERS } },
	);
	if (!res.ok) return ghError(res, "installation token exchange");
	const json = (await res.json()) as {
		token: string;
		expires_at: string;
		permissions: Record<string, string>;
	};
	return {
		token: json.token,
		expiresAt: json.expires_at,
		permissions: json.permissions,
	};
}

/** Prove the token can read the repo — i.e. it can clone it. */
export async function verifyRepoAccess(
	token: string,
	repo: string,
): Promise<{ fullName: string; defaultBranch: string; private: boolean }> {
	const res = await fetch(`${GH}/repos/${repo}`, {
		headers: { Authorization: `token ${token}`, ...HEADERS },
	});
	if (!res.ok) return ghError(res, `repo read for ${repo}`);
	const json = (await res.json()) as {
		full_name: string;
		default_branch: string;
		private: boolean;
	};
	return {
		fullName: json.full_name,
		defaultBranch: json.default_branch,
		private: json.private,
	};
}
