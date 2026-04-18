// Shared logic for the fail-notify-{playwright,lighthouse} jobs in cd.yml.
//
// Called from github-script@v7 as:
//   const script = require('./.github/workflows/cd-fail-notify.cjs');
//   await script({ github, context, core });
//
// Env inputs:
//   VALIDATOR    — "playwright" or "lighthouse"
//   PREVIEW_URL  — preview deployment URL
//   REPRO_HINT   — shell command to reproduce locally
//
// Reads findings.md from the current working directory (downloaded artifact).

module.exports = async function failNotify({ github, context, core, env = process.env, fs = require('node:fs') }) {
  const validator = env.VALIDATOR;
  const marker = `<!-- cd-failure:${validator} -->`;
  const dispatchMarker = `<!-- april-dispatch -->`;
  const escalateLabel = 'needs-human';
  const maxAttempts = 2;
  const findings = fs.existsSync('findings.md')
    ? fs.readFileSync('findings.md', 'utf8')
    : '_No findings file produced._';

  const title = `CD: ${validator} failures on main`;
  const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;

  const q = `repo:${context.repo.owner}/${context.repo.repo} in:body "${marker}" is:issue`;
  const found = await github.rest.search.issuesAndPullRequests({ q, per_page: 1 });
  const existing = found.data.items[0];

  let attempts = 0;
  if (existing) {
    const comments = await github.rest.issues.listComments({
      owner: context.repo.owner, repo: context.repo.repo,
      issue_number: existing.number, per_page: 100,
    });
    attempts = comments.data.filter(c =>
      c.body && c.body.includes(dispatchMarker)
    ).length;
  }
  const shouldDispatch = attempts < maxAttempts;

  const statusSection = shouldDispatch
    ? [
        '',
        '## Auto-fix',
        `April will be dispatched to investigate (attempt ${attempts + 1}/${maxAttempts}).`,
        `Reproduce locally: \`${env.REPRO_HINT}\``,
        '',
      ]
    : [
        '',
        '## Auto-fix exhausted — needs human',
        `April attempted ${attempts} fix(es) without success. Triage required.`,
        '/cc @fairchild',
        '',
      ];

  const body = [
    marker,
    `**Commit:** ${context.sha}`,
    `**Run:** ${runUrl}`,
    `**Preview URL:** ${env.PREVIEW_URL || '(not available)'}`,
    '',
    '## Findings',
    findings,
    ...statusSection,
    '## Plan to fix (if root cause is obvious)',
    '- [ ] Root cause: <one sentence>',
    '- [ ] Reproduction: <local command>',
    '- [ ] Fix approach: <one paragraph>',
    '- [ ] Validation: <how we know it is fixed>',
    '',
    '## Plan to explore (if fix is not obvious)',
    '- [ ] Hypothesis: <one sentence>',
    '- [ ] Experiment: <what to run>',
    '- [ ] Decision point: <what result tells us to do what>',
  ].join('\n');

  let issueNumber;
  if (existing) {
    if (existing.state === 'closed') {
      await github.rest.issues.update({
        owner: context.repo.owner, repo: context.repo.repo,
        issue_number: existing.number, state: 'open',
      });
    }
    if (!shouldDispatch) {
      await github.rest.issues.addLabels({
        owner: context.repo.owner, repo: context.repo.repo,
        issue_number: existing.number, labels: [escalateLabel],
      });
    }
    await github.rest.issues.createComment({
      owner: context.repo.owner, repo: context.repo.repo,
      issue_number: existing.number, body,
    });
    issueNumber = existing.number;
    core.notice(`Updated rolling issue #${issueNumber} (attempts=${attempts}, dispatch=${shouldDispatch})`);
  } else {
    const created = await github.rest.issues.create({
      owner: context.repo.owner, repo: context.repo.repo,
      title, body,
      labels: ['cd-failure', `cd-failure:${validator}`, 'auto-opened'],
    });
    issueNumber = created.data.number;
    core.notice(`Created rolling issue #${issueNumber}`);
  }

  if (shouldDispatch) {
    const directive = [
      `@${context.repo.owner} mentioned you in issue #${issueNumber}`,
      '',
      '---',
      `CD ${validator} validation failed on \`${context.sha}\`.`,
      '',
      `- Commit: ${context.sha}`,
      `- Preview URL: ${env.PREVIEW_URL || '(not available)'}`,
      `- Workflow run: ${runUrl}`,
      `- Reproduce: \`${env.REPRO_HINT}\``,
      '',
      `Reproduce locally, root-cause the failure, open a fix PR, and link it back to issue #${issueNumber}.`,
      '---',
      '',
    ].join('\n');
    const ref = context.ref.replace(/^refs\/heads\//, '');
    try {
      await github.rest.actions.createWorkflowDispatch({
        owner: context.repo.owner, repo: context.repo.repo,
        workflow_id: 'agent-april.yml',
        ref,
        inputs: { message: directive },
      });
      await github.rest.issues.createComment({
        owner: context.repo.owner, repo: context.repo.repo,
        issue_number: issueNumber,
        body: [
          dispatchMarker,
          `🤖 Dispatched **April** (attempt ${attempts + 1}/${maxAttempts}) on \`${ref}\`.`,
          '',
          '<details><summary>Directive</summary>',
          '',
          '```',
          directive,
          '```',
          '',
          '</details>',
        ].join('\n'),
      });
      core.notice(`Dispatched April (attempt ${attempts + 1})`);
    } catch (err) {
      core.warning(`Failed to dispatch April: ${err.message}`);
      await github.rest.issues.createComment({
        owner: context.repo.owner, repo: context.repo.repo,
        issue_number: issueNumber,
        body: `⚠️ Tried to dispatch April but failed: \`${err.message}\`. /cc @fairchild`,
      });
    }
  }

  return { issueNumber, attempts, shouldDispatch };
};
