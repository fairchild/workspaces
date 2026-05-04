import { describe, expect, it } from "vitest";
import { getAuthBaseURL } from "../auth-base-url";

describe("getAuthBaseURL", () => {
	it("uses an explicit non-Vercel BETTER_AUTH_URL unchanged", () => {
		expect(
			getAuthBaseURL({
				BETTER_AUTH_URL: "https://spaces.cloudcompute.com",
				NODE_ENV: "production",
			}),
		).toBe("https://spaces.cloudcompute.com");
	});

	it("derives Vercel auth origins from the request host with a deployment fallback", () => {
		expect(
			getAuthBaseURL({
				VERCEL: "1",
				VERCEL_ENV: "preview",
				VERCEL_URL: "spaces-gw9l63dw8-cloudcompute.vercel.app",
				NODE_ENV: "production",
			}),
		).toEqual({
			allowedHosts: [
				"spaces.cloudcompute.com",
				"*.cloudcompute.vercel.app",
				"*.vercel.app",
				"localhost:*",
				"127.0.0.1:*",
			],
			protocol: "https",
			fallback: "https://spaces-gw9l63dw8-cloudcompute.vercel.app",
		});
	});

	it("keeps Vercel dynamic even when BETTER_AUTH_URL is configured", () => {
		expect(
			getAuthBaseURL({
				BETTER_AUTH_URL: "https://spaces.cloudcompute.com",
				VERCEL: "1",
				VERCEL_ENV: "production",
				VERCEL_URL: "spaces.cloudcompute.com",
				NODE_ENV: "production",
			}),
		).toMatchObject({
			protocol: "https",
			fallback: "https://spaces.cloudcompute.com",
		});
	});

	it("allows localhost origins in development", () => {
		expect(getAuthBaseURL({ NODE_ENV: "development" })).toEqual({
			allowedHosts: ["localhost:*", "127.0.0.1:*"],
			protocol: "http",
			fallback: "http://localhost:3000",
		});
	});
});
