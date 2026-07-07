/*
 * PATCH /api/sessions/[id] — update a session's mutable settings: `model`
 * (#824's picker) and/or `title` (#823's inline edit). Auth-gated same as the
 * chat route. Each field validates against its own source of truth —
 * `isSelectableModel` (agent-runtime/models.ts) and the title cap/cleaning in
 * session-title.ts, shared with the auto-titler so both paths agree on what a
 * valid title is. Any key outside {model, title} is a 400, not a silent
 * no-op, so a typo'd field fails loudly instead of patching nothing.
 */
import { isSelectableModel } from "@/lib/agent-runtime/models";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getSession, updateSession } from "@/lib/db/sessions";
import { cleanTitleText, MAX_TITLE_LENGTH } from "@/lib/session-title";

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
