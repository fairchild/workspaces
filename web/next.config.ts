import type { NextConfig } from "next";

const nextConfig: NextConfig = {
	serverExternalPackages: ["chat", "@chat-adapter/state-memory"],
};

export default nextConfig;
