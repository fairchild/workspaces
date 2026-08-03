/**
 * Unit coverage for shouldForwardToWebApp's retained trigger shapes — the
 * non-port-bound verification of the forward filter kept after the managed
 * PR reviewer retirement (live consumers: event stream, dispatch cards).
 */
import { describe, expect, test } from "bun:test";
import { shouldForwardToWebApp } from "../src/forwarding";

const human = { sender: { login: "fairchild", type: "User" } };
const bot = { sender: { login: "april-clearwater[bot]", type: "Bot" } };

function prPayload(
  action: string,
  extra: Record<string, unknown> = {},
  pr: Record<string, unknown> = {}
): Record<string, unknown> {
  return { ...human, action, pull_request: { draft: false, ...pr }, ...extra };
}

describe("shouldForwardToWebApp — pull_request", () => {
  test.each(["opened", "reopened", "synchronize"])("%s forwards", (action) => {
    expect(shouldForwardToWebApp("pull_request", prPayload(action))).toBe(true);
  });

  test.each(["opened", "reopened", "synchronize"])(
    "%s on a draft does not forward",
    (action) => {
      expect(
        shouldForwardToWebApp("pull_request", prPayload(action, {}, { draft: true }))
      ).toBe(false);
    }
  );

  test("ready_for_review forwards", () => {
    expect(
      shouldForwardToWebApp("pull_request", prPayload("ready_for_review"))
    ).toBe(true);
  });

  test("edited forwards only for body or base changes", () => {
    expect(
      shouldForwardToWebApp(
        "pull_request",
        prPayload("edited", { changes: { body: { from: "old" } } })
      )
    ).toBe(true);
    expect(
      shouldForwardToWebApp(
        "pull_request",
        prPayload("edited", { changes: { base: { ref: { from: "main" } } } })
      )
    ).toBe(true);
    expect(
      shouldForwardToWebApp(
        "pull_request",
        prPayload("edited", { changes: { title: { from: "old" } } })
      )
    ).toBe(false);
  });

  test("payload without pull_request does not forward", () => {
    expect(
      shouldForwardToWebApp("pull_request", { ...human, action: "opened" })
    ).toBe(false);
  });

  test("unhandled actions do not forward", () => {
    expect(shouldForwardToWebApp("pull_request", prPayload("closed"))).toBe(false);
    expect(shouldForwardToWebApp("pull_request", prPayload("labeled"))).toBe(false);
  });
});

describe("shouldForwardToWebApp — issue_comment", () => {
  const prComment = (body: string): Record<string, unknown> => ({
    ...human,
    action: "created",
    issue: { pull_request: { url: "https://api.github.com/x" } },
    comment: { body },
  });

  test("evidence-signal comments on PRs forward", () => {
    expect(
      shouldForwardToWebApp(
        "issue_comment",
        prComment("results: https://evidence.cloudcompute.com/x/y.png")
      )
    ).toBe(true);
    expect(
      shouldForwardToWebApp("issue_comment", prComment("Evidence: attached above"))
    ).toBe(true);
    expect(
      shouldForwardToWebApp("issue_comment", prComment("Validation: green run"))
    ).toBe(true);
  });

  test("plain comments on PRs do not forward", () => {
    expect(shouldForwardToWebApp("issue_comment", prComment("lgtm"))).toBe(false);
  });

  test("comments on non-PR issues do not forward", () => {
    expect(
      shouldForwardToWebApp("issue_comment", {
        ...human,
        action: "created",
        issue: {},
        comment: { body: "Evidence: x" },
      })
    ).toBe(false);
  });

  test("non-created actions do not forward", () => {
    const payload = prComment("Evidence: x");
    expect(
      shouldForwardToWebApp("issue_comment", { ...payload, action: "edited" })
    ).toBe(false);
  });
});

describe("shouldForwardToWebApp — global guards", () => {
  test("bot senders never forward", () => {
    expect(
      shouldForwardToWebApp("pull_request", { ...prPayload("opened"), ...bot })
    ).toBe(false);
    expect(
      shouldForwardToWebApp("pull_request", {
        ...prPayload("opened"),
        sender: { login: "some-app", type: "Bot" },
      })
    ).toBe(false);
  });

  test("unknown event types never forward", () => {
    expect(shouldForwardToWebApp("push", { ...human })).toBe(false);
    expect(shouldForwardToWebApp("status", { ...human })).toBe(false);
  });
});
