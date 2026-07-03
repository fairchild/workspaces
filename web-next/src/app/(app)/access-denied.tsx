/*
 * The polite "not yours" page: shown to an authenticated user who is not
 * on the allowlist. No session data is rendered anywhere beneath it — the
 * (app) layout returns this instead of children.
 */
import { SignOutButton } from "./sign-out-button";

export function AccessDenied({ login }: { login: string }) {
	return (
		<main className="animate-rise flex min-h-screen flex-col items-center justify-center gap-3 px-5 text-center">
			<h1 className="font-serif text-3xl text-ink italic">
				This is someone else&rsquo;s studio.
			</h1>
			<p className="max-w-[46ch] font-mono text-[13px] leading-relaxed text-muted">
				You&rsquo;re signed in as <b className="text-ink">{login}</b>, but this
				deployment belongs to a single person — and that isn&rsquo;t you.
			</p>
			<SignOutButton />
		</main>
	);
}
