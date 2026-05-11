    const state = {
      docs: [],
      topics: [],
      query: new URLSearchParams(location.search)
    };

    const routes = [
      {
        title: "Learn product language",
        copy: "Vocabulary, product overview, surface model, and user-facing nouns.",
        links: [["Vocabulary", "q", "CONTEXT"], ["Product", "group", "Product"], ["Repository", "topic", "repository"]]
      },
      {
        title: "Debug runtime behavior",
        copy: "Terminal focus, Ghostty integration, shortcut routing, and session behavior.",
        links: [["Terminal", "topic", "terminal-session"], ["Ghostty", "topic", "ghostty"], ["Development", "group", "Development"]]
      },
      {
        title: "Operate providers",
        copy: "Lume, Daytona, validation, setup, recreate flows, and recovery.",
        links: [["Provider", "topic", "provider"], ["Lume", "topic", "lume"], ["Operations", "group", "Operations"]]
      },
      {
        title: "Prove the work",
        copy: "Evidence, performance, mergeability, and review readiness.",
        links: [["Evidence", "topic", "evidence"], ["Performance", "topic", "performance"], ["Mergeability", "topic", "mergeability"]]
      }
    ];

    const conceptClusters = [
      ["Product nouns", ["repository", "workspace", "terminal-session"]],
      ["Runtime mechanics", ["terminal-session", "ghostty", "surface"]],
      ["Provider operations", ["provider", "lume", "workspace"]],
      ["Review proof", ["evidence", "performance", "mergeability"]]
    ];

    const readingPath = [
      ["Learn", [["Vocabulary", "q", "CONTEXT"], ["Product overview", "q", "product overview"]]],
      ["Orient", [["Architecture", "q", "architecture"], ["Provider model", "topic", "provider"]]],
      ["Operate", [["Lume runbooks", "topic", "lume"], ["Troubleshooting", "q", "troubleshooting"]]],
      ["Verify", [["Evidence", "topic", "evidence"], ["Mergeability", "topic", "mergeability"]]]
    ];

    const elements = {
      routeForm: document.querySelector("#route-form"),
      routeInput: document.querySelector("#route-input"),
      askButton: document.querySelector("#ask-button"),
      routeShowAll: document.querySelector("#route-show-all"),
      searchHint: document.querySelector("#search-hint"),
      autocomplete: document.querySelector("#autocomplete"),
      aiAnswer: document.querySelector("#ai-answer"),
      aiAnswerStatus: document.querySelector("#ai-answer-status"),
      aiAnswerBody: document.querySelector("#ai-answer-body"),
      citationList: document.querySelector("#citation-list"),
      copyAnswer: document.querySelector("#copy-answer"),
      dismissAnswer: document.querySelector("#dismiss-answer"),
      openAll: document.querySelector("#open-all"),
      routeGrid: document.querySelector("#route-grid"),
      conceptGrid: document.querySelector("#concept-grid"),
      pathRail: document.querySelector("#path-rail"),
      group: document.querySelector("#group"),
      topic: document.querySelector("#topic"),
      type: document.querySelector("#type"),
      reset: document.querySelector("#reset"),
      stats: document.querySelector("#stats"),
      results: document.querySelector("#results"),
      showAll: document.querySelector("#show-all"),
      expandAll: document.querySelector("#expand-all"),
      collapseAll: document.querySelector("#collapse-all")
    };

    let currentDocs = [];
    let currentAnswer = "";
    let askController = null;
    let renderRequestId = 0;

    function escapeHtml(value) {
      return String(value || "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

    function maybeJson(value) {
      if (typeof value !== "string") return value;
      let text = value.trim();
      if (text.startsWith("```json")) {
        text = text.replace(/^```json\s*/, "").replace(/```$/, "").trim();
      } else if (text.startsWith("```")) {
        text = text.replace(/^```\s*/, "").replace(/```$/, "").trim();
      }
      if (!text || !/^[{[]/.test(text)) return value;
      try {
        return JSON.parse(text);
      } catch {
        return value;
      }
    }

    function normalizeAnswerPayload(payload) {
      const parsedAnswer = maybeJson(payload.answer || payload.copyText || "");
      const structured = parsedAnswer && typeof parsedAnswer === "object" && !Array.isArray(parsedAnswer)
        ? parsedAnswer
        : {};
      const answer = structured.answer_markdown || structured.answer || payload.answer || payload.copyText || "";
      return {
        ...payload,
        answer,
        copyText: structured.copy_text || payload.copyText || answer,
        citations: Array.isArray(payload.citations) && payload.citations.length
          ? payload.citations
          : Array.isArray(structured.citations)
            ? structured.citations
            : []
      };
    }

    async function readJsonResponse(response) {
      const text = await response.text();
      const parsed = maybeJson(text);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed;
      }
      return {
        error: response.ok ? "Docs ask returned an unreadable response." : "Local AI docs ask is available only from docs/server.py."
      };
    }

    function markdownToHtml(markdown) {
      const lines = String(markdown || "").split("\n");
      let html = "";
      let inList = false;
      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (!line) {
          if (inList) {
            html += "</ul>";
            inList = false;
          }
          continue;
        }
        const bullet = /^[-*]\s+(.+)$/.exec(line);
        if (bullet) {
          if (!inList) {
            html += "<ul>";
            inList = true;
          }
          html += `<li>${inlineMarkdown(bullet[1])}</li>`;
          continue;
        }
        if (inList) {
          html += "</ul>";
          inList = false;
        }
        html += `<p>${inlineMarkdown(line)}</p>`;
      }
      if (inList) html += "</ul>";
      return html || "<p>No answer returned.</p>";
    }

    function inlineMarkdown(value) {
      return escapeHtml(value)
        .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\[([^\]]+)]\((\/docs\/[^)]+)\)/g, '<a href="$2">$1</a>');
    }

    function renderedHref(dest) {
      return `/docs/${dest.replace(/\.md$/, "")}`;
    }

    function optionList(values, label) {
      return [`<option value="">All ${label}</option>`]
        .concat(values.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`))
        .join("");
    }

    function optionPairs(values, label) {
      return [`<option value="">All ${label}</option>`]
        .concat(values.map(({ value, text }) => `<option value="${escapeHtml(value)}">${escapeHtml(text)}</option>`))
        .join("");
    }

    function topicLabel(topic) {
      return state.topics.find((entry) => entry.id === topic)?.label || topic.replace(/-/g, " ");
    }

    function titleCase(value) {
      return String(value || "")
        .split(/[-_/]+/)
        .filter(Boolean)
        .map((part) => `${part[0]?.toUpperCase() || ""}${part.slice(1)}`)
        .join(" ");
    }

    function sectionLabel(doc) {
      if (doc.dest.includes("/")) {
        return titleCase(doc.dest.split("/")[0]);
      }
      return "Root";
    }

    function groupBy(values, keyForValue) {
      const groups = new Map();
      for (const value of values) {
        const key = keyForValue(value) || "Reference";
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(value);
      }
      return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b));
    }

    function countBy(values, keyForValue) {
      return groupBy(values, keyForValue)
        .map(([key, entries]) => ({ key, count: entries.length }))
        .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));
    }

    function setFilter(key, value) {
      if (key === "q") {
        elements.routeInput.value = value;
      } else {
        elements[key].value = value;
      }
      render();
    }

    function clearFilters() {
      elements.routeInput.value = "";
      elements.group.value = "";
      elements.topic.value = "";
      elements.type.value = "";
      render();
    }

    function syncUrl() {
      const params = new URLSearchParams();
      for (const key of ["group", "topic", "type"]) {
        if (elements[key].value) params.set(key, elements[key].value);
      }
      if (elements.routeInput.value.trim()) params.set("q", elements.routeInput.value.trim());
      history.replaceState(null, "", `${location.pathname}${params.toString() ? `?${params}` : ""}`);
    }

    function filters() {
      return {
        q: elements.routeInput.value.trim(),
        group: elements.group.value,
        topic: elements.topic.value,
        type: elements.type.value
      };
    }

    function docMatchesFilters(doc, active) {
      return (!active.group || doc.group === active.group)
        && (!active.topic || (doc.topics || []).includes(active.topic))
        && (!active.type || doc.type === active.type);
    }

    async function searchDocs(active) {
      if (!active.q) return state.docs.filter((doc) => docMatchesFilters(doc, active));
      const params = new URLSearchParams({
        q: active.q,
        limit: "250"
      });
      for (const key of ["group", "topic", "type"]) {
        if (active[key]) params.set(key, active[key]);
      }
      const response = await fetch(`/docs/api/search?${params}`, { cache: "no-store" });
      if (!response.ok) throw new Error("Local docs search is unavailable.");
      const payload = await response.json();
      return Array.isArray(payload.results) ? payload.results : [];
    }

    function renderDocs(docs, active) {
      currentDocs = docs;
      elements.stats.innerHTML = [
        `${docs.length} shown`,
        `${state.docs.length} indexed`,
        active.group || "all areas"
      ].map((text) => `<span class="stat">${escapeHtml(text)}</span>`).join("");

      elements.results.innerHTML = docs.length
        ? groupBy(docs, (doc) => doc.group || "Reference").map(([area, areaDocs]) => `
            <details class="area" open>
              <summary class="area-head">
                <strong>${escapeHtml(area)}</strong>
                <span>${areaDocs.length} docs</span>
              </summary>
              ${groupBy(areaDocs, sectionLabel).map(([section, sectionDocs]) => `
                <details class="section" open>
                  <summary class="section-head">
                    <strong>${escapeHtml(section)}</strong>
                    <span>${sectionDocs.length}</span>
                  </summary>
                  <div class="doc-list">
                    ${sectionDocs.map((doc) => `
                      <a class="doc-row" href="${renderedHref(doc.dest)}">
                        <span>
                          <span class="doc-title">${escapeHtml(doc.title)}</span><br>
                          <span class="path">${escapeHtml(doc.dest)}</span>
                        </span>
                        <span>${escapeHtml(doc.summary || "No summary yet.")}</span>
                        <span class="tags">
                          <span class="tag">${escapeHtml(doc.type || "Reference")}</span>
                          ${(doc.topics || []).slice(0, 3).map((topic) => `<span class="tag">${escapeHtml(topicLabel(topic))}</span>`).join("")}
                        </span>
                      </a>
                    `).join("")}
                  </div>
                </details>
              `).join("")}
            </details>
          `).join("")
        : '<div class="empty">No docs match these filters.</div>';
      renderAutocomplete(docs, active);
      syncUrl();
    }

    async function render() {
      const active = filters();
      const requestId = ++renderRequestId;
      try {
        const docs = await searchDocs(active);
        if (requestId !== renderRequestId) return;
        renderDocs(docs, active);
      } catch (error) {
        if (requestId !== renderRequestId) return;
        currentDocs = [];
        elements.stats.innerHTML = `<span class="stat">${escapeHtml(error.message || "Search unavailable")}</span>`;
        elements.results.innerHTML = '<div class="empty">Local docs search is unavailable.</div>';
        elements.autocomplete.classList.remove("active");
        elements.autocomplete.innerHTML = "";
      }
    }

    function renderAutocomplete(docs, active) {
      const shouldShow = Boolean(active.q) && docs.length > 0;
      elements.autocomplete.classList.toggle("active", shouldShow);
      if (!shouldShow) {
        elements.autocomplete.innerHTML = "";
        elements.searchHint.textContent = "Typing filters instantly. Enter asks local Claude Code using the same search.";
        return;
      }
      const topDocs = docs.slice(0, 6);
      elements.searchHint.textContent = `${docs.length} matching docs. Press Enter to ask with canonical docs search.`;
      elements.autocomplete.innerHTML = topDocs.map((doc) => `
        <a class="autocomplete-row" href="${renderedHref(doc.dest)}">
          <strong>${escapeHtml(doc.title)}</strong>
          <span>${escapeHtml(doc.summary || "No summary yet.")}</span>
          <code>${escapeHtml(doc.dest)}</code>
        </a>
      `).join("");
    }

    async function askDocs() {
      const query = elements.routeInput.value.trim();
      if (!query) {
        elements.routeInput.focus();
        return;
      }
      if (askController) askController.abort();
      askController = new AbortController();
      elements.aiAnswer.classList.add("active");
      elements.aiAnswer.setAttribute("aria-busy", "true");
      elements.routeForm.classList.add("asking");
      elements.aiAnswerStatus.textContent = "Asking local Claude Code...";
      elements.aiAnswerBody.innerHTML = '<div class="answer-loading"><span class="answer-spinner" aria-hidden="true"></span><span>Searching docs and preparing a cited answer.</span></div>';
      elements.citationList.innerHTML = "";
      elements.askButton.disabled = true;
      try {
        const response = await fetch("/docs/api/ask", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ query }),
          signal: askController.signal
        });
        const payload = await readJsonResponse(response);
        if (!response.ok) {
          throw new Error(payload.detail || payload.error || "Docs ask failed.");
        }
        const answerPayload = normalizeAnswerPayload(payload);
        currentAnswer = answerPayload.copyText || answerPayload.answer || "";
        elements.aiAnswerStatus.textContent = answerPayload.totalCostUsd ? `Claude Code · $${Number(answerPayload.totalCostUsd).toFixed(4)}` : "Claude Code";
        elements.aiAnswerBody.innerHTML = markdownToHtml(answerPayload.answer || answerPayload.copyText);
        elements.citationList.innerHTML = (answerPayload.citations || []).map((citation) => `
          <a href="${escapeHtml(citation.url || "#")}" title="${escapeHtml(citation.source || "")}">
            ${escapeHtml(citation.title || citation.source || "Source")}
          </a>
        `).join("");
      } catch (error) {
        if (error.name === "AbortError") return;
        currentAnswer = "";
        elements.aiAnswerStatus.textContent = "Unavailable";
        elements.aiAnswerBody.innerHTML = `<p>${escapeHtml(error.message || "Could not ask local Claude Code.")}</p>`;
      } finally {
        elements.askButton.disabled = false;
        elements.routeForm.classList.remove("asking");
        elements.aiAnswer.setAttribute("aria-busy", "false");
        askController = null;
      }
    }

    function renderRoutes() {
      elements.routeGrid.innerHTML = routes.map((route) => `
        <article class="route">
          <div>
            <h3>${escapeHtml(route.title)}</h3>
            <p>${escapeHtml(route.copy)}</p>
          </div>
          <div class="route-actions">
            ${route.links.map(([label, kind, value]) => `
              <button type="button" data-filter="${escapeHtml(kind)}" data-value="${escapeHtml(value)}">
                <span>${escapeHtml(label)}</span><span>${escapeHtml(kind)}</span>
              </button>
            `).join("")}
          </div>
        </article>
      `).join("");
    }

    function renderConcepts() {
      const indexedTopics = new Set(state.docs.flatMap((doc) => doc.topics || []));
      elements.conceptGrid.innerHTML = conceptClusters.map(([title, ids]) => {
        const visibleIds = ids.filter((id) => indexedTopics.has(id));
        if (!visibleIds.length) return "";
        return `
          <article class="concept-card">
            <h3>${escapeHtml(title)}</h3>
            <p>${escapeHtml(visibleIds.map(topicLabel).join(", "))}</p>
            <div class="topic-chips">
              ${visibleIds.map((id) => `
                <button class="topic-chip" type="button" data-filter="topic" data-value="${escapeHtml(id)}">
                  ${escapeHtml(topicLabel(id))}
                </button>
              `).join("")}
            </div>
          </article>
        `;
      }).join("");
    }

    function renderReadingPath() {
      elements.pathRail.innerHTML = readingPath.map(([title, links], index) => `
        <article class="path-step" data-step="${index + 1}">
          <h3>${escapeHtml(title)}</h3>
          ${links.map(([label, kind, value]) => `
            <button type="button" data-filter="${escapeHtml(kind)}" data-value="${escapeHtml(value)}">
              ${escapeHtml(label)}
            </button>
          `).join("")}
        </article>
      `).join("");
    }

    function hydrateControls() {
      const groups = [...new Set(state.docs.map((doc) => doc.group).filter(Boolean))].sort();
      const topics = [...new Set(state.docs.flatMap((doc) => doc.topics || []))]
        .sort((a, b) => topicLabel(a).localeCompare(topicLabel(b)));
      const types = [...new Set(state.docs.map((doc) => doc.type).filter(Boolean))].sort();
      elements.group.innerHTML = optionList(groups, "collections");
      elements.topic.innerHTML = optionPairs(
        topics.map((topic) => ({ value: topic, text: topicLabel(topic) })),
        "topics"
      );
      elements.type.innerHTML = optionList(types, "types");

      elements.routeInput.value = state.query.get("q") || "";
      elements.group.value = state.query.get("group") || "";
      elements.topic.value = state.query.get("topic") || "";
      elements.type.value = state.query.get("type") || "";
    }

    async function loadIndex() {
      const response = await fetch("/docs/local-docs-manifest.json", { cache: "no-store" });
      if (!response.ok) throw new Error("Local docs manifest is unavailable.");
      const manifest = await response.json();
      if (!manifest.local) throw new Error("This index is only available in local docs mode.");
      state.docs = manifest.entries || [];
      state.topics = manifest.topics || [];
      hydrateControls();
      renderRoutes();
      renderConcepts();
      renderReadingPath();
      render();
      requestAnimationFrame(() => elements.routeInput.focus());
    }

    function handleFilterClick(event) {
      const button = event.target.closest("[data-filter]");
      if (!button) return;
      setFilter(button.dataset.filter, button.dataset.value);
    }

    elements.routeForm.addEventListener("submit", (event) => {
      event.preventDefault();
      askDocs();
    });
    elements.routeInput.addEventListener("input", render);
    elements.routeShowAll.addEventListener("click", clearFilters);
    elements.openAll.addEventListener("click", clearFilters);
    elements.routeGrid.addEventListener("click", handleFilterClick);
    elements.conceptGrid.addEventListener("click", handleFilterClick);
    elements.pathRail.addEventListener("click", handleFilterClick);
    document.querySelector(".reading-path").addEventListener("click", handleFilterClick);
    for (const input of [elements.group, elements.topic, elements.type]) {
      input.addEventListener("input", render);
      input.addEventListener("change", render);
    }
    elements.copyAnswer.addEventListener("click", async () => {
      if (!currentAnswer) return;
      try {
        await navigator.clipboard.writeText(currentAnswer);
        elements.aiAnswerStatus.textContent = "Copied";
      } catch {
        const textArea = document.createElement("textarea");
        textArea.value = currentAnswer;
        textArea.setAttribute("readonly", "");
        textArea.style.position = "fixed";
        textArea.style.opacity = "0";
        document.body.appendChild(textArea);
        textArea.select();
        document.execCommand("copy");
        textArea.remove();
        elements.aiAnswerStatus.textContent = "Copied";
      }
    });
    elements.dismissAnswer.addEventListener("click", () => {
      elements.aiAnswer.classList.remove("active");
    });
    elements.reset.addEventListener("click", () => {
      clearFilters();
    });
    elements.showAll.addEventListener("click", clearFilters);
    elements.expandAll.addEventListener("click", () => {
      document.querySelectorAll("#results details").forEach((details) => {
        details.open = true;
      });
    });
    elements.collapseAll.addEventListener("click", () => {
      document.querySelectorAll("#results details").forEach((details) => {
        details.open = false;
      });
    });

    loadIndex().catch((error) => {
      elements.results.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
    });
