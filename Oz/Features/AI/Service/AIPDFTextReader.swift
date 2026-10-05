import Darwin
import Foundation

nonisolated enum AIPDFTextReader {
    private static let queue = DispatchQueue(label: "com.oz.ai-pdf", qos: .userInitiated, attributes: .concurrent)

    static func extract(
        _ data: Data, maximumBytes: Int = AIPDFText.maximumTextBytes, validationOnly: Bool = false,
        executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AIPDFHelper")
    ) async throws -> AIPDFText {
        try Task.checkCancellation()
        guard data.count <= AIPDFText.maximumFileBytes else {
            throw AIProviderError.responseFailed("That PDF exceeds the 10 MB attachment limit.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oz-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("document.pdf")
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [file.path, String(maximumBytes), validationOnly ? "validate" : "extract"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        if Task.isCancelled { terminate(process) }
        let deadline = Task.detached {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            terminate(process)
        }
        defer { deadline.cancel() }
        let result: Result<AIPDFText, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: collect(process, output: output)) }
            }
        } onCancel: { terminate(process) }
        try Task.checkCancellation()
        return try result.get()
    }

    private static func collect(_ process: Process, output: Pipe) -> Result<AIPDFText, Error> {
        defer {
            terminate(process)
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        do {
            var bytes = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 4_096), !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= 256 * 1_024 else {
                    throw AIProviderError.responseFailed("PDF extraction exceeded its output limit.")
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AIProviderError.responseFailed("PDF extraction failed or timed out. Try a smaller PDF.")
            }
            let result = try JSONDecoder().decode(AIPDFText.self, from: bytes)
            if let error = result.error { throw AIProviderError.responseFailed(error) }
            return .success(result)
        } catch { return .failure(error) }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
