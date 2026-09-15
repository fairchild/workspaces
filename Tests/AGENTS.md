# Tests/ - Testing Context

`CLAUDE.md` here symlinks to this file — read one, not both.

Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. Test behavior, not implementation.

| Pattern | Exemplar | When to use |
|---------|----------|-------------|
| Integration fixture | `Helpers/TestGitRepository.swift` | Testing against real external tools (git, filesystem) |
| Configurable mock | `Helpers/MockGitService.swift` | Testing orchestration logic with injectable errors |
| Extracted helpers | `WorkspaceServiceTests` `makeWorkspaceFixture()` | When 3+ tests share setup boilerplate |
| Serialized suite | `@Suite("WorkspaceService", .serialized)` | When tests share mutable global state |
| Launch-scaled budget | `Helpers/LaunchBudget.swift` | Any deadline in a test that launches child processes |

**Rules:**

- Test observable behavior, not implementation details
- Protect data contracts: Codable roundtrips, git porcelain format values
- Use `defer { cleanup() }` for temp directories
- The full suite on a checkout older than `90255bfe` (#1654, before `v0.28.0`) deletes the running app's operator credential: the file is keyed by the bundle identifier, shared by every copy of the app, and those tests removed it on cleanup. Every `workspaces automation` call on the machine then fails until the installed app is quit and reopened. Before running such a checkout's suite, warn the sessions dispatching through the app or run only a `--filter` that skips the automation suites; from `90255bfe` on, the suite is safe.
- For behavior-preserving refactors, verify tests bind by mutating the extracted logic and confirming failures; a surviving mutation means the test gets rewritten, not the check dropped.
- Wait on the observable state change, not a tuned wall clock — child-process round trips span 0.3s–35s between a laptop and a loaded runner, so scale any such deadline from `Helpers/LaunchBudget.swift` and measure the whole round trip. Where a real-time bound genuinely *is* the property (an OS-imposed ceiling), gate that one test with a named reason.
