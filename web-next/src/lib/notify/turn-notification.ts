/*
 * Sends detached-turn completion notices to the owner-configured webhook.
 * The ingest loop calls this after the terminal events are durable so a
 * finished, failed, or stopped background turn can find the owner even when no
 * browser is attached.
 */
import type { Session } from "../db/sessions";

export type TurnNotificationOutcome = "completed" | "failed" | "stopped";

export interface TurnNotificationPayload {
	event: "turn_completed";
	sessionId: string;
	title: string;
	repo: string;
	outcome: TurnNotificationOutcome;
	durationMs: number;
	url?: string;
}

type TurnNotificationFetch = typeof fetch;
interface TurnNotificationEnv {
	[key: string]: string | undefined;
	BETTER_AUTH_URL?: string;
	WEB_NEXT_NOTIFY_TOKEN?: string;
	WEB_NEXT_NOTIFY_URL?: string;
}

export interface TurnNotificationInput {
	session: Pick<Session, "id" | "title">;
	/** The repo's `owner/name` — resolved by the caller; sessions store only
	 * the repo row id, which means nothing in a phone notification. */
	repoFullName?: string | null;
	outcome: TurnNotificationOutcome;
	durationMs: number;
}

export interface TurnNotificationOptions {
	env?: TurnNotificationEnv;
	fetch?: TurnNotificationFetch;
	logger?: Pick<Console, "error">;
	timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 3_000;

export async function notifyTurnCompleted(
	input: TurnNotificationInput,
	options: TurnNotificationOptions = {},
): Promise<void> {
	const env = options.env ?? runtimeEnv();
	const notifyUrl = env.WEB_NEXT_NOTIFY_URL;
	if (!notifyUrl) return;

	const logger = options.logger ?? console;
	const fetchImpl = options.fetch ?? globalThis.fetch;
	const controller = new AbortController();
	const timeout = setTimeout(
		() => controller.abort(),
		options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
	);

	try {
		const response = await fetchImpl(notifyUrl, {
			body: JSON.stringify(buildTurnNotificationPayload(input, env)),
			headers: headers(env),
			method: "POST",
			signal: controller.signal,
		});
		if (!response.ok) {
			logger.error(
				`[turn-notification] webhook returned ${response.status} ${response.statusText}`,
			);
		}
	} catch (error) {
		logger.error("[turn-notification] webhook delivery failed", error);
	} finally {
		clearTimeout(timeout);
	}
}

export function buildTurnNotificationPayload(
	input: TurnNotificationInput,
	env: Pick<TurnNotificationEnv, "BETTER_AUTH_URL"> = runtimeEnv(),
): TurnNotificationPayload {
	return {
		event: "turn_completed",
		sessionId: input.session.id,
		title: input.session.title,
		repo: input.repoFullName ?? "",
		outcome: input.outcome,
		durationMs: input.durationMs,
		...(env.BETTER_AUTH_URL ? { url: sessionUrl(env.BETTER_AUTH_URL, input.session.id) } : {}),
	};
}

function headers(env: Pick<TurnNotificationEnv, "WEB_NEXT_NOTIFY_TOKEN">): HeadersInit {
	return {
		"content-type": "application/json",
		...(env.WEB_NEXT_NOTIFY_TOKEN
			? { authorization: `Bearer ${env.WEB_NEXT_NOTIFY_TOKEN}` }
			: {}),
	};
}

function sessionUrl(baseUrl: string, sessionId: string): string {
	return `${baseUrl.replace(/\/+$/, "")}/sessions/${encodeURIComponent(sessionId)}`;
}

function runtimeEnv(): TurnNotificationEnv {
	return {
		BETTER_AUTH_URL: process.env.BETTER_AUTH_URL,
		WEB_NEXT_NOTIFY_TOKEN: process.env.WEB_NEXT_NOTIFY_TOKEN,
		WEB_NEXT_NOTIFY_URL: process.env.WEB_NEXT_NOTIFY_URL,
	};
}
