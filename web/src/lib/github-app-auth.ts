import crypto from "node:crypto";

function base64url(input: Buffer | string): string {
	const buf = typeof input === "string" ? Buffer.from(input) : input;
	return buf.toString("base64url");
}

export function generateGitHubAppJWT(
	appId: string,
	privateKeyPem: string,
): string {
	const now = Math.floor(Date.now() / 1000);
	const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
	const payload = base64url(
		JSON.stringify({ iss: appId, iat: now - 60, exp: now + 600 }),
	);
	const data = `${header}.${payload}`;
	const normalizedKey = privateKeyPem.replace(/\\n/g, "\n");
	const signature = crypto.sign("sha256", Buffer.from(data), normalizedKey);
	return `${data}.${base64url(signature)}`;
}

export async function getInstallationToken(
	appId: string,
	privateKeyPem: string,
	installationId: string,
): Promise<string> {
	const jwt = generateGitHubAppJWT(appId, privateKeyPem);
	const res = await fetch(
		`https://api.github.com/app/installations/${installationId}/access_tokens`,
		{
			method: "POST",
			headers: {
				Authorization: `Bearer ${jwt}`,
				Accept: "application/vnd.github+json",
			},
		},
	);
	if (!res.ok) {
		const body = await res.text().catch(() => "");
		throw new Error(
			`GitHub App token exchange failed (${res.status}): ${body}`,
		);
	}
	const json = (await res.json()) as { token: string };
	return json.token;
}
