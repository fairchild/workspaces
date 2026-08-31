/*
 * The sign-out affordance, and the one place that picks which door it opens.
 * Local mode's session cookie is HttpOnly, so the button posts to /sign-out
 * and lets the server expire it (#1488); every other mode's identity is
 * script-reachable and exits through RevokeSessionButton. Reading the mode
 * here keeps call sites — masthead and access-denied alike — unaware of it.
 */
import { localModeEnabled } from "@/lib/auth/config";
import { RevokeSessionButton } from "./revoke-session-button";

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
	const className = variantClassName[variant];
	if (!localModeEnabled()) return <RevokeSessionButton className={className} />;
	return (
		<form action="/sign-out" method="post" className="flex">
			<button type="submit" className={className}>
				sign out
			</button>
		</form>
	);
}
