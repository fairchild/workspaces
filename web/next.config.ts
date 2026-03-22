import type { NextConfig } from "next";

const nextConfig: NextConfig = {
	serverExternalPackages: [
		"chat",
		"@chat-adapter/state-memory",
		"better-sqlite3",
	],
	images: {
		remotePatterns: [
			{ protocol: "https", hostname: "avatars.githubusercontent.com" },
		],
	},
};

export default nextConfig;
