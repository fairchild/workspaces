import type { WebhookEvent } from "./types";

const MAX_EVENTS = 100;
const events: WebhookEvent[] = [];

export function pushEvent(event: WebhookEvent): void {
	events.unshift(event);
	if (events.length > MAX_EVENTS) events.length = MAX_EVENTS;
}

export function getEvents(limit = 50): WebhookEvent[] {
	return events.slice(0, limit);
}
