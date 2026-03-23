import type { NextConfig } from "next";

const nextConfig: NextConfig = {
	serverExternalPackages: ["@libsql/client", "libsql"],
	images: {
		remotePatterns: [
			{ protocol: "https", hostname: "avatars.githubusercontent.com" },
		],
	},
};

export default nextConfig;
