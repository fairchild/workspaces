/*
 * PATCH /api/sessions/[id] — update a session's mutable settings. Currently
 * just `model` (#824's picker): auth-gated same as the chat route, validated
 * against the single source of truth in agent-runtime/models.ts so an unknown
 * or retired id is a 400, not a silent write.
 */
import { isSelectableModel } from "@/lib/agent-runtime/models";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getSession, updateSession } from "@/lib/db/sessions";

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
	const model =
		typeof body === "object" && body !== null && "model" in body
			? String((body as { model: unknown }).model)
			: undefined;
	if (model === undefined) {
		return Response.json({ error: "model is required" }, { status: 400 });
	}
	if (!isSelectableModel(model)) {
		return Response.json({ error: `unknown model: ${model}` }, { status: 400 });
	}

	await updateSession(handle, id, { model });
	return Response.json({ model });
}
