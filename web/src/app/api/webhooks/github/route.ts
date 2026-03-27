import crypto from "node:crypto";
import { pushEvent } from "@/lib/events";
import type { WebhookEvent, WebhookEventType } from "@/lib/types";

export const dynamic = "force-dynamic";

const SUPPORTED_EVENTS = new Set<string>([
	"pull_request",
	"check_run",
	"check_suite",
	"discussion",
	"discussion_comment",
	"push",
	"issues",
	"issue_comment",
	"workflow_run",
]);

async function verifySignature(
	body: string,
	signature: string | null,
): Promise<boolean> {
	const secret = process.env.GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET;
	if (!secret) {
		if (process.env.NODE_ENV === "production") {
			console.warn("[webhooks] WEBHOOK_SECRET is not set — rejecting");
			return false;
		}
		return true;
	}
	if (!signature) {
		console.warn("[webhooks] no signature header");
		return false;
	}

	const expected = `sha256=${crypto.createHmac("sha256", secret).update(body).digest("hex")}`;

	if (signature.length !== expected.length) {
		console.warn(
			`[webhooks] sig length mismatch: got=${signature.length} expected=${expected.length} secret_len=${secret.length}`,
		);
		return false;
	}

	const sigBuf = Buffer.from(signature);
	const expectedBuf = Buffer.from(expected);
	return crypto.timingSafeEqual(sigBuf, expectedBuf);
}

function summarize(
	type: string,
	action: string,
	payload: Record<string, unknown>,
): string {
	switch (type) {
		case "pull_request": {
			const pr = payload.pull_request as Record<string, unknown> | undefined;
			return `${action} #${pr?.number ?? "?"}: ${pr?.title ?? ""}`;
		}
		case "push": {
			const commits = payload.commits as unknown[] | undefined;
			const ref = String(payload.ref ?? "").replace("refs/heads/", "");
			return `${commits?.length ?? 0} commit(s) to ${ref}`;
		}
		case "issues": {
			const issue = payload.issue as Record<string, unknown> | undefined;
			return `${action} #${issue?.number ?? "?"}: ${issue?.title ?? ""}`;
		}
		case "check_run": {
			const cr = payload.check_run as Record<string, unknown> | undefined;
			return `${cr?.name ?? "check"}: ${cr?.conclusion ?? action}`;
		}
		case "workflow_run": {
			const wr = payload.workflow_run as Record<string, unknown> | undefined;
			return `${wr?.name ?? "workflow"}: ${wr?.conclusion ?? action}`;
		}
		default:
			return action;
	}
}

export async function POST(request: Request): Promise<Response> {
	const body = await request.text();
	const signature = request.headers.get("x-hub-signature-256");

	if (!(await verifySignature(body, signature))) {
		return new Response("invalid signature", { status: 401 });
	}

	const eventType = request.headers.get("x-github-event");
	if (!eventType || !SUPPORTED_EVENTS.has(eventType)) {
		return new Response("ignored", { status: 200 });
	}

	const payload = JSON.parse(body) as Record<string, unknown>;
	const action = String(payload.action ?? "");
	const repo = (payload.repository as Record<string, unknown> | undefined)
		?.full_name as string | undefined;

	const event: WebhookEvent = {
		id: request.headers.get("x-github-delivery") ?? crypto.randomUUID(),
		type: eventType as WebhookEventType,
		action,
		summary: summarize(eventType, action, payload),
		repo: repo ?? "unknown",
		timestamp: new Date().toISOString(),
		payload: body,
	};

	await pushEvent(event);

	return Response.json({ ok: true });
}
