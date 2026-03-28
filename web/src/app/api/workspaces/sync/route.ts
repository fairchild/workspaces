import { type SyncWorkspaceInput, syncWorkspaces } from "@/lib/workspaces";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
	const token = request.headers.get("authorization")?.replace("Bearer ", "");
	const expected = process.env.WORKSPACE_SYNC_TOKEN;
	if (!expected || token !== expected) {
		return new Response("unauthorized", { status: 401 });
	}

	const body = (await request.json()) as { workspaces?: SyncWorkspaceInput[] };
	if (!Array.isArray(body.workspaces)) {
		return Response.json(
			{ error: "workspaces array required" },
			{ status: 400 },
		);
	}

	const count = await syncWorkspaces(body.workspaces);
	return Response.json({ ok: true, synced: count });
}
