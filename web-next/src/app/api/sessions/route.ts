/*
 * POST /api/sessions — programmatic session creation, the API complement to
 * the UI's server action (actions.ts). Exists for API clients that need a
 * throwaway session with an explicit title and provider — the #818 real-turn
 * validation probe is the first — so it skips the action's GitHub repo
 * resolution (repoId stays null; the vercel provider falls back to its
 * configured AGENT_TARGET_REPO only for these repo-less sessions). Auth-gated
 * like every session route; model always starts at the DEFAULT_MODEL, same as
 * the UI path.
 */
import { getProvider } from "@/lib/agent-runtime/provider";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { createSession } from "@/lib/db/sessions";
import { defaultComputeProvider } from "@/lib/db/start-session";
import { cleanTitleText, MAX_TITLE_LENGTH } from "@/lib/session-title";

export const runtime = "nodejs";

export async function POST(request: Request) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const body: unknown = await request.json().catch(() => undefined);
	if (typeof body !== "object" || body === null) {
		return Response.json({ error: "a JSON body is required" }, { status: 400 });
	}
	const { title: rawTitle, provider: rawProvider, ...rest } = body as {
		title?: unknown;
		provider?: unknown;
	};
	const unknownFields = Object.keys(rest);
	if (unknownFields.length > 0) {
		return Response.json(
			{ error: `unknown field(s): ${unknownFields.join(", ")}` },
			{ status: 400 },
		);
	}

	let title = "";
	if (rawTitle !== undefined) {
		if (typeof rawTitle !== "string") {
			return Response.json({ error: "title must be a string" }, { status: 400 });
		}
		title = cleanTitleText(rawTitle);
		if (title.length > MAX_TITLE_LENGTH) {
			return Response.json(
				{ error: `title must be at most ${MAX_TITLE_LENGTH} characters` },
				{ status: 400 },
			);
		}
	}

	let provider = defaultComputeProvider();
	if (rawProvider !== undefined) {
		provider = String(rawProvider);
		try {
			getProvider(provider);
		} catch {
			return Response.json(
				{ error: `unknown provider: ${provider}` },
				{ status: 400 },
			);
		}
	}

	const session = await createSession(getDatabase(), {
		id: crypto.randomUUID(),
		ownerLogin: auth.user.login,
		title,
		provider,
	});
	return Response.json(
		{
			id: session.id,
			title: session.title,
			provider: session.provider,
			model: session.model,
			status: session.status,
			createdAt: session.createdAt,
		},
		{ status: 201 },
	);
}
