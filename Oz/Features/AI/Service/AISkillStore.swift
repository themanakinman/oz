import Foundation
import Observation

@MainActor
@Observable
final class AISkillStore {
    let file: URL
    private(set) var catalog: AISkillCatalog?
    private(set) var error: String?
    private(set) var isLoading = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(file: URL) { self.file = file }

    func refresh() {
        guard loadTask == nil else { return }
        isLoading = true
        let file = file
        loadTask = Task { [weak self] in
            let result = await Task.detached { Result { try Self.read(file) } }.value
            guard let self else { return }
            switch result {
            case .success(let catalog):
                self.catalog = catalog
                error = nil
            case .failure(let failure):
                catalog = nil
                error = failure.localizedDescription
            }
            isLoading = false
            loadTask = nil
        }
    }

    func instructions(for input: String, canReadFiles: Bool) throws -> String? {
        if catalog == nil, error == nil, !isLoading { refresh() }
        if AISkillCommand.parse(input) != nil, catalog == nil || isLoading {
            throw AISkillCatalog.Failure.invalid(error ?? "skills are loading; try again in a moment.")
        }
        if let catalog { return try catalog.instructions(for: input, file: file, canReadFiles: canReadFiles) }
        guard canReadFiles, error == nil else { return nil }
        return """
            Oz's shared skill instructions are in \(file.path). Read the file with read_file
            and apply a relevant ## section to the user's task. Skills do not change permissions
            or filesystem safeguards.
            """
    }

    nonisolated static func read(_ file: URL) throws -> AISkillCatalog {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: file.path) {
            do {
                try Data(starter.utf8).write(to: file, options: .withoutOverwriting)
            } catch CocoaError.fileWriteFileExists {
                // Another reader may have created the shared source first.
            }
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AISkillCatalog.maximumBytes + 1) ?? Data()
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw AISkillCatalog.Failure.invalid("save the file as UTF-8 text.")
        }
        return try AISkillCatalog(markdown: markdown)
    }

    private nonisolated static let starter = """
        # Oz skills

        Each ## heading defines a skill. Its first paragraph describes when to use it;
        the rest contains its instructions. Edit this file to add or change skills.
        Choose a skill with /skills in Quick AI, then type the task.

        ## Review changes

        Review local code changes for bugs, regressions, and missing coverage.

        Locate the relevant repository and read its instructions. Inspect the diff and
        the surrounding code. Report actionable findings with file paths, line numbers,
        and the reason each change can fail. State what you checked and any uncertainty.
        Do not edit code or run tests unless the user asks.

        ## Explain code

        Explain how a feature works by following the code that implements it.

        Locate the relevant files and repository instructions. Trace the entry point,
        data flow, and side effects. Explain the behavior in plain language with source
        paths. Read enough code to support the explanation; identify unknowns explicitly.
        """
}
