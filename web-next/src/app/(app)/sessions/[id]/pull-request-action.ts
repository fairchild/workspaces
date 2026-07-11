/*
 * Live PR-action state for a session. The server-rendered action establishes
 * provider capability and branch identity; live turn state owns whether the
 * action is currently eligible, so a completed checkpoint can arm it without
 * a page reload.
 */
import type { MastheadData } from "@/components/folio/session-masthead";

type PullRequestAction = NonNullable<MastheadData["pullRequestAction"]>;

export function deriveLivePullRequestAction(
	action: PullRequestAction | null | undefined,
	state: { hasBranchWork: boolean; busy: boolean },
): PullRequestAction | null {
	if (!action) return null;
	return {
		...action,
		enabled: state.hasBranchWork && !state.busy,
		reason: state.busy
			? "wait for turn"
			: state.hasBranchWork
				? undefined
				: "no checkpoints ready",
	};
}

export function shouldRefreshSessionAfterTurn(
	wasBusy: boolean,
	isBusy: boolean,
): boolean {
	return wasBusy && !isBusy;
}
