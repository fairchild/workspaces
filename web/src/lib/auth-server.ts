import { headers } from "next/headers";

export async function getSession() {
	const { auth } = await import("./auth");
	return auth.api.getSession({ headers: await headers() });
}
