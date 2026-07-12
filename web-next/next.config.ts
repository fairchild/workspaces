import type { NextConfig } from "next";

if (process.env.WEB_NEXT_LOCAL_MODE === "1") {
	if (process.env.AUTH_BYPASS === "1") {
		throw new Error("WEB_NEXT_LOCAL_MODE cannot be combined with AUTH_BYPASS=1");
	}
	if (process.env.GITHUB_OAUTH_CLIENT_ID || process.env.GITHUB_OAUTH_CLIENT_SECRET) {
		throw new Error(
			"WEB_NEXT_LOCAL_MODE cannot be combined with GitHub OAuth environment variables",
		);
	}
}

const nextConfig: NextConfig = {
	transpilePackages: ["@fairchild/folio"],
	// The real (vercel) compute provider talks to the in-sandbox harness bridge
	// over a WebSocket. Bundling `ws` (and its native `bufferutil`) breaks that
	// path with "bufferUtil.mask is not a function", so keep the harness stack
	// external and let Node require it at runtime.
	serverExternalPackages: [
		"ws",
		"bufferutil",
		"utf-8-validate",
		"@ai-sdk/harness",
		"@ai-sdk/harness-claude-code",
		"@ai-sdk/sandbox-vercel",
		"@vercel/sandbox",
	],
};

export default nextConfig;
