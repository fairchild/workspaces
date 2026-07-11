import { describe, expect, test } from "vitest";
import {
	deriveLivePullRequestAction,
	shouldRefreshSessionAfterTurn,
} from "./pull-request-action";

const staleDisabledAction = {
	head: "spaces/session-123",
	base: "main",
	enabled: false,
	reason: "no checkpoints ready",
};

describe("deriveLivePullRequestAction", () => {
	test("arms a page-load-disabled action when live branch work arrives", () => {
		expect(
			deriveLivePullRequestAction(staleDisabledAction, {
				hasBranchWork: true,
				busy: false,
			}),
		).toEqual({
			head: "spaces/session-123",
			base: "main",
			enabled: true,
			reason: undefined,
		});
	});

	test("keeps the action disabled while a turn is busy", () => {
		expect(
			deriveLivePullRequestAction(staleDisabledAction, {
				hasBranchWork: true,
				busy: true,
			}),
		).toMatchObject({ enabled: false, reason: "wait for turn" });
	});

	test("keeps the action disabled when no checkpoint exists", () => {
		expect(
			deriveLivePullRequestAction(staleDisabledAction, {
				hasBranchWork: false,
				busy: false,
			}),
		).toMatchObject({ enabled: false, reason: "no checkpoints ready" });
	});

	test("does not invent an action for providers without PR support", () => {
		expect(
			deriveLivePullRequestAction(null, {
				hasBranchWork: true,
				busy: false,
			}),
		).toBeNull();
	});
});

describe("shouldRefreshSessionAfterTurn", () => {
	test("refreshes only on the busy to idle edge", () => {
		expect(shouldRefreshSessionAfterTurn(true, false)).toBe(true);
		expect(shouldRefreshSessionAfterTurn(false, false)).toBe(false);
		expect(shouldRefreshSessionAfterTurn(false, true)).toBe(false);
		expect(shouldRefreshSessionAfterTurn(true, true)).toBe(false);
	});
});
