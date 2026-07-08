"use client";

/*
 * Quiet sign-out affordance for the access-denied page. Clears both
 * identities — the Better Auth session (real mode) and the test bypass
 * cookie (bypass mode) — then returns to sign-in.
 */
import { signOut } from "@/lib/auth/auth-client";
import { TEST_AUTH_COOKIE } from "@/lib/auth/config";

type SignOutButtonVariant = "page" | "masthead";

const variantClassName: Record<SignOutButtonVariant, string> = {
	page: "mt-3 font-mono text-[13px] text-hint underline decoration-line-strong underline-offset-4 transition-colors hover:text-accent",
	masthead:
		"font-mono text-masthead tracking-[.02em] text-hint transition-colors hover:text-accent focus-visible:text-accent",
};

export function SignOutButton({
	variant = "page",
}: {
	variant?: SignOutButtonVariant;
}) {
	const handleSignOut = async () => {
		document.cookie = `${TEST_AUTH_COOKIE}=; path=/; max-age=0`;
		await signOut().catch(() => {
			// No Better Auth session (bypass mode) — nothing to revoke.
		});
		window.location.assign("/sign-in");
	};

	return (
		<button
			type="button"
			onClick={handleSignOut}
			className={variantClassName[variant]}
		>
			sign out
		</button>
	);
}
