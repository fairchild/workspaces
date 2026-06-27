type DynamicAuthBaseURL = {
	allowedHosts: string[];
	protocol: "http" | "https" | "auto";
	fallback?: string;
};

export type AuthBaseURL = string | DynamicAuthBaseURL;

const LOCAL_ALLOWED_HOSTS = ["localhost:*", "127.0.0.1:*"];
const VERCEL_ALLOWED_HOSTS = [
	"spaces.cloudcompute.com",
	"qa.spaces-preview.cloudcompute.com",
	"*.cloudcompute.vercel.app",
	"*.vercel.app",
];

function withHttps(hostOrUrl: string): string {
	if (hostOrUrl.startsWith("http://") || hostOrUrl.startsWith("https://")) {
		return hostOrUrl;
	}
	return `https://${hostOrUrl}`;
}

function vercelFallback(env: NodeJS.ProcessEnv): string | undefined {
	if (env.BETTER_AUTH_URL) return env.BETTER_AUTH_URL;
	if (env.VERCEL_URL) return withHttps(env.VERCEL_URL);
	return undefined;
}

export function getAuthBaseURL(env = process.env): AuthBaseURL {
	if (env.VERCEL === "1" || env.VERCEL_ENV || env.VERCEL_URL) {
		return {
			allowedHosts: [...VERCEL_ALLOWED_HOSTS, ...LOCAL_ALLOWED_HOSTS],
			protocol: "https",
			...(vercelFallback(env) ? { fallback: vercelFallback(env) } : {}),
		};
	}

	if (env.BETTER_AUTH_URL) return env.BETTER_AUTH_URL;

	if (env.NODE_ENV === "development") {
		return {
			allowedHosts: LOCAL_ALLOWED_HOSTS,
			protocol: "http",
			fallback: "http://localhost:3000",
		};
	}

	return "http://localhost:3000";
}
