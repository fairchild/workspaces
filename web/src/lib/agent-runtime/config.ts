/** GitHub logins allowed to trigger agent compute sessions. */
export const ALLOWED_AGENT_LOGINS = new Set(
	(process.env.ALLOWED_AGENT_LOGINS ?? "fairchild")
		.split(",")
		.map((s) => s.trim())
		.filter(Boolean),
);

/** Agent name to use when no @mention is provided. Null disables default routing. */
export const DEFAULT_AGENT: string | null = process.env.DEFAULT_AGENT ?? null;
