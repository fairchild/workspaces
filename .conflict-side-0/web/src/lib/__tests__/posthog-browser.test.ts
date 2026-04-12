import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockCapture, mockIdentify, mockReset } = vi.hoisted(() => ({
	mockCapture: vi.fn(),
	mockIdentify: vi.fn(),
	mockReset: vi.fn(),
}));

vi.mock("posthog-js", () => ({
	default: {
		capture: mockCapture,
		identify: mockIdentify,
		reset: mockReset,
	},
}));

import {
	capturePostHogEvent,
	identifyPostHogUser,
	isPostHogEnabled,
	resetPostHogUser,
} from "../posthog-browser";

describe("posthog-browser", () => {
	beforeEach(() => {
		vi.stubEnv("NEXT_PUBLIC_POSTHOG_TOKEN", "phc_test");
		mockCapture.mockReset();
		mockIdentify.mockReset();
		mockReset.mockReset();
	});

	afterEach(() => {
		vi.unstubAllEnvs();
	});

	it("emits calls when configured", () => {
		expect(isPostHogEnabled()).toBe(true);

		capturePostHogEvent("web_repositories_saved", { repo_count: 2 });
		identifyPostHogUser("user-123", { email: "test@example.com" });
		resetPostHogUser();

		expect(mockCapture).toHaveBeenCalledWith("web_repositories_saved", {
			repo_count: 2,
		});
		expect(mockIdentify).toHaveBeenCalledWith("user-123", {
			email: "test@example.com",
		});
		expect(mockReset).toHaveBeenCalledTimes(1);
	});

	it("suppresses PostHog calls when the project token is missing", () => {
		vi.stubEnv("NEXT_PUBLIC_POSTHOG_TOKEN", "");

		expect(isPostHogEnabled()).toBe(false);

		capturePostHogEvent("web_repositories_saved");
		identifyPostHogUser("user-123");
		resetPostHogUser();

		expect(mockCapture).not.toHaveBeenCalled();
		expect(mockIdentify).not.toHaveBeenCalled();
		expect(mockReset).not.toHaveBeenCalled();
	});
});
