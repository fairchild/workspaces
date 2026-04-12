import posthog from "posthog-js";

type PostHogPropertyValue = string | number | boolean | null | undefined;

export type PostHogProperties = Record<string, PostHogPropertyValue>;

export function isPostHogEnabled() {
	return Boolean(process.env.NEXT_PUBLIC_POSTHOG_TOKEN);
}

export function capturePostHogEvent(
	event: string,
	properties?: PostHogProperties,
) {
	if (!isPostHogEnabled()) return;
	posthog.capture(event, properties);
}

export function identifyPostHogUser(
	distinctId: string,
	properties?: PostHogProperties,
) {
	if (!isPostHogEnabled()) return;
	posthog.identify(distinctId, properties);
}

export function resetPostHogUser() {
	if (!isPostHogEnabled()) return;
	posthog.reset();
}
