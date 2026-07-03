/*
 * The authenticated shell: every route in (app) renders only for the
 * allowlisted user. Middleware already bounced signed-out requests at the
 * edge; this gate is the authoritative server-side verdict — it re-checks
 * the session (freshness "indeterminate" falls through to here) and
 * enforces the allowlist, showing the polite refusal instead of any data.
 */
import { redirect } from "next/navigation";
import { getAuthState } from "@/lib/auth/auth-state";
import { AccessDenied } from "./access-denied";

// Everything behind auth is per-request by definition; opting the whole
// group out of prerendering also keeps the build from evaluating the gate.
export const dynamic = "force-dynamic";

export default async function AppLayout({
	children,
}: Readonly<{ children: React.ReactNode }>) {
	const auth = await getAuthState();
	if (auth.kind === "unauthenticated") redirect("/sign-in");
	if (auth.kind === "forbidden") return <AccessDenied login={auth.login} />;
	return children;
}
