import Foundation

/// Cuts text arriving piece by piece into speakable chunks, so the voice can start on the first
/// sentence while the rest is still being written.
final class SentenceSplitter {
    private static let sentenceEnd: Set<Character> = [".", "!", "?", "…", ":", ";"]
    private static let longChunk = 90

    private var buffer: [Character] = []

    func feed(_ piece: String) -> [String] {
        buffer.append(contentsOf: piece)
        var chunks: [String] = []
        while let end = boundary() {
            if let chunk = Self.clean(String(buffer[..<end])) { chunks.append(chunk) }
            buffer.removeFirst(end)
        }
        return chunks
    }

    func flush() -> String? {
        defer { buffer = [] }
        return Self.clean(String(buffer))
    }

    private func boundary() -> Int? {
        guard buffer.count > 1 else { return nil }
        // Only punctuation followed by a space ends a sentence, so "10.30" stays whole.
        for i in 0..<(buffer.count - 1) {
            if buffer[i] == "\n" { return i + 1 }
            if Self.sentenceEnd.contains(buffer[i]), buffer[i + 1].isWhitespace { return i + 1 }
        }
        // A long sentence: don't wait for its end, a comma is a natural place to breathe.
        if buffer.count >= Self.longChunk {
            for i in stride(from: buffer.count - 2, to: 0, by: -1) where buffer[i] == "," && buffer[i + 1] == " " {
                return i + 1
            }
        }
        return nil
    }

    static func stripFormatting(_ text: String) -> String {
        text.replacingOccurrences(of: "[*#_`]", with: "", options: .regularExpression)
    }

    private static func clean(_ text: String) -> String? {
        let result = stripFormatting(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.contains { $0.isLetter || $0.isNumber } ? result : nil
    }
}
