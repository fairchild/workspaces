import { getSession } from "@/lib/auth-server";
import { PostHogUserIdentify } from "../dashboard/components/posthog-user-identify";

export default async function SetupLayout({
	children,
}: {
	children: React.ReactNode;
}) {
	const session = await getSession();

	return (
		<>
			{session ? (
				<PostHogUserIdentify
					id={session.user.id}
					email={session.user.email}
					name={session.user.name}
				/>
			) : null}
			{children}
		</>
	);
}
