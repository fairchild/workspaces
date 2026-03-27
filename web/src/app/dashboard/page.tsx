import { DashboardShell } from "./components/dashboard-shell";

export default async function DashboardPage({
	searchParams,
}: { searchParams: Promise<{ tab?: string }> }) {
	const { tab } = await searchParams;
	return <DashboardShell selectedRepo={null} initialTab={tab} />;
}
