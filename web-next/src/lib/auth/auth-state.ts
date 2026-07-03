/*
 * Server-side auth resolution: who is this request, and are they let in?
 * The single-user allowlist is enforced here (middleware only checks session
 * freshness), so every page/action shares one verdict shape. In bypass mode
 * (see config.ts) identity rides in a test cookie; in real mode it comes
 * from the Better Auth session's persisted GitHub login.
 */
import { cookies, headers } from "next/headers";
import { getDatabase } from "../db/client";
import { ensureSchema } from "../db/schema";
import { authBypassEnabled, isLoginAllowed, TEST_AUTH_COOKIE } from "./config";

export type AuthState =
	| { kind: "unauthenticated" }
	/** Signed in, but not on the allowlist — show the polite refusal, no data. */
	| { kind: "forbidden"; login: string }
	| { kind: "authorized"; user: { login: string; name: string } };

function verdict(login: string, name: string): AuthState {
	if (!isLoginAllowed(login)) return { kind: "forbidden", login };
	return { kind: "authorized", user: { login: login.toLowerCase(), name } };
}

export async function getAuthState(): Promise<AuthState> {
	if (authBypassEnabled()) {
		const login = (await cookies()).get(TEST_AUTH_COOKIE)?.value ?? "";
		if (!login) return { kind: "unauthenticated" };
		return verdict(login, login);
	}

	const handle = getDatabase();
	await ensureSchema(handle); // Better Auth tables live in our migrations.
	const { getAuth } = await import("./auth");
	const session = await getAuth().api.getSession({ headers: await headers() });
	if (!session) return { kind: "unauthenticated" };
	const user = session.user as typeof session.user & {
		githubLogin?: string | null;
	};
	// No persisted login (shouldn't happen via the GitHub provider) fails
	// closed: an empty login is never on the allowlist.
	return verdict(user.githubLogin ?? "", user.name || (user.githubLogin ?? ""));
}

/** For server actions: the authorized user, or an error (no partial access). */
export async function requireAuthorizedUser(): Promise<{
	login: string;
	name: string;
}> {
	const state = await getAuthState();
	if (state.kind !== "authorized") {
		throw new Error("not signed in as the allowed user");
	}
	return state.user;
}
