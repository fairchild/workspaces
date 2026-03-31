/** GitHub logins allowed to trigger agent compute sessions. */
export const ALLOWED_AGENT_LOGINS = new Set(
	(process.env.ALLOWED_AGENT_LOGINS ?? "fairchild")
		.split(",")
		.map((s) => s.trim())
		.filter(Boolean),
);
