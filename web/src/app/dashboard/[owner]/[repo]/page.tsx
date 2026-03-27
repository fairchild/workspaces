import { DashboardShell } from "../../components/dashboard-shell";

export default async function RepoPage({
	params,
	searchParams,
}: {
	params: Promise<{ owner: string; repo: string }>;
	searchParams: Promise<{ tab?: string }>;
}) {
	const { owner, repo } = await params;
	const { tab } = await searchParams;
	return <DashboardShell selectedRepo={{ owner, repo }} initialTab={tab} />;
}
