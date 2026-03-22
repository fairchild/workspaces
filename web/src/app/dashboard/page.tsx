import { getSession } from "@/lib/auth-server";
import { ActivityFeed } from "./components/activity-feed";
import { MainPanel } from "./components/main-panel";
import { Sidebar } from "./components/sidebar";
import styles from "./page.module.css";

export default async function Dashboard() {
	const session = await getSession();

	return (
		<div className={styles.columns}>
			<aside className={styles.left}>
				<Sidebar />
			</aside>
			<main className={styles.center}>
				<MainPanel userName={session?.user.name ?? "there"} />
			</main>
			<aside className={styles.right}>
				<ActivityFeed />
			</aside>
		</div>
	);
}
