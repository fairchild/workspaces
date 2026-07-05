import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RaceGroupPlanner")
struct RaceGroupPlannerTests {
    @Test("Slug derives from the first four words of the prompt")
    func slugFromPrompt() {
        let plan = RaceGroupPlanner.plan(
            prompt: "Add a health endpoint to the server",
            count: 3,
            command: "claude"
        )

        #expect(plan.slug == "add-a-health-endpoint")
        #expect(
            plan.workspaceNames == [
                "race-add-a-health-endpoint-1",
                "race-add-a-health-endpoint-2",
                "race-add-a-health-endpoint-3",
            ]
        )
    }

    @Test("Name override wins over the prompt and is sanitized")
    func nameOverrideWins() {
        let plan = RaceGroupPlanner.plan(
            prompt: "whatever the prompt says",
            count: 1,
            command: "claude",
            nameOverride: "My Fix!"
        )

        #expect(plan.slug == "my-fix")
        #expect(plan.workspaceNames == ["race-my-fix-1"])
    }

    @Test("Count clamps to the supported range")
    func countClamping() {
        #expect(RaceGroupPlanner.plan(prompt: "x", count: 0, command: "claude").workspaceNames.count == 1)
        #expect(RaceGroupPlanner.plan(prompt: "x", count: 99, command: "claude").workspaceNames.count == 8)
    }

    @Test("Punctuation collapses to git-ref-safe dashes")
    func slugSanitization() {
        let plan = RaceGroupPlanner.plan(prompt: "fix: the / thing?!", count: 1, command: "claude")
        #expect(plan.slug == "fix-the-thing")
    }

    @Test("Long derivations truncate to a bounded slug without a trailing dash")
    func slugLengthBound() {
        let plan = RaceGroupPlanner.plan(
            prompt: "supercalifragilistic expialidocious antidisestablishmentarianism floccinaucinihilipilification",
            count: 1,
            command: "claude"
        )

        #expect(plan.slug.count <= RaceGroupPlanner.maxSlugLength)
        #expect(!plan.slug.hasSuffix("-"))
        #expect(!plan.slug.isEmpty)
    }

    @Test("Symbol-only prompts fall back to a stable slug")
    func emptySlugFallback() {
        let plan = RaceGroupPlanner.plan(prompt: "!!! ???", count: 1, command: "claude")
        #expect(plan.slug == RaceGroupPlanner.fallbackSlug)
    }

    @Test("Prompt is single-quote shell escaped in the agent command")
    func shellEscaping() {
        let plan = RaceGroupPlanner.plan(
            prompt: "don't `run` $HOME \"now\"",
            count: 1,
            command: "claude"
        )

        #expect(plan.agentCommand == "claude -p 'don'\\''t `run` $HOME \"now\"'")
    }

    @Test("Custom agent command passes through verbatim")
    func commandPassthrough() {
        let plan = RaceGroupPlanner.plan(
            prompt: "do the thing",
            count: 1,
            command: "claude --permission-mode acceptEdits"
        )

        #expect(plan.agentCommand == "claude --permission-mode acceptEdits -p 'do the thing'")
    }
}
