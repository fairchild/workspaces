import { timingSafeEqual } from "node:crypto";
import { unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import { isWorkspace } from "@/lib/workspace-utils";
import {
	DEFAULT_WORKSPACE_OWNER_ID,
	type SyncWorkspaceInput,
	getWorkspaces,
	syncWorkspaces,
} from "@/lib/workspaces";

function safeEqual(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

function syncApiKey(): string | undefined {
	return process.env.WORKSPACE_SYNC_API_KEY;
}

function hasSyncApiKey(request: Request): boolean {
	const authHeader = request.headers.get("authorization");
	const key = syncApiKey();
	if (authHeader?.startsWith("Bearer ") && key) {
		const token = authHeader.slice(7);
		return safeEqual(token, key);
	}
	return false;
}

async function readOwnerId(request: Request): Promise<string | null> {
	if (hasSyncApiKey(request)) return DEFAULT_WORKSPACE_OWNER_ID;
	const session = await getSession();
	return session?.user.id ?? null;
}

export async function POST(request: Request): Promise<Response> {
	if (!hasSyncApiKey(request)) return unauthorizedResponse();

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

	const count = await syncWorkspaces(
		DEFAULT_WORKSPACE_OWNER_ID,
		workspaces as SyncWorkspaceInput[],
	);
	return Response.json({ ok: true, count });
}

export async function GET(request: Request): Promise<Response> {
	const ownerId = await readOwnerId(request);
	if (!ownerId) return unauthorizedResponse();

	const workspaces = await getWorkspaces(ownerId);

	return Response.json({ workspaces });
}
