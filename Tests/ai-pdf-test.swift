import AppKit
import PDFKit

@main
@MainActor
struct AIPDFTest {
    private static var failures = 0

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oz-pdf-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = pdf(["First page: Oz attachment test", "Second page: page boundaries survive"])
        let file = root.appendingPathComponent("text.pdf")
        try text.write(to: file)
        let result = try await AIPDFTextExtractor.extract(at: file, maximumBytes: 32_768)
        expect(result.error == nil && !result.usedOCR && !result.truncated, "selectable text needs no OCR")
        expect(result.content.contains("[Page 1]") && result.content.contains("[Page 2]"), "retains page boundaries")
        expect(result.content.contains("attachment test") && result.processedPages == 2, "extracts both pages")
        let long = root.appendingPathComponent("long.pdf")
        try pdf([String(repeating: "Text to exceed the extraction budget. ", count: 100)]).write(to: long)
        let partial = try await AIPDFTextExtractor.extract(at: long, maximumBytes: 512)
        expect(partial.truncated && partial.content.utf8.count <= 512, "bounded text is explicitly partial")
        expect(partial.content.contains("Partial extraction"), "the model sees the truncation notice")
        let many = root.appendingPathComponent("many.pdf")
        try pdf(Array(repeating: "Page text", count: 65)).write(to: many)
        let pages = try await AIPDFTextExtractor.extract(at: many, maximumBytes: 32_768)
        expect(pages.truncated && pages.processedPages == 64 && pages.pageCount == 65, "bounds page count")
        let scanned = root.appendingPathComponent("scan.pdf")
        let image = NSImage(size: NSSize(width: 800, height: 300), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("SCANNED PDF ATTACHMENT" as NSString).draw(
                at: NSPoint(x: 40, y: 120),
                withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
            return true
        }
        let scan = PDFDocument()
        scan.insert(PDFPage(image: image)!, at: 0)
        expect(scan.write(to: scanned), "writes scanned fixture")
        let recognized = try await AIPDFTextExtractor.extract(at: scanned, maximumBytes: 32_768)
        expect(recognized.usedOCR && recognized.content.contains("SCANNED"), "recognizes image-only pages")
        let locked = root.appendingPathComponent("locked.pdf")
        let document = PDFDocument(data: text)!
        expect(document.write(to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "secret"]),
               "writes locked fixture")
        let denied = try await AIPDFTextExtractor.extract(at: locked, maximumBytes: 32_768)
        expect(denied.error?.contains("locked") == true, "locked files explain their refusal")
        let invalid = root.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        let invalidResult = try await AIPDFTextExtractor.extract(at: invalid, maximumBytes: 512)
        expect(invalidResult.error != nil, "malformed PDF is refused")
        let helper = root.appendingPathComponent("AIPDFHelper")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-swift-version", "6", "Oz/Features/AI/Model/AIPDFText.swift",
                             "Oz/Features/AI/Service/AIPDFTextExtractor.swift", "Oz/Features/AI/Service/AIPDFHelper.swift",
                             "-o", helper.path]
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { exit(1) }
        let isolated = try await AIPDFTextReader.extract(text, executable: helper)
        expect(isolated == result, "bundled helper path returns the same extraction")
        let validated = try await AIPDFTextReader.extract(text, validationOnly: true, executable: helper)
        expect(validated.content.isEmpty && validated.pageCount == 2 && !validated.usedOCR,
               "native delivery validates the PDF without extracting or changing its bytes")
        do {
            _ = try await AIPDFTextReader.extract(Data("not PDF".utf8), executable: helper)
            expect(false, "reader must report malformed PDF")
        } catch { expect(error.localizedDescription.contains("could not be read"), "reader preserves actionable errors") }
        let slow = root.appendingPathComponent("slow-helper")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        let reading = Task { try await AIPDFTextReader.extract(text, executable: slow) }
        try await Task.sleep(for: .milliseconds(150))
        let stopping = ContinuousClock.now
        reading.cancel()
        do {
            _ = try await reading.value
            expect(false, "cancelled extraction must not stage content")
        } catch { expect(error is CancellationError, "reader propagates cancellation") }
        expect(stopping.duration(to: .now) < .seconds(2), "cancellation promptly stops the helper")
        let capture = Capture()
        let provider = AIPDFTextProvider(base: Probe(capture: capture), maximumBytes: 32_768, executable: helper)
        let request = AIRequest(instructions: "preserve instructions", messages: [
            AIMessage(role: .user, text: "Summarize", documents: [
                AIDocument(data: text, mimeType: "application/pdf", name: "report.pdf")])
        ], webSearch: true)
        for try await _ in provider.stream(request) {}
        let sent = capture.request
        expect(sent?.messages.first?.documents.isEmpty == true, "text route receives no binary PDF")
        expect(sent?.messages.first?.text.contains("Attached file: report.pdf") == true, "keeps original filename")
        expect(sent?.messages.first?.text.contains("attachment test") == true, "converted PDF reaches text transport")
        expect(sent?.instructions == request.instructions && sent?.webSearch == true, "keeps routing options")
        if failures > 0 { exit(1) }
        print("All PDF attachment checks passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL \(message)") }
    }

    private static func pdf(_ pages: [String]) -> Data {
        let output = NSMutableData()
        let consumer = CGDataConsumer(data: output)!
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 530, height: 700),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AIRequest?
        var request: AIRequest? { lock.withLock { stored } }
        func save(_ request: AIRequest) { lock.withLock { stored = request } }
    }

    private struct Probe: AIProvider {
        let capture: Capture
        func stream(_ request: AIRequest) -> AIProviderStream {
            capture.save(request)
            return AIProviderStream { $0.yield(.finished); $0.finish() }
        }
    }
}
