import Darwin
import Foundation

@main
nonisolated enum AIFileHelper {
    private static let outputLock = NSLock()

    private enum Event: Sendable {
        case request(Data)
        case completed(String)
        case inputEnded
    }

    static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let runner = AIFileToolRunner(
            home: URL(fileURLWithPath: CommandLine.arguments[1]),
            revisions: URL(fileURLWithPath: CommandLine.arguments[2]))
        let (events, continuation) = AsyncStream<Event>.makeStream()
        signal(SIGPIPE, SIG_IGN)
        // CLI clients may terminate their helper instead of sending an MCP cancellation.
        let signals = [SIGTERM, SIGINT].map { value in
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global(qos: .utility))
            source.setEventHandler { @Sendable in continuation.yield(.inputEnded) }
            source.resume()
            return source
        }
        defer { for source in signals { source.cancel() } }
        let reader = Task.detached { readInput(into: continuation) }
        var running: [String: Task<Void, Never>] = [:]
        input: for await event in events {
            switch event {
            case .inputEnded: break input
            case .completed(let id): running[id] = nil
            case .request(let line):
                guard let request = JSONValue(data: line)?.objectValue else { continue }
                if request["method"]?.stringValue == "notifications/cancelled",
                    let id = request["params"]?.objectValue?["requestId"], let key = try? key(id) {
                    running[key]?.cancel()
                    continue
                }
                guard let id = request["id"], let method = request["method"]?.stringValue else { continue }
                guard let key = try? key(id) else { continue }
                guard running[key] == nil, running.count < 4 else {
                    let error: [String: Any] = ["code": -32_000, "message": "Too many concurrent tools or duplicate request ID."]
                    do { try send(["error": error], id: id) } catch { break input }
                    continue
                }
                running[key] = Task.detached {
                    defer { continuation.yield(.completed(key)) }
                    do { try await respond(to: request, method: method, id: id, using: runner) } catch {
                        do {
                            try send(["error": ["code": -32_603, "message": error.localizedDescription]], id: id)
                        } catch { continuation.yield(.inputEnded) }
                    }
                }
            }
        }
        reader.cancel()
        for task in running.values { task.cancel() }
        for task in running.values { await task.value }
        continuation.finish()
    }

    private static func readInput(into events: AsyncStream<Event>.Continuation) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                events.yield(.inputEnded)
                return
            }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A) {
                guard newline - buffer.startIndex <= AIFileToolRunner.maxFileBytes * 2 else {
                    events.yield(.inputEnded)
                    return
                }
                events.yield(.request(Data(buffer[..<newline])))
                buffer.removeSubrange(...newline)
            }
            guard buffer.count <= AIFileToolRunner.maxFileBytes * 2 else {
                events.yield(.inputEnded)
                return
            }
        }
        events.yield(.inputEnded)
    }

    private static func respond(
        to request: [String: JSONValue], method: String, id: JSONValue, using runner: AIFileToolRunner
    ) async throws {
        let response: [String: Any]
        switch method {
        case "initialize":
            response = ["result": [
                "protocolVersion": request["params"]?.objectValue?["protocolVersion"]?.stringValue ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Oz Files", "version": "1"],
                "instructions": AIFileTools.instructions(home: runner.home.path)
            ]]
        case "ping": response = ["result": [:]]
        case "tools/list":
            response = ["result": ["tools": AIFileTools.tools.map { tool in
                ["name": String(tool.name.dropFirst(AIFileTools.prefix.count)),
                 "title": tool.title, "description": tool.description,
                 "inputSchema": tool.parameters.jsonObject]
            }]]
        case "tools/call":
            let params = request["params"]?.objectValue ?? [:]
            guard let arguments = params["arguments"]?.objectValue else {
                try send(["error": ["code": -32_602, "message": "Tool arguments must be an object."]], id: id)
                return
            }
            let data = try JSONSerialization.data(withJSONObject: arguments.mapValues(\.jsonObject))
            let result = await runner.invoke(AIToolCall(
                id: "file-call", name: AIFileTools.prefix + (params["name"]?.stringValue ?? ""),
                arguments: String(data: data, encoding: .utf8) ?? "{}"))
            response = ["result": ["content": [["type": "text", "text": result.content]], "isError": result.isError]]
        default:
            response = ["error": ["code": -32_601, "message": "Unknown filesystem server method."]]
        }
        try send(response, id: id)
    }

    private static func key(_ id: JSONValue) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: id.jsonObject, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func send(_ response: [String: Any], id: JSONValue) throws {
        var object = response
        object["jsonrpc"] = "2.0"
        object["id"] = id.jsonObject
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try outputLock.withLock { try FileHandle.standardOutput.write(contentsOf: data) }
    }
}
