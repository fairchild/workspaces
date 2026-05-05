import { validateProductionAuthConfig } from "@/lib/agent-runtime/config";
import type { NextRequest } from "next/server";

export const dynamic = "force-dynamic";

async function handler(request: NextRequest) {
	validateProductionAuthConfig();
	const { auth } = await import("@/lib/auth");
	const { toNextJsHandler } = await import("better-auth/next-js");
	const { GET: get, POST: post } = toNextJsHandler(auth);
	if (request.method === "POST") return post(request);
	return get(request);
}

export { handler as GET, handler as POST };
