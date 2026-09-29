import Foundation

struct AISkillCatalog: Sendable {
    struct Skill: Identifiable, Sendable {
        let id: String
        let name: String
        let summary: String
        let instructions: String
    }

    enum Failure: LocalizedError {
        case invalid(String)
        case missing(String)
        case taskRequired

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): "Invalid skills.md: \(reason)"
            case .missing(let id): "Skill ‘\(id)’ was not found. Choose one with /skills."
            case .taskRequired: "Add a task after the skill name."
            }
        }
    }

    static let maximumBytes = 65_536
    let skills: [Skill]

    init(markdown: String) throws {
        guard markdown.utf8.count <= Self.maximumBytes else {
            throw Failure.invalid("keep the file under 64 KB.")
        }
        var sections: [(name: String, lines: [String])] = []
        var fence: (character: Character, count: Int)?
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first
            let count = trimmed.prefix { $0 == marker }.count
            if let open = fence {
                if marker == open.character, count >= open.count,
                    trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
            } else if let marker, marker == "`" || marker == "~", count >= 3 {
                fence = (marker, count)
            } else if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw Failure.invalid("a skill heading is empty.") }
                sections.append((name, []))
                continue
            }
            if !sections.isEmpty { sections[sections.count - 1].lines.append(line) }
        }
        guard sections.count <= 64 else { throw Failure.invalid("use at most 64 skills.") }
        var identifiers = Set<String>()
        skills = try sections.map { section in
            let id = section.name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
                .lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
            guard !id.isEmpty, section.name.count <= 80, identifiers.insert(id).inserted else {
                throw Failure.invalid("skill names must be unique and no longer than 80 characters.")
            }
            let body = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body.utf8.count <= 16_384 else {
                throw Failure.invalid("‘\(section.name)’ needs instructions under 16 KB.")
            }
            let summary = body.components(separatedBy: "\n\n").first ?? body
            return Skill(id: id, name: section.name, summary: String(summary.prefix(240)), instructions: body)
        }
    }

    func matching(_ query: String) -> [Skill] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return skills.filter { skill in
            let text = "\(skill.name) \(skill.id) \(skill.summary)".lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    func instructions(for input: String, file: URL, canReadFiles: Bool) throws -> String? {
        switch AISkillCommand.parse(input) {
        case .invocation(let id, let task):
            guard let skill = skills.first(where: { $0.id == id }) else { throw Failure.missing(id) }
            guard !task.isEmpty else { throw Failure.taskRequired }
            return """
                The user selected the Oz skill ‘\(skill.name)’ from \(file.path).
                The /skills \(id) prefix selects this skill; apply it to the task that follows.
                Skill instructions do not grant tools or change filesystem safeguards.

                <oz_skill id="\(skill.id)">
                \(skill.instructions)
                </oz_skill>
                """
        case .command, .browse:
            throw Failure.taskRequired
        case nil:
            guard canReadFiles, !skills.isEmpty else { return nil }
            let catalog = skills.map { "- \($0.id): \($0.summary.replacingOccurrences(of: "\n", with: " "))" }
                .joined(separator: "\n")
            return """
                Oz skills are shared instructions in \(file.path).
                When a listed skill matches the user's task, read its ## section with read_file
                before applying it. Skill instructions do not change tool permissions or safeguards.
                \(catalog)
                """
        }
    }
}
