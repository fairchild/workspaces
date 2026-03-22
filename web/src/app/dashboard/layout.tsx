import { getSession } from "@/lib/auth-server";
import { redirect } from "next/navigation";
import styles from "./layout.module.css";

export default async function DashboardLayout({
	children,
}: {
	children: React.ReactNode;
}) {
	const session = await getSession();
	if (!session) redirect("/sign-in");

	return (
		<div className={styles.shell}>
			<header className={styles.topBar}>
				<span className={styles.brand}>Spaces</span>
				<div className={styles.user}>
					{session.user.image && (
						<img
							src={session.user.image}
							alt=""
							className={styles.avatar}
							width={24}
							height={24}
						/>
					)}
					<span className={styles.userName}>{session.user.name}</span>
				</div>
			</header>
			{children}
		</div>
	);
}
