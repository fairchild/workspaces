/*
 * The doorway: GitHub OAuth in production, the quiet test bypass in harness
 * mode, or a local token paste box under WEB_NEXT_LOCAL_MODE. Already signed
 * in → home (the allowlist verdict, if negative, is delivered by the shell).
 */
import { redirect } from "next/navigation";
import { getAuthState } from "@/lib/auth/auth-state";
import {
	authBypassEnabled,
	localModeEnabled,
	parseAllowedLogins,
} from "@/lib/auth/config";
import { safeRedirectPath } from "@/lib/auth/redirect-path";
import { localSignInAction, testSignInAction } from "./actions";
import { GitHubSignInButton } from "./github-sign-in-button";

export const dynamic = "force-dynamic";

export default async function SignInPage({
	searchParams,
}: {
	searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
	const auth = await getAuthState();
	if (auth.kind !== "unauthenticated") redirect("/");
	const params = await searchParams;
	const redirectPath = safeRedirectPath(
		typeof params.redirect === "string" ? params.redirect : "",
	);
	const local = localModeEnabled();
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
				{local ? (
					<form action={localSignInAction} className="flex w-full max-w-sm flex-col gap-3">
						{/* Deep-link continuation (#987) — re-validated in the action. */}
						<input type="hidden" name="redirect" value={redirectPath} />
						<input
							name="token"
							type="password"
							required
							autoComplete="off"
							placeholder="local sign-in token"
							className="rounded-md border border-line bg-transparent px-3 py-2 font-mono text-[13px] text-ink outline-none transition-colors placeholder:text-hint focus:border-focus-line"
						/>
						<button
							type="submit"
							className="rounded-md border border-line px-3 py-2 font-mono text-[12px] text-ink transition-colors hover:border-focus-line hover:text-accent"
						>
							continue locally
						</button>
					</form>
				) : (
					<GitHubSignInButton />
				)}
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
