import CoreFoundation
import Foundation

enum PreviewRenderer {
    static let truncationLimit = 1024 * 1024 // 1 MiB
    static let sniffSize = 8192
    private static let trailingDecodeAllowance = 16
    private static let binaryThreshold = 0.3

    enum Error: Swift.Error {
        case binaryContent
        case invalidTextEncoding
    }

    static func render(fileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let readLimit = truncationLimit + trailingDecodeAllowance
        let content = try handle.read(upToCount: readLimit) ?? Data()
        let hasMoreContent = !(try handle.read(upToCount: 1) ?? Data()).isEmpty
        guard !content.isEmpty else {
            return content
        }

        let sample = Data(content.prefix(sniffSize))
        let bom = detectBOM(sample)
        if bom == nil && isBinary(sample) {
            throw Error.binaryContent
        }

        let decoded: String
        if let bom {
            let payload = Data(content.dropFirst(bom.length))
            guard let value = decode(payload, as: bom.encoding, mayHaveTruncatedTail: hasMoreContent) else {
                throw Error.invalidTextEncoding
            }
            decoded = value
        } else {
            guard let value = detectAndDecode(content, mayHaveTruncatedTail: hasMoreContent) else {
                throw Error.invalidTextEncoding
            }
            decoded = value
        }

        return boundedUTF8Data(decoded)
    }

    private static func detectAndDecode(_ data: Data, mayHaveTruncatedTail: Bool) -> String? {
        if hasISO2022JPEscapeSequence(data),
           let value = decode(data, as: .iso2022JP, mayHaveTruncatedTail: mayHaveTruncatedTail) {
            return value
        }

        if let value = decode(data, as: .utf8, mayHaveTruncatedTail: mayHaveTruncatedTail) {
            return value
        }

        if let encoding = detectEncodingWithFoundation(data),
           let value = decode(data, as: encoding, mayHaveTruncatedTail: mayHaveTruncatedTail) {
            return value
        }

        for encoding in fallbackEncodings {
            if let value = decode(data, as: encoding, mayHaveTruncatedTail: mayHaveTruncatedTail) {
                return value
            }
        }

        return nil
    }

    private static func decode(
        _ data: Data,
        as encoding: String.Encoding,
        mayHaveTruncatedTail: Bool
    ) -> String? {
        let maximumTrim = mayHaveTruncatedTail ? min(trailingDecodeAllowance, data.count) : 0

        for trimmedByteCount in 0...maximumTrim {
            let byteCount = data.count - trimmedByteCount
            guard isAligned(byteCount, for: encoding) else {
                continue
            }
            if let value = String(data: data.prefix(byteCount), encoding: encoding) {
                return value
            }
        }

        return nil
    }

    private static func isAligned(_ byteCount: Int, for encoding: String.Encoding) -> Bool {
        switch encoding {
        case .utf16BigEndian, .utf16LittleEndian:
            return byteCount.isMultiple(of: 2)
        case .utf32BigEndian, .utf32LittleEndian:
            return byteCount.isMultiple(of: 4)
        default:
            return true
        }
    }

    private static func boundedUTF8Data(_ value: String) -> Data {
        let data = Data(value.utf8)
        guard data.count > truncationLimit else {
            return data
        }

        var byteCount = truncationLimit
        while byteCount > 0 {
            let candidate = Data(data.prefix(byteCount))
            if String(data: candidate, encoding: .utf8) != nil {
                return candidate
            }
            byteCount -= 1
        }

        return Data()
    }

    private static func isBinary(_ data: Data) -> Bool {
        var suspiciousCount = 0

        for byte in data {
            if byte == 0x00 {
                return true
            }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0C && byte != 0x0D && byte != 0x1B {
                suspiciousCount += 1
            }
        }

        return Double(suspiciousCount) / Double(data.count) > binaryThreshold
    }

    private static func hasISO2022JPEscapeSequence(_ data: Data) -> Bool {
        guard data.count >= 3 else {
            return false
        }

        for index in 0..<(data.count - 2) where data[index] == 0x1B {
            let second = data[index + 1]
            let third = data[index + 2]
            if second == 0x24 && (third == 0x40 || third == 0x42) {
                return true
            }
            if second == 0x28 && (third == 0x42 || third == 0x49 || third == 0x4A) {
                return true
            }
        }

        return false
    }

    private static func detectEncodingWithFoundation(_ data: Data) -> String.Encoding? {
        var convertedString: NSString?
        var usedLossyConversion = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &convertedString,
            usedLossyConversion: &usedLossyConversion
        )

        guard encoding != 0, !usedLossyConversion.boolValue else {
            return nil
        }
        return String.Encoding(rawValue: encoding)
    }

    private static var fallbackEncodings: [String.Encoding] {
        [
            .iso2022JP,
            .japaneseEUC,
            .shiftJIS,
            cfEncoding(.EUC_KR),
            cfEncoding(.GB_18030_2000),
            cfEncoding(.big5),
            cfEncoding(.GB_2312_80),
            .windowsCP1252,
            .macOSRoman
        ]
    }

    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        )
    }

    private static func detectBOM(_ data: Data) -> (encoding: String.Encoding, length: Int)? {
        let bytes = Array(data.prefix(4))

        if bytes.count >= 4 && bytes[0...3] == [0x00, 0x00, 0xFE, 0xFF] {
            return (.utf32BigEndian, 4)
        }
        if bytes.count >= 4 && bytes[0...3] == [0xFF, 0xFE, 0x00, 0x00] {
            return (.utf32LittleEndian, 4)
        }
        if bytes.count >= 3 && bytes[0...2] == [0xEF, 0xBB, 0xBF] {
            return (.utf8, 3)
        }
        if bytes.count >= 2 && bytes[0...1] == [0xFE, 0xFF] {
            return (.utf16BigEndian, 2)
        }
        if bytes.count >= 2 && bytes[0...1] == [0xFF, 0xFE] {
            return (.utf16LittleEndian, 2)
        }

        return nil
    }
}
