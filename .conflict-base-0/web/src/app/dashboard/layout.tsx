import { getSession } from "@/lib/auth-server";
import Image from "next/image";
import Link from "next/link";
import { redirect } from "next/navigation";
import { PostHogUserIdentify } from "./components/posthog-user-identify";
import { SignOutButton } from "./components/sign-out-button";
import styles from "./layout.module.css";

export const dynamic = "force-dynamic";

export default async function DashboardLayout({
	children,
}: {
	children: React.ReactNode;
}) {
	const session = await getSession();
	if (!session) redirect("/sign-in");

	const { hasUserRepos } = await import("@/lib/repos");
	if (!(await hasUserRepos(session.user.id))) redirect("/setup");

	return (
		<div className={styles.shell}>
			<PostHogUserIdentify
				id={session.user.id}
				email={session.user.email}
				name={session.user.name}
			/>
			<header className={styles.topBar}>
				<Link href="/dashboard" className={styles.brand}>
					Spaces
				</Link>
				<div className={styles.user}>
					{session.user.image && (
						<Image
							src={session.user.image}
							alt=""
							className={styles.avatar}
							width={24}
							height={24}
						/>
					)}
					<span className={styles.userName}>{session.user.name}</span>
					<SignOutButton />
				</div>
			</header>
			{children}
		</div>
	);
}
