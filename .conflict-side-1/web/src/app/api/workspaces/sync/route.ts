import { timingSafeEqual } from "node:crypto";
import { getSession } from "@/lib/auth-server";
import { isWorkspace } from "@/lib/workspace-utils";
import {
	type SyncWorkspaceInput,
	getWorkspaces,
	syncWorkspaces,
} from "@/lib/workspaces";

const SYNC_API_KEY = process.env.WORKSPACE_SYNC_API_KEY;

function safeEqual(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

/** Resolve user ID from API key header or session cookie. */
async function authenticateRequest(request: Request): Promise<string | null> {
	const authHeader = request.headers.get("authorization");
	if (authHeader?.startsWith("Bearer ") && SYNC_API_KEY) {
		const token = authHeader.slice(7);
		if (safeEqual(token, SYNC_API_KEY)) return "default";
	}

	const session = await getSession();
	return session?.user.id ?? null;
}

export async function POST(request: Request): Promise<Response> {
	const userId = await authenticateRequest(request);
	if (!userId) return Response.json({ error: "unauthorized" }, { status: 401 });

	let body: unknown;
	try {
		body = await request.json();
	} catch {
		return Response.json({ error: "invalid JSON" }, { status: 400 });
	}

	const { workspaces } = body as { workspaces?: unknown };
	if (!Array.isArray(workspaces)) {
		return Response.json(
			{ error: "workspaces must be an array" },
			{ status: 400 },
		);
	}

	for (const w of workspaces) {
		if (!isWorkspace(w)) {
			return Response.json(
				{ error: "invalid workspace object", detail: w },
				{ status: 422 },
			);
		}
	}

	const count = await syncWorkspaces(workspaces as SyncWorkspaceInput[]);
	return Response.json({ ok: true, count });
}

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session)
		return Response.json({ error: "unauthorized" }, { status: 401 });

	const workspaces = await getWorkspaces();

	return Response.json({ workspaces });
}
