/**
 * Forward filter for the web-app webhook mirror: decides which GitHub events
 * the relay forwards to the dashboard (event stream, dispatch cards).
 * Standalone module (no Workers imports) so it stays unit-testable under bun.
 */

const EVIDENCE_SIGNAL =
  /(evidence\.cloudcompute\.com|^\s*(?:Evidence|Validation):)/im;

function isBotSender(payload: Record<string, unknown>): boolean {
  const sender = payload.sender as Record<string, unknown> | undefined;
  const login = String(sender?.login ?? "");
  if (login.endsWith("[bot]")) return true;
  return String(sender?.type ?? "").toLowerCase() === "bot";
}

export function shouldForwardToWebApp(
  eventType: string,
  payload: Record<string, unknown>
): boolean {
  if (isBotSender(payload)) return false;

  const action = String(payload.action ?? "");
  if (eventType === "pull_request") {
    const pr = payload.pull_request as Record<string, unknown> | undefined;
    if (!pr) return false;
    const isDraft = Boolean(pr.draft);

    if (["opened", "reopened", "synchronize", "edited"].includes(action)) {
      if (isDraft) return false;
      if (action !== "edited") return true;
      const changes = payload.changes as Record<string, unknown> | undefined;
      return Boolean(changes?.body !== undefined || changes?.base !== undefined);
    }

    return action === "ready_for_review";
  }

  if (eventType === "issue_comment" && action === "created") {
    const issue = payload.issue as Record<string, unknown> | undefined;
    const comment = payload.comment as Record<string, unknown> | undefined;
    if (!issue?.pull_request) return false;
    const body = String(comment?.body ?? "");
    return EVIDENCE_SIGNAL.test(body);
  }

  return false;
}
