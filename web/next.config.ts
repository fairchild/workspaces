import type { NextConfig } from "next";

const nextConfig: NextConfig = {
	serverExternalPackages: [
		"chat",
		"@chat-adapter/state-memory",
		"@libsql/client",
		"libsql",
	],
	images: {
		remotePatterns: [
			{ protocol: "https", hostname: "avatars.githubusercontent.com" },
		],
	},
};

export default nextConfig;
