import Foundation

enum AntigravityToolProtocol {
    static func schema(tools: [AITool]) throws -> String {
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": [
                "text": ["type": "string"],
                "calls": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "properties": [
                            "name": ["type": "string", "enum": tools.map(\.name)],
                            "arguments": [
                                "type": "string",
                                "description": "A JSON object matching the tool's parameters."
                            ]
                        ],
                        "required": ["name", "arguments"]
                    ]
                ]
            ],
            "required": ["text", "calls"]
        ]
        return try jsonString(schema)
    }

    static func prompt(_ request: AIRequest) throws -> String {
        var sections = [
            "You are an assistant inside Oz. Native files, commands, browsers, subagents and MCP are unavailable."
        ]
        sections.append(
            request.webSearch
                ? "You may use search_web and read_url_content. Cite sources using Markdown links."
                : "Do not search the web or access external resources.")
        if !request.tools.isEmpty {
            sections.append(
                """
                Oz supplies the tools below. Return structured JSON with text and calls.
                To use a tool, put its exact name and JSON-encoded argument object in calls.
                Do not invent results. Oz executes calls and returns tool results in the conversation.
                Use only the offered tool names. When finished, return the answer in text and empty calls.
                """)
            let tools: [[String: Any]] = request.tools.map {
                ["name": $0.name, "description": $0.description, "parameters": $0.parameters.jsonObject]
            }
            sections.append("Offered Oz tools:\n" + (try jsonString(tools)))
        }
        if let instructions = request.instructions { sections.append("Instructions:\n" + instructions) }
        let messages: [[String: Any]] = request.messages.map { message in
            var object: [String: Any] = ["role": message.role.rawValue, "text": message.text]
            if !message.toolCalls.isEmpty {
                object["tool_calls"] = message.toolCalls.map {
                    ["id": $0.id, "name": $0.name, "arguments": $0.arguments]
                }
            }
            if let result = message.toolResult {
                object["tool_result"] = [
                    "id": result.callID, "content": result.content, "is_error": result.isError
                ]
            }
            return object
        }
        sections.append("Conversation:\n" + (try jsonString(messages)))
        return sections.joined(separator: "\n\n")
    }

    private static func jsonString(_ object: Any) throws -> String {
        guard let string = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)
        else { throw AIProviderError.malformedResponse }
        return string
    }

    static func events(result: [String: Any], tools: [AITool]) throws -> [AIStreamEvent] {
        guard let output = result["structured_output"] as? [String: Any],
            let text = output["text"] as? String, let calls = output["calls"] as? [[String: Any]]
        else { throw AIProviderError.responseFailed("Antigravity returned an invalid tool response.") }
        let offered = Set(tools.map(\.name))
        var events: [AIStreamEvent] = text.isEmpty ? [] : [.text(text)]
        for call in calls {
            guard let name = call["name"] as? String, offered.contains(name),
                let arguments = call["arguments"] as? String,
                (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any]
            else {
                throw AIProviderError.responseFailed("Antigravity requested an invalid or unoffered tool.")
            }
            events.append(
                .toolCallRequested(
                    AIToolCall(
                        id: "oz-" + UUID().uuidString, name: name, arguments: arguments)))
        }
        return events
    }
}
