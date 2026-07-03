"use server";

/*
 * Test-bypass sign-in: sets the acting-login cookie and enters the app.
 * Hard-guarded by authBypassEnabled() — with real OAuth configured (or
 * without AUTH_BYPASS=1) this action refuses, so it is inert in production.
 */
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import {
	authBypassEnabled,
	parseAllowedLogins,
	TEST_AUTH_COOKIE,
} from "@/lib/auth/config";

export async function testSignInAction(): Promise<void> {
	if (!authBypassEnabled()) {
		throw new Error("test sign-in is disabled outside bypass mode");
	}
	const [login] = parseAllowedLogins();
	if (!login) throw new Error("ALLOWED_LOGINS is empty — nobody to sign in as");
	(await cookies()).set(TEST_AUTH_COOKIE, login, { path: "/" });
	redirect("/");
}
