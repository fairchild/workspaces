import { DashboardShell } from "../../components/dashboard-shell";

export default async function RepoPage({
	params,
}: { params: Promise<{ owner: string; repo: string }> }) {
	const { owner, repo } = await params;
	return <DashboardShell selectedRepo={{ owner, repo }} />;
}
