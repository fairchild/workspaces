---
status: done
issue: 552
completed: 2026-05-25
resolution: promoted-to-github-issue
category: task-list
pr: null
branch: null
score: null
retro_summary: null
---

# Swift Development Skills: Install and Create

## Problem Statement

Research during the doc-refresh session (2026-02-15) identified several high-quality agent skills for Swift/macOS development, performance profiling, and memory debugging. Installing these would improve code quality during the refinement gate and ongoing polish work. Additionally, some project-specific workflows (os_signpost patterns, package-benchmark CI, terminal surface profiling) would benefit from custom skills.

Performance and snappy UX are central to the product. Making performance measurement a regular part of development — not an afterthought — requires the right tooling baked into the workflow.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary skill source | Axiom (CharlesWiltgen/Axiom) | Most comprehensive Swift skill set (31 skills), includes perf profiling, SwiftUI perf, memory debugging, SwiftData |
| MCP for Instruments | XcodeTraceMCP | Bridges Instruments trace analysis into Claude workflow |
| SwiftUI correctness | AvdLee/SwiftUI-Agent-Skill | Non-opinionated, modern API focus, perf anti-pattern detection |
| Concurrency safety | AvdLee/Swift-Concurrency-Agent-Skill | Relevant since GitService/WorkspaceService are actors |
| Custom skills | Create project-specific perf skills | os_signpost patterns, package-benchmark, surface memory profiling |

## Tasks

### Tier 1: Install Existing Skills

#### 1.1 Install Axiom Skills

- **Source**: https://github.com/CharlesWiltgen/Axiom
- **Install via**: `/plugin` menu in Claude Code, search for "axiom"
- **Priority skills**:
  - `axiom-performance-profiling` — Instruments decision trees for CPU, memory, battery
  - `axiom-swiftui-performance` — SwiftUI-specific perf optimization
  - `axiom-memory-debugging` — Memory debugging workflows
  - `axiom-swiftdata` — SwiftData patterns (directly relevant to persistence layer)
  - `axiom-swift-concurrency` — Swift 6 data races and actor isolation
- **Verify**: Run one skill against the codebase and confirm it provides useful guidance

#### 1.2 Install AvdLee Skills

- **SwiftUI**: https://github.com/AvdLee/SwiftUI-Agent-Skill
- **Concurrency**: https://github.com/AvdLee/Swift-Concurrency-Agent-Skill
- **Install**: Clone to skills directory or add as agent skills
- **Verify**: Run SwiftUI skill against `SidebarView.swift` or `ContentView.swift`

#### 1.3 Set Up XcodeTraceMCP

- **Source**: `jamesrochabrun/xcodetracemcp` (MCP server)
- **Install**: Configure in `claude_desktop_config.json`
- **Workflow**: Run Instruments on app -> save `.trace` -> Claude analyzes via MCP
- **Verify**: Capture a test trace, confirm MCP can parse and return insights

### Tier 2: Create Custom Skills

#### 2.1 OSSignposter Patterns Skill

A project-specific skill that provides:
- `Perf` enum boilerplate with subsystem/category constants
- Patterns for measuring launch, user-interaction, and async flows
- Integration with XCTest `XCTOSSignpostMetric` for regression tests
- Instruments Custom Instrument Package guidance

**Key content to encode**:
```swift
import OSLog

enum Perf {
    static let logger = Logger(subsystem: "com.workspaces.app", category: "Performance")
    static let signposter = OSSignposter(logger: logger)
}

// Interval pattern
let state = Perf.signposter.beginInterval("RepoClick", id: Perf.signposter.makeSignpostID())
// ... work ...
Perf.signposter.endInterval("RepoClick", state)

// Closure pattern
Perf.signposter.withIntervalSignpost("GitStatus") { await git.status(at: path) }
```

#### 2.2 Package-Benchmark CI Skill

A skill for setting up and maintaining `ordo-one/package-benchmark`:
- `Benchmarks/` directory structure
- Benchmark target `Package.swift` boilerplate
- GitHub Actions workflow for baseline comparison on PRs
- Threshold configuration for regression gating
- Available metrics reference: `cpuTotal`, `wallClock`, `mallocCountTotal`, `memoryLeaked`, etc.

**Source**: https://github.com/ordo-one/package-benchmark
**Swift.org blog**: https://www.swift.org/blog/benchmarks/

#### 2.3 Surface Memory Profiling Skill

A skill encoding terminal surface memory monitoring patterns:
- `DispatchSource.makeMemoryPressureSource` for adaptive eviction on macOS
- `mach_task_basic_info` for resident memory measurement
- LRU cache patterns (custom or `nicklockwood/LRUCache`)
- NSCache vs deterministic LRU tradeoffs
- MetricKit is NOT available on macOS (skip it)

### Tier 3: Evaluate and Defer

These were found but may not be worth installing yet:

- **Dimillian/Skills** — Opinionated Swift/SwiftUI skills from IceCubesApp creator. iOS 26 Liquid Glass focus. Monitor for macOS relevance.
- **xclaude-plugin** (`conorluddy/xclaude-plugin`) — 8 MCP servers for Xcode/Simulator. iOS-focused but profiling MCP could be useful.
- **Joannis/claude-skills** — Swift Server (Vapor/Hummingbird). Not relevant unless we add server components.
- **Generic profiling skill** (`jeremylongshore`) — Language-agnostic, less valuable than Axiom.

## Acceptance Criteria

- [ ] Axiom skills installed and verified against codebase
- [ ] AvdLee SwiftUI + Concurrency skills installed
- [ ] XcodeTraceMCP configured and tested with a sample trace
- [ ] At least one custom skill created (OSSignposter patterns is highest priority)
- [ ] Skills documented in project CLAUDE.md or `.claude/` config

## Verification Commands

```bash
# Check installed skills/plugins
ls ~/.claude/skills/
ls ~/.claude/plugins/

# Verify Axiom
# (run via Claude Code /plugin menu)

# Verify XcodeTraceMCP
# Check claude_desktop_config.json for MCP entry
```

## References

- Research session transcript: 2026-02-15 doc-refresh session
- Axiom: https://charleswiltgen.github.io/Axiom/
- AvdLee SwiftUI: https://github.com/AvdLee/SwiftUI-Agent-Skill
- AvdLee Concurrency: https://github.com/AvdLee/Swift-Concurrency-Agent-Skill
- XcodeTraceMCP: https://lobehub.com/mcp/jamesrochabrun-xcodetracemcp
- ordo-one/package-benchmark: https://github.com/ordo-one/package-benchmark
- nicklockwood/LRUCache: https://github.com/nicklockwood/LRUCache
- VoltAgent/awesome-agent-skills: https://github.com/VoltAgent/awesome-agent-skills
- Apple OSSignposter: https://developer.apple.com/documentation/os/ossignposter
- Swift.org benchmarks blog: https://www.swift.org/blog/benchmarks/
