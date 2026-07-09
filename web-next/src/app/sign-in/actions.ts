"use server";

/*
 * Sign-in actions for non-OAuth doors: the test bypass used by e2e/perf, and
 * owner-local mode's minted bearer token. Both are hard-guarded by their mode
 * switches so neither action can silently become a production auth path.
 */
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import {
	authBypassEnabled,
	LOCAL_AUTH_COOKIE,
	localModeEnabled,
	parseAllowedLogins,
	TEST_AUTH_COOKIE,
} from "@/lib/auth/config";
import { localSignInTokenMatches } from "@/lib/auth/local-token";

export async function testSignInAction(): Promise<void> {
	if (!authBypassEnabled()) {
		throw new Error("test sign-in is disabled outside bypass mode");
	}
	const [login] = parseAllowedLogins();
	if (!login) throw new Error("ALLOWED_LOGINS is empty — nobody to sign in as");
	(await cookies()).set(TEST_AUTH_COOKIE, login, { path: "/" });
	redirect("/");
}

export async function localSignInAction(formData: FormData): Promise<void> {
	if (!localModeEnabled()) {
		throw new Error("local sign-in is disabled outside local mode");
	}
	const token = String(formData.get("token") ?? "");
	if (!localSignInTokenMatches(token)) {
		throw new Error("invalid local sign-in token");
	}
	(await cookies()).set(LOCAL_AUTH_COOKIE, token.trim(), {
		path: "/",
		httpOnly: true,
		sameSite: "lax",
		secure: false,
	});
	redirect("/");
}
