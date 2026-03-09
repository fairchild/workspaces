/**
 * Mock GitHub API server for local e2e testing.
 * Responds to the 4 endpoints the webhook-relay Worker calls.
 *
 * Token-dependent behavior:
 *   - Default token     → full access (2 repos)
 *   - ghp_no_install    → no GitHub App installation
 *   - ghp_repo_b_only   → only sees repo-b (for filtering test)
 */

const PORT = 8788;

function repos(owner: string, onlyB = false) {
  if (onlyB) return [{ full_name: `${owner}/repo-b` }];
  return [
    { full_name: `${owner}/repo-a` },
    { full_name: `${owner}/repo-b` },
  ];
}

const server = Bun.serve({
  port: PORT,
  fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    const auth = req.headers.get("Authorization") ?? "";
    const token = auth.replace("Bearer ", "");

    console.log(`[mock-github] ${req.method} ${path} token=${token.slice(0, 12)}...`);

    // GET /user
    if (path === "/user") {
      if (!auth) return Response.json({ message: "Requires authentication" }, { status: 401 });
      return Response.json({ id: 1, login: "test-user" });
    }

    // GET /user/installations
    if (path === "/user/installations") {
      if (token === "ghp_no_install") {
        return Response.json({ total_count: 0, installations: [] });
      }
      return Response.json({
        total_count: 1,
        installations: [{ account: { login: "test-org" } }],
      });
    }

    // GET /orgs/:owner/repos
    const orgMatch = path.match(/^\/orgs\/([^/]+)\/repos$/);
    if (orgMatch) {
      const owner = orgMatch[1];
      return Response.json(repos(owner, token === "ghp_repo_b_only"));
    }

    // GET /users/:owner/repos (fallback)
    const userMatch = path.match(/^\/users\/([^/]+)\/repos$/);
    if (userMatch) {
      const owner = userMatch[1];
      return Response.json(repos(owner, token === "ghp_repo_b_only"));
    }

    return Response.json({ message: "Not Found" }, { status: 404 });
  },
});

console.log(`[mock-github] listening on http://localhost:${server.port}`);
