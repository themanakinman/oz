import Foundation

@main
@MainActor
struct AISkillTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func rejects(_ markdown: String) {
        do {
            _ = try AISkillCatalog(markdown: markdown)
            preconditionFailure("Invalid catalog was accepted")
        } catch {
            checks += 1
        }
    }

    static func main() async throws {
        let markdown = """
            # Oz skills
            These introductory instructions are not a skill.

            ## Review changes
            Find bugs in the diff.

            Read the surrounding code before reporting findings.
            ### Examples
            ```markdown
            ## This is an example, not a skill
            ```
            ~~~~
            ## Also an example
            ~~~~

            ## Explain code
            Trace how a feature works.

            Follow its entry point and data flow.
            """
        let catalog = try AISkillCatalog(markdown: markdown)
        expect(catalog.skills.count == 2, "Only unfenced level-two headings define skills")
        expect(catalog.skills[0].id == "review-changes", "Names produce stable slash identifiers")
        expect(catalog.skills[0].summary == "Find bugs in the diff.", "First paragraph describes the skill")
        expect(catalog.skills[0].instructions.contains("### Examples"), "Subheadings remain in the body")
        expect(catalog.matching("bugs").first?.id == "review-changes", "Descriptions can be searched")
        expect(catalog.matching("EXPLAIN").count == 1, "Matching ignores case")
        expect(catalog.matching("missing").isEmpty, "Unknown queries yield no suggestions")
        let empty = try AISkillCatalog(markdown: "# Empty")
        expect(empty.skills.isEmpty, "An empty file has no skills")
        rejects("## Review\nBody\n## review\nOther body")
        rejects("## No instructions\n")
        rejects("## !!!\nBody")
        rejects("## Long\n" + String(repeating: "x", count: 16_385))
        rejects(String(repeating: "x", count: 65_537))
        rejects((0..<65).map { "## Skill \($0)\nBody" }.joined(separator: "\n"))

        expect(AISkillCommand.parse("/") == .command, "Slash opens the command suggestion")
        expect(AISkillCommand.parse("/ski") == .command, "Partial commands remain completable")
        expect(AISkillCommand.parse("/skills") == .browse(""), "Full command opens the catalog")
        expect(AISkillCommand.parse("/skills ") == .browse(""), "Space after command keeps suggestions")
        expect(AISkillCommand.parse("/skills rev") == .browse("rev"), "A partial identifier filters skills")
        expect(AISkillCommand.parse("/skills review-changes ") == .invocation(id: "review-changes", task: ""),
            "Selection closes completion and leaves room for the task")
        expect(AISkillCommand.parse(" /skills EXPLAIN-CODE explain this ") == .invocation(
            id: "explain-code", task: "explain this"), "Invocation separates identifier and task")
        for text in ["", "ordinary text", "explain /skills", "/Users/j/project", "/skills-other", "/s task"] {
            expect(AISkillCommand.parse(text) == nil, "Ordinary text and file paths stay ordinary text")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AI/skills.md")
        let explicit = try catalog.instructions(
            for: "/skills review-changes inspect this", file: file, canReadFiles: false)
        expect(explicit?.contains("Read the surrounding code") == true, "Selected body reaches text-only models")
        expect(explicit?.contains(file.path) == true, "Instructions identify the shared source")
        expect(explicit?.contains("Trace how a feature") == false, "Other skill bodies stay out of the request")
        expect(explicit?.contains("do not grant tools") == true, "Skill selection grants no permissions")
        let automatic = try catalog.instructions(for: "review this", file: file, canReadFiles: true)
        expect(automatic?.contains("read_file") == true, "File agents can load a matching skill themselves")
        expect(automatic?.contains("Read the surrounding code") == false, "Automatic discovery sends summaries")
        let disabled = try catalog.instructions(for: "review this", file: file, canReadFiles: false)
        expect(disabled == nil, "Text-only ordinary requests get no unusable file discovery")
        for input in ["/skills", "/skills unknown do this", "/skills review-changes "] {
            do {
                _ = try catalog.instructions(for: input, file: file, canReadFiles: true)
                preconditionFailure("Incomplete or unknown selection was sent")
            } catch { checks += 1 }
        }

        let seeded = try AISkillStore.read(file)
        expect(seeded.skills.count == 2, "Missing source gets a useful starter catalog")
        try Data(markdown.utf8).write(to: file)
        let reloaded = try AISkillStore.read(file)
        expect(reloaded.skills[0].instructions.contains("### Examples"), "Existing source is never overwritten")
        let store = AISkillStore(file: file)
        let firstRequest = try store.instructions(for: "ordinary first question", canReadFiles: true)
        expect(firstRequest?.contains(file.path) == true, "First requests can discover skills before the cache warms")
        store.refresh()
        store.refresh()
        while store.isLoading { await Task.yield() }
        expect(store.catalog?.skills.count == 2 && store.error == nil, "Refresh loads and coalesces callers")
        let routed = try store.instructions(for: "/skills review-changes task", canReadFiles: false)
        expect(routed == explicit, "The store and direct catalog use the same request instructions")
        try Data("## Broken".utf8).write(to: file)
        store.refresh()
        while store.isLoading { await Task.yield() }
        expect(store.catalog == nil && store.error != nil, "Invalid edits clear stale executable instructions")
        let brokenDiscovery = try store.instructions(for: "ordinary question", canReadFiles: true)
        expect(brokenDiscovery == nil, "Known invalid sources are not advertised for automatic execution")
        try Data("".utf8).write(to: file)
        store.refresh()
        while store.isLoading { await Task.yield() }
        expect(store.catalog?.skills.isEmpty == true && store.error == nil, "The catalog recovers after edits")
        try Data([0xFF, 0xFE]).write(to: file)
        do {
            _ = try AISkillStore.read(file)
            preconditionFailure("Non-UTF-8 source was accepted")
        } catch { checks += 1 }
        try Data(String(repeating: "x", count: 65_537).utf8).write(to: file)
        do {
            _ = try AISkillStore.read(file)
            preconditionFailure("Oversized source was accepted")
        } catch { checks += 1 }
        print("Passed \(checks) skill checks")
    }
}
