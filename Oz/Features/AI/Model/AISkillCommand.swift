import Foundation

enum AISkillCommand: Equatable, Sendable {
    case command
    case browse(String)
    case invocation(id: String, task: String)

    static func parse(_ input: String, identifiers: Set<String> = []) -> Self? {
        let text = String(input.drop(while: \.isWhitespace))
        guard !text.isEmpty else { return nil }
        let command = String(text.prefix { !$0.isWhitespace }).lowercased()
        if command != "/skills" {
            return !text.contains(where: \.isWhitespace) && "/skills".hasPrefix(command) ? .command : nil
        }
        let rest = text.dropFirst(command.count).drop(while: \.isWhitespace)
        guard let boundary = rest.firstIndex(where: \.isWhitespace) else { return .browse(String(rest)) }
        let id = String(rest[..<boundary]).lowercased()
        guard identifiers.contains(id) else { return .browse(String(rest)) }
        return .invocation(
            id: id,
            task: String(rest[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isCompletion: Bool {
        switch self {
        case .command, .browse: true
        case .invocation: false
        }
    }
}
