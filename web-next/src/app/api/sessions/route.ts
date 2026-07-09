/*
 * POST /api/sessions — programmatic session creation, the API complement to
 * the UI's server action (actions.ts). An optional `repo` (owner/name) runs
 * the same GitHub validation + resolution as the UI path (#987 embedded
 * shell); omitted, it keeps the original repo-less behavior for API clients
 * that need a throwaway session — the #818 real-turn validation probe is the
 * first (repoId stays null; the vercel provider falls back to its configured
 * AGENT_TARGET_REPO only for these repo-less sessions). Auth-gated like every
 * session route; model always starts at the DEFAULT_MODEL, same as the UI.
 */
import { getProvider } from "@/lib/agent-runtime/provider";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { createSession } from "@/lib/db/sessions";
import {
	defaultComputeProvider,
	isValidRepoFullName,
	PATH_PARAM_UNSUPPORTED,
	RepoUnavailableError,
	startSession,
} from "@/lib/db/start-session";
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
	const {
		title: rawTitle,
		provider: rawProvider,
		repo: rawRepo,
		path: rawPath,
		...rest
	} = body as {
		title?: unknown;
		provider?: unknown;
		repo?: unknown;
		path?: unknown;
	};
	// Reserved by the embedded-native contract for Milestone 2 — refused
	// loudly so a shell that sends it early gets told, not silently unbound.
	if (rawPath !== undefined) {
		return Response.json({ error: PATH_PARAM_UNSUPPORTED }, { status: 400 });
	}
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

	let repo: string | undefined;
	if (rawRepo !== undefined) {
		if (typeof rawRepo !== "string" || !isValidRepoFullName(rawRepo.trim())) {
			return Response.json(
				{ error: "repo must be an owner/name repository" },
				{ status: 400 },
			);
		}
		repo = rawRepo.trim();
	}

	let session;
	if (repo !== undefined) {
		// Same validation + resolution as the UI create path (start-session.ts).
		try {
			session = await startSession(getDatabase(), repo, {
				ownerLogin: auth.user.login,
				title,
				provider,
			});
		} catch (error) {
			if (error instanceof RepoUnavailableError) {
				return Response.json(
					{ error: `${repo} doesn't exist or isn't accessible` },
					{ status: 404 },
				);
			}
			throw error;
		}
	} else {
		session = await createSession(getDatabase(), {
			id: crypto.randomUUID(),
			ownerLogin: auth.user.login,
			title,
			provider,
		});
	}
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
