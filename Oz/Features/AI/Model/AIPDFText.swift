import Foundation

struct AIPDFText: Codable, Equatable, Sendable {
    static let maximumTextBytes = 32 * 1_024
    static let maximumFileBytes = 10 * 1_048_576
    static let maximumPages = 64

    let content: String
    let pageCount: Int
    let processedPages: Int
    let truncated: Bool
    let usedOCR: Bool
    var error: String?

    var label: String {
        ["Extracted text", usedOCR ? "OCR" : nil, truncated ? "Partial" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
