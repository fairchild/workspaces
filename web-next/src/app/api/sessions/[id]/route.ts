/*
 * /api/sessions/[id] — the session resource. GET reads the session plus its
 * durable event log (the projection the transcript is built from — what the
 * #818 validation probe polls as the source of truth). PATCH updates the
 * mutable settings: `model` (#824's picker) and/or `title` (#823's inline
 * edit), each validated against its own source of truth, any unknown key a
 * 400. DELETE removes the session and its log — but first stops any live
 * parked sandbox (sandbox-release.ts); a sandbox that can't be stopped keeps
 * the session, so the only pointer to a still-billing machine is never lost.
 * Every method carries the same auth gate as the chat route.
 */
import { isSelectableModel } from "@/lib/agent-runtime/models";
import { releaseParkedSandbox } from "@/lib/agent-runtime/sandbox-release";
import { resolveTurn } from "@/lib/agent-runtime/turn-tail";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import {
	deleteSession,
	getSession,
	readEvents,
	updateSession,
} from "@/lib/db/sessions";
import { cleanTitleText, MAX_TITLE_LENGTH } from "@/lib/session-title";

export const runtime = "nodejs";

export async function GET(
	request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session" }, { status: 404 });
	}

	const sinceParam = new URL(request.url).searchParams.get("sinceSeq");
	const sinceSeq = sinceParam ? Number(sinceParam) : 0;
	if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
		return Response.json(
			{ error: "sinceSeq must be a non-negative number" },
			{ status: 400 },
		);
	}
	const events = await readEvents(handle, id, sinceSeq);
	return Response.json({
		session: {
			id: session.id,
			title: session.title,
			provider: session.provider,
			status: session.status,
			model: session.model,
			// Whether a turn parked a resumable sandbox handle; the handle itself
			// is private server state and never leaves the row.
			parked: !!(session.claudeSessionId && session.resumeState),
			createdAt: session.createdAt,
			lastActivityAt: session.lastActivityAt,
		},
		events: events.map((event) => ({
			seq: event.seq,
			role: event.role,
			kind: event.chunk.type,
			content: event.chunk.content,
			metadata: event.chunk.metadata,
		})),
	});
}

export async function DELETE(
	_request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session" }, { status: 404 });
	}

	// A running turn's detached ingest keeps appending to this session;
	// deleting now would orphan those writes and lose the resume handle the
	// turn is about to park (a sandbox leak until its lifetime cap). Refuse
	// until it settles — a *stale* turn (dead runner) has no live writer and
	// deletes fine.
	const turn = await resolveTurn(handle, id);
	if (turn.status === "running") {
		return Response.json(
			{ error: "a turn is still running on this session — retry once it completes" },
			{ status: 409 },
		);
	}

	const release = await releaseParkedSandbox(session);
	if (release.disposition === "stop-failed") {
		// The sandbox is (as far as we can tell) still running and we could not
		// stop it. Deleting the session now would drop the resume handle — the
		// only pointer to a machine that keeps billing — so keep everything and
		// report the failure for a retry.
		return Response.json(
			{
				error: `the session's sandbox could not be stopped: ${release.detail}`,
				sandbox: release.disposition,
			},
			{ status: 502 },
		);
	}
	await deleteSession(handle, id);
	return Response.json({ deleted: true, sandbox: release.disposition });
}

const ALLOWED_FIELDS = new Set(["model", "title"]);

export async function PATCH(
	request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session" }, { status: 404 });
	}

	const body: unknown = await request.json().catch(() => undefined);
	if (typeof body !== "object" || body === null) {
		return Response.json({ error: "a JSON body is required" }, { status: 400 });
	}

	const unknownFields = Object.keys(body).filter((key) => !ALLOWED_FIELDS.has(key));
	if (unknownFields.length > 0) {
		return Response.json(
			{ error: `unknown field(s): ${unknownFields.join(", ")}` },
			{ status: 400 },
		);
	}

	const patch: { model?: string; title?: string } = {};
	const response: { model?: string; title?: string } = {};

	if ("model" in body) {
		const model = String((body as { model: unknown }).model);
		if (!isSelectableModel(model)) {
			return Response.json({ error: `unknown model: ${model}` }, { status: 400 });
		}
		patch.model = model;
		response.model = model;
	}

	if ("title" in body) {
		const raw = (body as { title: unknown }).title;
		if (typeof raw !== "string") {
			return Response.json({ error: "title must be a string" }, { status: 400 });
		}
		const title = cleanTitleText(raw);
		if (!title) {
			return Response.json({ error: "title must not be empty" }, { status: 400 });
		}
		if (title.length > MAX_TITLE_LENGTH) {
			return Response.json(
				{ error: `title must be at most ${MAX_TITLE_LENGTH} characters` },
				{ status: 400 },
			);
		}
		patch.title = title;
		response.title = title;
	}

	if (Object.keys(patch).length === 0) {
		return Response.json({ error: "model or title is required" }, { status: 400 });
	}

	await updateSession(handle, id, patch);
	return Response.json(response);
}
