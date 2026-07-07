import type { NextConfig } from "next";

const nextConfig: NextConfig = {
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
