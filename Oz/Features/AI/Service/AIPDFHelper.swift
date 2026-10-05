import Foundation

@main
nonisolated enum AIPDFHelper {
    static func main() async {
        guard CommandLine.arguments.count == 4, let limit = Int(CommandLine.arguments[2]),
            ["extract", "validate"].contains(CommandLine.arguments[3]) else { exit(2) }
        do {
            let result = try await AIPDFTextExtractor.extract(
                at: URL(fileURLWithPath: CommandLine.arguments[1]), maximumBytes: limit,
                validationOnly: CommandLine.arguments[3] == "validate")
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(result))
        } catch { exit(1) }
    }
}
