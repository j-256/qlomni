import Foundation

enum PreviewRenderer {
    static let truncationLimit = 1024 * 1024  // 1 MiB
    static let sniffSize = 8192

    enum Error: Swift.Error {
        case binaryContent
    }

    static func render(fileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let prefix = try handle.read(upToCount: sniffSize) ?? Data()
        if prefix.contains(0x00) {
            throw Error.binaryContent
        }

        if prefix.count < sniffSize {
            return prefix
        }

        let remainingBudget = truncationLimit - prefix.count
        let rest = try handle.read(upToCount: remainingBudget) ?? Data()
        return prefix + rest
    }
}
