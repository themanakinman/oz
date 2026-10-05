import Foundation

struct AIPDFTextProvider: AIProvider {
    let base: any AIProvider
    let maximumBytes: Int
    var executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AIPDFHelper")

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            let task = Task.detached {
                do {
                    var messages: [AIMessage] = []
                    for message in request.messages {
                        try Task.checkCancellation()
                        var documents: [AIDocument] = []
                        for document in message.documents {
                            guard document.mimeType == AIAttachmentPolicy.pdfMIMEType else {
                                documents.append(document)
                                continue
                            }
                            continuation.yield(.thinking)
                            let result = try await AIPDFTextReader.extract(
                                document.data, maximumBytes: maximumBytes, executable: executable)
                            documents.append(AIDocument(data: Data(result.content.utf8), mimeType: "text/plain",
                                                        name: document.name))
                        }
                        messages.append(AIMessage(
                            role: message.role, text: AIAttachmentPolicy.prompt(text: message.text, documents: documents),
                            images: message.images, toolCalls: message.toolCalls, toolResult: message.toolResult))
                    }
                    for try await event in base.stream(request.continuing(with: messages, tools: request.tools)) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
