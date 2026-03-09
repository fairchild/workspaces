// Repo Landing — Project Override
//
// Custom landing page for the WorkspaceManager repo itself.
// Demonstrates the repo-level override pattern (.agents/workspaces/).
//
// Contract:
//   IN:  window.RepoLanding.onData({ repo, workspaces })
//   OUT: window.webkit.messageHandlers.repoLanding.postMessage({ action, ... })

(function () {
    "use strict";

    const grid = document.getElementById("workspace-grid");
    const emptyState = document.getElementById("empty-state");
    const banner = document.getElementById("repo-banner");

    // -- Bridge ----------------------------------------------------------------

    function bridge(action, extra) {
        const msg = Object.assign({ action: action }, extra || {});
        if (window.webkit?.messageHandlers?.repoLanding) {
            window.webkit.messageHandlers.repoLanding.postMessage(msg);
        }
    }

    // expose for inline onclick in HTML
    window.bridge = bridge;

    // -- Helpers ---------------------------------------------------------------

    function relativeTime(ts) {
        const s = Math.floor(Date.now() / 1000 - ts);
        if (s < 60) return "now";
        const m = Math.floor(s / 60);
        if (m < 60) return m + "m";
        const h = Math.floor(m / 60);
        if (h < 24) return h + "h";
        const d = Math.floor(h / 24);
        return d + "d";
    }

    function shortPath(full) {
        const home = "/Users/";
        if (full.startsWith(home)) {
            const rest = full.slice(home.length);
            const slash = rest.indexOf("/");
            return "~" + (slash >= 0 ? rest.slice(slash) : "");
        }
        return full;
    }

    // -- Banner ----------------------------------------------------------------

    function renderBanner(data) {
        const ws = data.workspaces || [];
        if (ws.length === 0) { banner.innerHTML = ""; return; }

        const active = ws.filter(w => w.status === "active").length;
        const withAgent = ws.filter(w => w.isAgentRunning).length;
        const total = ws.length;

        const parts = [];

        parts.push(stat("green", active + " active"));
        parts.push(sep());
        parts.push(stat(withAgent > 0 ? "orange" : "gray", withAgent + " agent" + (withAgent !== 1 ? "s" : "")));
        parts.push(sep());
        parts.push(document.createTextNode(total + " workspace" + (total !== 1 ? "s" : "") + " total"));

        banner.innerHTML = "";
        parts.forEach(p => banner.appendChild(p));
    }

    function stat(color, text) {
        const el = document.createElement("span");
        el.className = "banner-stat";
        el.innerHTML = '<span class="dot ' + color + '"></span>' + text;
        return el;
    }

    function sep() {
        const el = document.createElement("span");
        el.className = "banner-sep";
        return el;
    }

    // -- Cards -----------------------------------------------------------------

    function renderCard(ws) {
        const card = document.createElement("div");
        card.className = "card " + ws.status + "-border";
        card.onclick = () => bridge("selectWorkspace", { id: ws.id });

        // Header
        const header = document.createElement("div");
        header.className = "card-header";

        const name = document.createElement("span");
        name.className = "card-name";
        name.textContent = ws.name;

        const badge = document.createElement("span");
        badge.className = "badge badge-" + ws.status;
        badge.textContent = ws.status;

        header.append(name, badge);

        // Meta
        const meta = document.createElement("div");
        meta.className = "card-meta";

        if (ws.branch) {
            const br = document.createElement("div");
            br.className = "card-branch";
            br.textContent = ws.branch;
            meta.appendChild(br);
        }

        const path = document.createElement("div");
        path.className = "card-path";
        path.textContent = shortPath(ws.path);
        meta.appendChild(path);

        // Processes
        const procs = ws.processes || [];
        let procsEl = null;
        if (procs.length > 0) {
            procsEl = document.createElement("div");
            procsEl.className = "processes";
            procs.forEach(p => {
                const chip = document.createElement("span");
                chip.className = "process-chip " + (p.isKnownAgent ? "known" : "other");
                chip.innerHTML = '<span class="pulse"></span>' + p.displayName;
                procsEl.appendChild(chip);
            });
        }

        // Footer
        const footer = document.createElement("div");
        footer.className = "card-footer";

        const time = document.createElement("span");
        time.className = "card-time";
        time.textContent = relativeTime(ws.lastAccessedAt);

        const actions = document.createElement("div");
        actions.className = "card-actions";

        const editorBtn = makeAction("Open", () => bridge("openInEditor", { id: ws.id }));
        const revealBtn = makeAction("Reveal", () => bridge("revealInFinder", { id: ws.id }));
        const archiveBtn = makeAction("Archive", () => bridge("archiveWorkspace", { id: ws.id }));

        actions.append(editorBtn, revealBtn, archiveBtn);
        footer.append(time, actions);

        // Assemble
        card.append(header, meta);
        if (procsEl) card.appendChild(procsEl);
        card.appendChild(footer);

        return card;
    }

    function makeAction(label, fn) {
        const btn = document.createElement("button");
        btn.className = "action-btn";
        btn.textContent = label;
        btn.onclick = (e) => { e.stopPropagation(); fn(); };
        return btn;
    }

    function renderNewCard() {
        const card = document.createElement("div");
        card.className = "new-card";
        card.onclick = () => bridge("createWorkspace");

        const icon = document.createElement("div");
        icon.className = "new-card-icon";
        icon.textContent = "+";

        const label = document.createElement("div");
        label.className = "new-card-label";
        label.textContent = "New Workspace";

        card.append(icon, label);
        return card;
    }

    // -- Render ----------------------------------------------------------------

    function render(data) {
        renderBanner(data);
        grid.innerHTML = "";

        const workspaces = data.workspaces || [];
        if (workspaces.length === 0) {
            emptyState.style.display = "flex";
            grid.style.display = "none";
            return;
        }

        emptyState.style.display = "none";
        grid.style.display = "grid";

        workspaces.forEach(ws => grid.appendChild(renderCard(ws)));
        grid.appendChild(renderNewCard());
    }

    // -- Public API ------------------------------------------------------------

    window.RepoLanding = {
        onData: function (data) { render(data); }
    };

    // -- Standalone mode (browser dev) -----------------------------------------

    if (!window.webkit?.messageHandlers?.repoLanding) {
        render({
            repo: {
                name: "minnetonka-v3",
                localPath: "/Users/fairchild/conductor/workspaces/workspaces/minnetonka-v3",
                remoteURL: "https://github.com/fairchild/minnetonka-v3"
            },
            workspaces: [
                {
                    id: "1", name: "repo-landing-page", branch: "repo-landing-page",
                    path: "/Users/fairchild/conductor/workspaces/workspaces/minnetonka-v3",
                    status: "active", lastAccessedAt: Date.now() / 1000 - 120,
                    isAgentRunning: true, agentName: "Claude",
                    processes: [
                        { displayName: "Claude", isKnownAgent: true },
                        { displayName: "swift", isKnownAgent: false }
                    ]
                },
                {
                    id: "2", name: "terminal-splits", branch: "ws/terminal-splits",
                    path: "/Users/fairchild/conductor/workspaces/workspaces/minnetonka-v3/.workspaces/terminal-splits",
                    status: "active", lastAccessedAt: Date.now() / 1000 - 3600,
                    isAgentRunning: false, agentName: null,
                    processes: []
                },
                {
                    id: "3", name: "perf-signposts", branch: "ws/perf-signposts",
                    path: "/Users/fairchild/conductor/workspaces/workspaces/minnetonka-v3/.workspaces/perf-signposts",
                    status: "stopped", lastAccessedAt: Date.now() / 1000 - 86400,
                    isAgentRunning: false, agentName: null,
                    processes: []
                },
                {
                    id: "4", name: "vz-backend-spike", branch: "ws/vz-backend",
                    path: "/Users/fairchild/conductor/workspaces/workspaces/minnetonka-v3/.workspaces/vz-backend",
                    status: "archived", lastAccessedAt: Date.now() / 1000 - 86400 * 5,
                    isAgentRunning: false, agentName: null,
                    processes: [{ displayName: "Pi", isKnownAgent: true }]
                }
            ]
        });
    } else {
        bridge("ready");
    }
})();
