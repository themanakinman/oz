import Foundation
import PDFKit
import Vision

nonisolated enum AIPDFTextExtractor {
    static func extract(at url: URL, maximumBytes: Int, validationOnly: Bool = false) async throws -> AIPDFText {
        guard let document = PDFDocument(url: url) else { return failure("That PDF could not be read.") }
        guard !document.isLocked else { return failure("That PDF is locked. Unlock it before attaching it.") }
        guard document.pageCount > 0 else { return failure("That PDF has no pages to read.") }
        if validationOnly {
            return AIPDFText(content: "", pageCount: document.pageCount, processedPages: 0,
                             truncated: false, usedOCR: false)
        }
        let limit = max(512, min(maximumBytes, AIPDFText.maximumTextBytes))
        var content = ""
        var processed = 0
        var usedOCR = false
        var hasText = false
        var truncated = document.pageCount > AIPDFText.maximumPages
        for index in 0..<min(document.pageCount, AIPDFText.maximumPages) {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                return failure("A page in that PDF could not be read.")
            }
            var text = autoreleasepool { page.string ?? "" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                guard let image = autoreleasepool(invoking: { render(page) }) else {
                    return failure("A page in that PDF could not be rendered for text recognition.")
                }
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                request.minimumTextHeightFraction = 0
                let observations = try await request.perform(on: image)
                text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                usedOCR = true
            }
            hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let block = "\n\n[Page \(index + 1)]\n" + (text.isEmpty ? "[No readable text on this page]" : text)
            let remaining = limit - 256 - content.utf8.count
            if block.utf8.count > remaining {
                content += prefix(block, bytes: max(0, remaining))
                truncated = true
                break
            }
            content += block
            processed += 1
        }
        if !hasText {
            return failure("No text could be extracted from that PDF, including with OCR.")
        }
        let introduction = "PDF extracted as text; visual layout is not preserved."
        let notice = truncated ? "\n\n[Partial extraction: page or text limit reached; the PDF is not included in full.]" : ""
        return AIPDFText(content: introduction + content + notice, pageCount: document.pageCount,
                         processedPages: processed, truncated: truncated, usedOCR: usedOCR)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        guard let reference = page.pageRef else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, 2_048 / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        return context.makeImage()
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var data = text.utf8.prefix(bytes)
        while !data.isEmpty, String(bytes: data, encoding: .utf8) == nil { data = data.dropLast() }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func failure(_ message: String) -> AIPDFText {
        AIPDFText(content: "", pageCount: 0, processedPages: 0, truncated: false, usedOCR: false, error: message)
    }
}
