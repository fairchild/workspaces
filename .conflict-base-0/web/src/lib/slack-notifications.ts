import { getSlackAdapter } from "./bot";

/**
 * Slack channel ID for posting workspace notifications.
 * Set SLACK_NOTIFICATION_CHANNEL to a channel ID (e.g., C0123456789).
 */
function getNotificationChannel(): string | null {
	return process.env.SLACK_NOTIFICATION_CHANNEL ?? null;
}

/** Post a message to the notification channel. No-op if Slack is not configured. */
async function postToChannel(text: string): Promise<void> {
	const adapter = getSlackAdapter();
	const channel = getNotificationChannel();
	if (!adapter || !channel) return;

	const channelId = `slack:${channel}`;
	await adapter.postChannelMessage(channelId, text);
}

/** Notify on CI build / workflow failure. */
export async function notifyBuildFailure(
	repo: string,
	name: string,
	conclusion: string,
	url: string,
): Promise<void> {
	if (conclusion !== "failure") return;
	await postToChannel(
		`🔴 *Build failed* in \`${repo}\`\n*${name}* — <${url}|View run>`,
	);
}

/** Notify when a PR review is requested. */
export async function notifyReviewRequested(
	repo: string,
	prNumber: number,
	prTitle: string,
	reviewer: string,
	url: string,
): Promise<void> {
	await postToChannel(
		`👀 *Review requested* in \`${repo}\`\n<${url}|#${prNumber}: ${prTitle}> — reviewer: *${reviewer}*`,
	);
}
