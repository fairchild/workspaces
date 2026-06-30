import type { PrReviewRunDetails } from "@/lib/agent-runtime/pr-review-runs";
import { describe, expect, it } from "vitest";
import {
	formatDuration,
	lifecycleForRun,
	phaseForRun,
} from "./review-run-detail-view-model";

const START = "2026-06-30T20:00:00.000Z";
const PICKUP = "2026-06-30T20:01:00.000Z";
const UPDATE = "2026-06-30T20:03:00.000Z";

function run(overrides: Partial<PrReviewRunDetails> = {}): PrReviewRunDetails {
	return {
		fingerprint: "fp_test",
		repoFullName: "fairchild/workspaces",
		prNumber: 714,
		headSha: "9704ecbe24cc9f8ea716285f3ac2b9a1a95fd3f1",
		triggerKind: "synchronize",
		triggerSourceId: "9704ecbe24cc9f8ea716285f3ac2b9a1a95fd3f1",
		status: "started",
		sessionId: null,
		sessionStartedAt: null,
		createdAt: START,
		updatedAt: START,
		error: null,
		executionState: "waiting_for_session",
		latestKnownHeadSha: "9704ecbe24cc9f8ea716285f3ac2b9a1a95fd3f1",
		failureKind: null,
		failureMessage: null,
		failureRetryable: null,
		failedAt: null,
		nextAction: "Wait for the managed-agent session to start.",
		projectionStatus: "pending",
		projectionUpdatedAt: START,
		projectionError: null,
		githubReviewId: null,
		coalescedHeadSha: null,
		coalescedTriggerKind: null,
		coalescedTriggerSourceId: null,
		coalescedAt: null,
		reviewerConfigHash: "cfg",
		reviewIntent: null,
		projections: [],
		recovery: {
			available: false,
			action: null,
			label: null,
			reason: "This ReviewRun is still active.",
			reasonCode: "run_active",
		},
		...overrides,
	};
}

describe("review run detail view model", () => {
	it("formats active elapsed time from the supplied clock", () => {
		expect(
			formatDuration(START, null, new Date("2026-06-30T20:01:12Z").getTime()),
		).toBe("1m 12s");
	});

	it("classifies a run waiting for session pickup", () => {
		const phase = phaseForRun(run());

		expect(phase).toMatchObject({
			label: "Waiting for pickup",
			tone: "started",
		});
		expect(
			lifecycleForRun(run()).map((step) => [step.key, step.state]),
		).toEqual([
			["trigger", "done"],
			["pickup", "current"],
			["agent", "pending"],
			["intent", "pending"],
			["github", "pending"],
			["outcome", "pending"],
		]);
	});

	it("marks an attached session as the current agent step", () => {
		const active = run({
			sessionId: "sesn_test",
			sessionStartedAt: PICKUP,
			executionState: "running_session",
			nextAction: "Wait for the managed-agent session to finish.",
		});

		expect(phaseForRun(active)).toMatchObject({
			label: "Agent running",
			tone: "started",
		});
		expect(
			lifecycleForRun(active).map((step) => [step.key, step.state]),
		).toEqual([
			["trigger", "done"],
			["pickup", "done"],
			["agent", "current"],
			["intent", "pending"],
			["github", "pending"],
			["outcome", "pending"],
		]);
	});

	it("classifies a projected run as published", () => {
		const published = run({
			status: "completed",
			sessionId: "sesn_test",
			sessionStartedAt: PICKUP,
			updatedAt: UPDATE,
			executionState: "completed",
			reviewIntent: { event: "approve", body: "Looks good.", labels: [] },
			nextAction:
				"No action needed; the ReviewRun has been published to GitHub.",
			projectionStatus: "projected",
			projectionUpdatedAt: UPDATE,
			githubReviewId: "PRR_kw",
		});

		expect(phaseForRun(published)).toMatchObject({
			label: "Published to GitHub",
			tone: "completed",
		});
		expect(
			lifecycleForRun(published).map((step) => [step.key, step.state]),
		).toEqual([
			["trigger", "done"],
			["pickup", "done"],
			["agent", "done"],
			["intent", "done"],
			["github", "done"],
			["outcome", "done"],
		]);
	});

	it("keeps projection failure distinct from execution failure", () => {
		const projectionFailed = run({
			status: "completed",
			sessionId: "sesn_test",
			sessionStartedAt: PICKUP,
			updatedAt: UPDATE,
			executionState: "completed",
			reviewIntent: { event: "comment", body: "Needs work.", labels: [] },
			nextAction:
				"Broker or repair tooling should publish the completed ReviewRun projection to GitHub.",
			projectionStatus: "failed",
			projectionUpdatedAt: UPDATE,
			projectionError: "GitHub status write failed.",
			recovery: {
				available: true,
				action: "repair_projection",
				label: "Repair projection",
				reason: "Projection can be repaired.",
				reasonCode: "projection_failed",
			},
		});

		expect(phaseForRun(projectionFailed)).toMatchObject({
			label: "GitHub output needs repair",
			tone: "projection-failed",
		});
		expect(lifecycleForRun(projectionFailed).at(4)).toMatchObject({
			key: "github",
			state: "blocked",
		});
		expect(lifecycleForRun(projectionFailed).at(5)).toMatchObject({
			key: "outcome",
			state: "current",
		});
	});
});
