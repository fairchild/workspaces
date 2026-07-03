/*
 * Kysely dialect for libSQL/Turso. Ported by copy from the legacy web/ app
 * (web/src/lib/libsql-dialect.ts) — it encodes the working driver/connection
 * wiring against @libsql/client that the query builder needs. Kept as its own
 * file so the schema and store code depend on a stable seam.
 */
import type { Client, InValue } from "@libsql/client";
import {
	type DatabaseIntrospector,
	type Dialect,
	type DialectAdapter,
	type Driver,
	type Kysely,
	type QueryCompiler,
	SqliteAdapter,
	SqliteIntrospector,
	SqliteQueryCompiler,
} from "kysely";

class LibsqlDriver implements Driver {
	constructor(private client: Client) {}
	async init() {}
	async acquireConnection() {
		return new LibsqlConnection(this.client);
	}
	async beginTransaction(conn: LibsqlConnection) {
		conn.transaction = await this.client.transaction("deferred");
	}
	async commitTransaction(conn: LibsqlConnection) {
		await conn.transaction?.commit();
		conn.transaction = undefined;
	}
	async rollbackTransaction(conn: LibsqlConnection) {
		await conn.transaction?.rollback();
		conn.transaction = undefined;
	}
	async releaseConnection() {}
	async destroy() {
		this.client.close();
	}
}

class LibsqlConnection {
	transaction?: Awaited<ReturnType<Client["transaction"]>>;
	constructor(private client: Client) {}

	async executeQuery<R>(query: {
		sql: string;
		parameters: readonly unknown[];
	}) {
		const target = this.transaction ?? this.client;
		const result = await target.execute({
			sql: query.sql,
			args: query.parameters as InValue[],
		});
		return {
			rows: (result.rows as unknown as R[]) ?? [],
			numAffectedRows: BigInt(result.rowsAffected),
			insertId:
				result.lastInsertRowid != null
					? BigInt(result.lastInsertRowid.toString())
					: undefined,
		};
	}

	async *streamQuery(): AsyncGenerator<never> {
		throw new Error("Streaming not supported with libSQL");
	}
}

export class LibsqlDialect implements Dialect {
	constructor(private config: { client: Client }) {}
	createAdapter(): DialectAdapter {
		return new SqliteAdapter();
	}
	createDriver(): Driver {
		return new LibsqlDriver(this.config.client);
	}
	// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Kysely's Dialect interface requires Kysely<any>
	createIntrospector(db: Kysely<any>): DatabaseIntrospector {
		return new SqliteIntrospector(db);
	}
	createQueryCompiler(): QueryCompiler {
		return new SqliteQueryCompiler();
	}
}
