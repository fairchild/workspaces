/*
 * The doorway: wordmark, one GitHub button, nothing else. In test-bypass
 * mode a second quiet button signs in as the allowlisted user so e2e,
 * evidence, and local dev work without OAuth. Already signed in → home
 * (the allowlist verdict, if negative, is delivered by the app shell).
 */
import { redirect } from "next/navigation";
import { getAuthState } from "@/lib/auth/auth-state";
import { authBypassEnabled, parseAllowedLogins } from "@/lib/auth/config";
import { testSignInAction } from "./actions";
import { GitHubSignInButton } from "./github-sign-in-button";

export const dynamic = "force-dynamic";

export default async function SignInPage() {
	const auth = await getAuthState();
	if (auth.kind !== "unauthenticated") redirect("/");
	const bypass = authBypassEnabled();
	const [bypassLogin] = bypass ? parseAllowedLogins() : [];

	return (
		<main className="animate-rise flex min-h-screen flex-col items-center justify-center gap-8 px-5">
			<div className="flex flex-col items-center gap-2 text-center">
				<h1 className="font-serif text-5xl text-ink italic">Spaces</h1>
				<p className="font-mono text-[12px] tracking-[.04em] text-hint">
					coding sessions in the browser
				</p>
			</div>
			<div className="flex flex-col items-center gap-4">
				<GitHubSignInButton />
				{bypass && bypassLogin && (
					<form action={testSignInAction}>
						<button
							type="submit"
							className="font-mono text-[12px] text-hint underline decoration-line-strong underline-offset-4 transition-colors hover:text-accent"
						>
							continue as {bypassLogin} (test bypass)
						</button>
					</form>
				)}
			</div>
		</main>
	);
}
