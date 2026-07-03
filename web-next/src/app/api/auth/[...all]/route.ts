/*
 * Better Auth handler (real OAuth mode): /api/auth/* — sign-in social flow,
 * GitHub callback, session, sign-out. Lazy imports keep Better Auth and the
 * database out of the build graph; the schema is ensured here because Better
 * Auth queries its tables directly (store methods aren't in the path).
 */
import type { NextRequest } from "next/server";

export const dynamic = "force-dynamic";

async function handler(request: NextRequest) {
	const [{ getDatabase }, { ensureSchema }] = await Promise.all([
		import("@/lib/db/client"),
		import("@/lib/db/schema"),
	]);
	await ensureSchema(getDatabase());
	const { getAuth } = await import("@/lib/auth/auth");
	const { toNextJsHandler } = await import("better-auth/next-js");
	const { GET: get, POST: post } = toNextJsHandler(getAuth());
	if (request.method === "POST") return post(request);
	return get(request);
}

export { handler as GET, handler as POST };
