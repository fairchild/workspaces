import { getSession } from "@/lib/auth-server";
import { getWorkspaces, syncWorkspaces } from "@/lib/workspaces";
import type { Workspace, WorkspaceStatus } from "@/lib/types";

const SYNC_API_KEY = process.env.WORKSPACE_SYNC_API_KEY;

const VALID_STATUSES: Set<string> = new Set<string>([
	"provisioning",
	"active",
	"stopped",
	"archived",
]);

/** Resolve user ID from API key header or session cookie. */
async function authenticateRequest(
	request: Request,
): Promise<string | null> {
	const authHeader = request.headers.get("authorization");
	if (authHeader?.startsWith("Bearer ") && SYNC_API_KEY) {
		const token = authHeader.slice(7);
		if (token === SYNC_API_KEY) return "default";
	}

	const session = await getSession();
	return session?.user.id ?? null;
}

function isWorkspace(v: unknown): v is Workspace {
	if (typeof v !== "object" || v === null) return false;
	const o = v as Record<string, unknown>;
	return (
		typeof o.id === "string" &&
		typeof o.name === "string" &&
		typeof o.path === "string" &&
		typeof o.status === "string" &&
		VALID_STATUSES.has(o.status) &&
		typeof o.backendIdentifier === "string"
	);
}

export async function POST(request: Request): Promise<Response> {
	const userId = await authenticateRequest(request);
	if (!userId)
		return Response.json({ error: "unauthorized" }, { status: 401 });

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

	syncWorkspaces(userId, workspaces as Workspace[]);
	return Response.json({ ok: true, count: workspaces.length });
}

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session)
		return Response.json({ error: "unauthorized" }, { status: 401 });

	// User-specific state first, fall back to API-key-synced default
	const state =
		getWorkspaces(session.user.id) ?? getWorkspaces("default");

	return Response.json({
		workspaces: state?.workspaces ?? [],
		syncedAt: state?.syncedAt ?? null,
	});
}
