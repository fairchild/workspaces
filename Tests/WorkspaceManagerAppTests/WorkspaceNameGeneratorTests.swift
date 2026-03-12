import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WorkspaceNameGenerator")
struct WorkspaceNameGeneratorTests {
    @Test("Generated names are lowercase, sanitized, and valid")
    func generatedNamesAreSanitized() {
        let generatedName = WorkspaceNameGenerator.generateDefaultName(
            occupiedSanitizedNames: Set<String>()
        )

        #expect(generatedName == WorkspaceNameGenerator.sanitizedName(generatedName))
        #expect(WorkspaceService.isValidWorkspaceNameComponent(generatedName))
        #expect(!generatedName.contains(" "))
    }

    @Test("Sanitized equivalent names collapse to one occupied entry")
    func sanitizedEquivalentNamesCollapse() {
        let occupied = WorkspaceNameGenerator.sanitizedNameSet(from: ["My Feature", "my-feature"])

        #expect(occupied == Set(["my-feature"]))
    }

    @Test("Generated defaults advance to the next deterministic suffix")
    func generatedDefaultsUseDeterministicSuffixes() throws {
        let secondVariant = try WorkspaceNameGenerator.resolveName(
            "slug",
            source: .generatedDefault,
            occupiedSanitizedNames: ["slug"]
        )
        let thirdVariant = try WorkspaceNameGenerator.resolveName(
            "slug",
            source: .generatedDefault,
            occupiedSanitizedNames: ["slug", "slug-2"]
        )

        #expect(secondVariant == "slug-2")
        #expect(thirdVariant == "slug-3")
    }
}
