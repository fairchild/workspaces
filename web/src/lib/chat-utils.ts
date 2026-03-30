export function parseAgentMention(message: string): string | null {
	const match = message.match(/^@(\w[\w-]*)/);
	return match ? match[1] : null;
}

export function stripMention(message: string): string {
	return message.replace(/^@\w[\w-]*\s*/, "").trim();
}

export function parseIssueRef(task: string): string | null {
	const match = task.match(/#(\d+)/);
	return match ? `#${match[1]}` : null;
}

export function formatDispatchBody(
	agent: string,
	task: string,
	issueRef: string | null,
	taskId: string,
): string {
	const lines = [
		`**Agent:** @${agent}`,
		`**Task:** ${task}`,
		`**Task ID:** \`${taskId}\``,
	];
	if (issueRef) {
		lines.push(`**Issue:** ${issueRef}`);
	}
	lines.push(
		"",
		"---",
		"*Dispatched from [Spaces](https://spaces.cloudcompute.com) chat*",
	);
	return lines.join("\n");
}
