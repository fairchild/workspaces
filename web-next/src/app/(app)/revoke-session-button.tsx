"use client";

/*
 * Script-side sign-out for the doors whose identity script can reach: the
 * Better Auth session (real mode) and the test-bypass cookie. Local mode does
 * not come through here — its session cookie is HttpOnly, so it exits through
 * the /sign-out route instead (see sign-out-button.tsx).
 */
import { signOut } from "@/lib/auth/auth-client";
import { TEST_AUTH_COOKIE } from "@/lib/auth/config";

export function RevokeSessionButton({ className }: { className: string }) {
	const handleSignOut = async () => {
		document.cookie = `${TEST_AUTH_COOKIE}=; path=/; max-age=0`;
		await signOut().catch(() => {
			// No Better Auth session (bypass mode) — nothing to revoke.
		});
		window.location.assign("/sign-in");
	};

	return (
		<button type="button" onClick={handleSignOut} className={className}>
			sign out
		</button>
	);
}
