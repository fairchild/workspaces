import { headers } from "next/headers";

export async function getSession() {
	if (
		process.env.NODE_ENV === "development" &&
		process.env.DEV_BYPASS_AUTH === "1"
	) {
		return {
			user: {
				id: "dev-user",
				name: "Dev User",
				email: "dev@localhost",
				image: null,
				createdAt: new Date(),
				updatedAt: new Date(),
				emailVerified: false,
			},
			session: {
				id: "dev-session",
				expiresAt: new Date(Date.now() + 86400000),
			},
		};
	}
	const { auth } = await import("./auth");
	return auth.api.getSession({ headers: await headers() });
}
