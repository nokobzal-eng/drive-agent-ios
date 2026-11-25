import Compression
import Foundation

/// Reads the text out of a WhatsApp chat export: a .txt, or the .txt files inside a .zip
/// (WhatsApp on iPhone always exports a .zip, with or without media). Only the .txt entries are
/// unpacked; media is skipped. Plain zip only (stored or deflate), which is what WhatsApp writes.
enum ZipText {
    private static let maxTextBytes = 20_000_000

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.count >= 2 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B {
            let texts = textEntries(in: data)
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        let head = data.prefix(min(data.count, maxTextBytes))
        guard !head.prefix(2000).contains(0) else { return nil }
        return String(decoding: head, as: UTF8.self)
    }

    private static func textEntries(in d: Data) -> [String] {
        // End of central directory: the last record with this signature.
        let eocdSig: UInt32 = 0x0605_4B50
        guard d.count >= 22 else { return [] }
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 65_557)
        while i >= floor {
            if u32(d, i) == eocdSig { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }
        let count = Int(u16(d, eocd + 10))
        var p = Int(u32(d, eocd + 16))
        var texts: [String] = []
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4B50 else { break }
            let method = u16(d, p + 10)
            let compressed = Int(u32(d, p + 20))
            let size = Int(u32(d, p + 24))
            let nameLength = Int(u16(d, p + 28))
            let extraLength = Int(u16(d, p + 30))
            let commentLength = Int(u16(d, p + 32))
            let local = Int(u32(d, p + 42))
            let nameEnd = min(d.count, p + 46 + nameLength)
            let name = String(decoding: d[(d.startIndex + p + 46)..<(d.startIndex + nameEnd)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength

            guard name.lowercased().hasSuffix(".txt"), size > 0, size <= maxTextBytes,
                  local + 30 <= d.count, u32(d, local) == 0x0403_4B50 else { continue }
            let start = local + 30 + Int(u16(d, local + 26)) + Int(u16(d, local + 28))
            guard start + compressed <= d.count else { continue }
            let body = d[(d.startIndex + start)..<(d.startIndex + start + compressed)]
            switch method {
            case 0:
                texts.append(String(decoding: body, as: UTF8.self))
            case 8:
                if let raw = inflate(Data(body), size: size) { texts.append(String(decoding: raw, as: UTF8.self)) }
            default:
                continue
            }
        }
        return texts
    }

    /// Raw DEFLATE, as stored in zip files (Apple's ZLIB algorithm is raw deflate).
    private static func inflate(_ input: Data, size: Int) -> Data? {
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let from = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, size, from, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= d.count else { return 0 }
        let s = d.startIndex + at
        return UInt16(d[s]) | UInt16(d[s + 1]) << 8
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= d.count else { return 0 }
        let s = d.startIndex + at
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }
}
