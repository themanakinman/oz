import Foundation

@main
nonisolated enum AIFileHelper {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let runner = AIFileToolRunner(
            home: URL(fileURLWithPath: CommandLine.arguments[1]),
            revisions: URL(fileURLWithPath: CommandLine.arguments[2]))
        var buffer = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                guard newline - buffer.startIndex <= AIFileToolRunner.maxFileBytes * 2 else { exit(3) }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                try respond(to: line, using: runner)
            }
            guard buffer.count <= AIFileToolRunner.maxFileBytes * 2 else { exit(3) }
        }
    }

    private static func respond(to line: Data, using runner: AIFileToolRunner) throws {
        guard let request = JSONValue(data: line)?.objectValue,
            let id = request["id"], let method = request["method"]?.stringValue
        else { return }
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
            let result = runner.execute(AIToolCall(
                id: "file-call", name: AIFileTools.prefix + (params["name"]?.stringValue ?? ""),
                arguments: String(data: data, encoding: .utf8) ?? "{}"))
            response = ["result": ["content": [["type": "text", "text": result.content]], "isError": result.isError]]
        default:
            response = ["error": ["code": -32_601, "message": "Unknown filesystem server method."]]
        }
        try send(response, id: id)
    }

    private static func send(_ response: [String: Any], id: JSONValue) throws {
        var object = response
        object["jsonrpc"] = "2.0"
        object["id"] = id.jsonObject
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
