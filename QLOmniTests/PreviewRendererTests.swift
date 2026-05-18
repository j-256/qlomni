import XCTest

final class PreviewRendererTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qlomni-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(name: String, bytes: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testShortContentReturnedVerbatim() throws {
        let content = "hello world\n".data(using: .utf8)!
        let url = try writeFile(name: "short.txt", bytes: content)

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertEqual(result, content)
    }

    func testEmptyFileReturnsEmptyData() throws {
        let url = try writeFile(name: "empty.txt", bytes: Data())

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertEqual(result.count, 0)
    }

    func testExactlyLimitNotTruncated() throws {
        let bytes = Data(repeating: 0x41, count: PreviewRenderer.truncationLimit)
        let url = try writeFile(name: "exact.txt", bytes: bytes)

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertEqual(result.count, PreviewRenderer.truncationLimit)
        XCTAssertEqual(result, bytes)
    }

    func testOverLimitTruncated() throws {
        let overLimit = PreviewRenderer.truncationLimit + 1024
        let bytes = Data(repeating: 0x42, count: overLimit)
        let url = try writeFile(name: "big.txt", bytes: bytes)

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertEqual(result.count, PreviewRenderer.truncationLimit)
        XCTAssertEqual(result, bytes.prefix(PreviewRenderer.truncationLimit))
    }

    func testNonexistentFileThrows() {
        let url = tempDir.appendingPathComponent("does-not-exist.txt")

        XCTAssertThrowsError(try PreviewRenderer.render(fileAt: url))
    }

    func testBinaryWithNulInPrefixThrows() throws {
        var bytes = Data("starts as text".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: Data(repeating: 0xFF, count: 100))
        let url = try writeFile(name: "binary.dat", bytes: bytes)

        XCTAssertThrowsError(try PreviewRenderer.render(fileAt: url)) { error in
            XCTAssertEqual(error as? PreviewRenderer.Error, .binaryContent)
        }
    }

    func testNulPastSniffWindowDoesNotThrow() throws {
        var bytes = Data(repeating: 0x41, count: PreviewRenderer.sniffSize)
        bytes.append(0x00)
        bytes.append(contentsOf: Data(repeating: 0x42, count: 100))
        let url = try writeFile(name: "late-nul.txt", bytes: bytes)

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertEqual(result.count, bytes.count)
    }
}
