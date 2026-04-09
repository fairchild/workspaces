/**
 * Temporary diagnostic endpoint. The dashboard hierarchy is throwing
 * empty 500s and the DB layer is the most likely culprit. Vercel
 * function logs aren't easily accessible from a dev session, so this
 * endpoint runs a series of DB probes and returns the first real
 * error it sees, with the exception text and stack.
 *
 * DELETE THIS ENDPOINT once the outage is diagnosed. It intentionally
 * exposes DB error details which you don't want in long-lived
 * production code.
 */

import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

function probe(name: string, fn: () => Promise<unknown>) {
	return fn().then(
		(ok) => ({ name, status: "ok", result: ok }),
		(err: unknown) => ({
			name,
			status: "error",
			error:
				err instanceof Error
					? { message: err.message, name: err.name, stack: err.stack }
					: { message: String(err) },
		}),
	);
}

export async function GET() {
	const env = {
		TURSO_DATABASE_URL_present: !!process.env.TURSO_DATABASE_URL,
		TURSO_DATABASE_URL_length: process.env.TURSO_DATABASE_URL?.length ?? 0,
		TURSO_DATABASE_URL_host: process.env.TURSO_DATABASE_URL?.replace(
			/[?#].*/,
			"",
		).slice(0, 60),
		TURSO_AUTH_TOKEN_present: !!process.env.TURSO_AUTH_TOKEN,
		TURSO_AUTH_TOKEN_length: process.env.TURSO_AUTH_TOKEN?.length ?? 0,
		BETTER_AUTH_SECRET_present: !!process.env.BETTER_AUTH_SECRET,
		NODE_ENV: process.env.NODE_ENV,
		VERCEL_ENV: process.env.VERCEL_ENV,
	};

	const probes = await Promise.all([
		probe("import_db_module", async () => {
			const db = await import("@/lib/db");
			return { exports: Object.keys(db).slice(0, 20) };
		}),
		probe("getTurso_construct", async () => {
			const { getTurso } = await import("@/lib/db");
			const t = getTurso();
			return { hasExecute: typeof t.execute === "function" };
		}),
		probe("trivial_select", async () => {
			const { getTurso } = await import("@/lib/db");
			const r = await getTurso().execute("SELECT 1 as n");
			return { rows: r.rows.length, sample: r.rows[0] };
		}),
		probe("sqlite_master_count", async () => {
			const { getTurso } = await import("@/lib/db");
			const r = await getTurso().execute(
				"SELECT count(*) as c FROM sqlite_master",
			);
			return { count: r.rows[0]?.c };
		}),
		probe("list_tables", async () => {
			const { getTurso } = await import("@/lib/db");
			const r = await getTurso().execute(
				"SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
			);
			return { tables: r.rows.map((row) => row.name) };
		}),
		probe("user_repos_table", async () => {
			const { getTurso } = await import("@/lib/db");
			const r = await getTurso().execute(
				"SELECT count(*) as c FROM user_repos",
			);
			return { count: r.rows[0]?.c };
		}),
	]);

	return NextResponse.json({ env, probes }, { status: 200 });
}
