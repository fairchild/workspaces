// Owns the production CD issue policy for cd.yml: one open issue per prod
// surface while failing, and close auto-opened prod issues once prod validates.

import nodeFs from "node:fs";

const prodSurfaceLabel = "cd-failure:prod";
const marker = `<!-- ${prodSurfaceLabel} -->`;
const prodUrl = "https://spaces.cloudcompute.com";
const failureLabels = ["cd-failure", prodSurfaceLabel, "urgent", "auto-opened"];

function runUrl(context) {
	return `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
}

function openProdIssueParams(context) {
	return {
		owner: context.repo.owner,
		repo: context.repo.repo,
		state: "open",
		labels: `auto-opened,cd-failure,${prodSurfaceLabel}`,
		sort: "updated",
		direction: "desc",
	};
}

async function listOpenProdIssues(github, context, perPage = 50) {
	const found = await github.rest.issues.listForRepo({
		...openProdIssueParams(context),
		per_page: perPage,
	});
	return found.data;
}

function readFindings(fs) {
	return fs.existsSync("findings.md")
		? fs.readFileSync("findings.md", "utf8")
		: "_No findings file produced._";
}

function alertBody(context, env, findings) {
	return [
		marker,
		`**Commit:** ${context.sha}`,
		`**Run:** ${runUrl(context)}`,
		`**Prod URL:** ${env.PROD_URL || prodUrl}`,
		"",
		"## Findings",
		findings,
		"",
		"## Manual rollback runbook",
		"",
		"**Vercel - instant alias swap:**",
		"```bash",
		"vercel rollback                    # interactive picker",
		"# or:",
		"vercel ls --prod | head -5",
		"vercel promote <previous-prod-url>",
		"```",
		"",
		"**Workers - re-deploy from previous good SHA:**",
		"```bash",
		"git checkout <previous-good-sha>",
		"cd infra/<worker> && npx wrangler@4 deploy",
		"git checkout main",
		"```",
		"",
		"## Decide: rollback vs roll forward",
		"- [ ] Rolled back (note which surfaces): ",
		"- [ ] Rolling forward (link the fix PR): ",
		"",
		"@fairchild",
	].join("\n");
}

export async function postProdAlert({
	github,
	context,
	core,
	env = process.env,
	fs = nodeFs,
}) {
	const findings = readFindings(fs);
	const body = alertBody(context, env, findings);
	const existing = (await listOpenProdIssues(github, context, 1))[0];

	if (existing) {
		await github.rest.issues.addLabels({
			owner: context.repo.owner,
			repo: context.repo.repo,
			issue_number: existing.number,
			labels: ["urgent"],
		});
		await github.rest.issues.createComment({
			owner: context.repo.owner,
			repo: context.repo.repo,
			issue_number: existing.number,
			body,
		});
		core.notice(`Updated prod alert issue #${existing.number}`);
		return { issueNumber: existing.number, created: false };
	}

	const shortSha = context.sha.slice(0, 7);
	const created = await github.rest.issues.create({
		owner: context.repo.owner,
		repo: context.repo.repo,
		title: `Prod regression on ${shortSha}`,
		body,
		labels: failureLabels,
	});
	core.notice(`Opened prod alert issue #${created.data.number}`);
	return { issueNumber: created.data.number, created: true };
}

export async function closeResolvedProdAlerts({ github, context, core }) {
	const issues = await listOpenProdIssues(github, context);
	const body = [
		marker,
		`Prod validation is green for \`${context.sha}\` in ${runUrl(context)}.`,
		"",
		`Closing this auto-opened \`${prodSurfaceLabel}\` issue. The CD auto-opener will update an open surface issue or create a new one if production regresses again.`,
	].join("\n");

	for (const issue of issues) {
		await github.rest.issues.createComment({
			owner: context.repo.owner,
			repo: context.repo.repo,
			issue_number: issue.number,
			body,
		});
		await github.rest.issues.update({
			owner: context.repo.owner,
			repo: context.repo.repo,
			issue_number: issue.number,
			state: "closed",
			state_reason: "completed",
		});
	}

	const numbers = issues.map((issue) => issue.number);
	core.notice(
		numbers.length
			? `Closed resolved prod alert issues: ${numbers.join(", ")}`
			: "No open prod alert issues to close",
	);
	return { closed: numbers };
}
