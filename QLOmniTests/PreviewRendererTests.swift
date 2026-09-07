import CoreFoundation
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

    private func encodedFixture(
        _ value: String,
        encoding: String.Encoding,
        bom: [UInt8] = []
    ) throws -> Data {
        let encoded = try XCTUnwrap(value.data(using: encoding, allowLossyConversion: false))
        return Data(bom) + encoded
    }

    private func assertRenderedText(
        _ value: String,
        encoding: String.Encoding,
        bom: [UInt8] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bytes = try encodedFixture(value, encoding: encoding, bom: bom)
        let url = try writeFile(name: UUID().uuidString, bytes: bytes)

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertEqual(String(data: result, encoding: .utf8), value, file: file, line: line)
    }

    private func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        )
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

    func testUnicodeBOMFixturesDecodeToUTF8() throws {
        let value = "Hello, 日本語\n"

        try assertRenderedText(value, encoding: .utf8, bom: [0xEF, 0xBB, 0xBF])
        try assertRenderedText(value, encoding: .utf16LittleEndian, bom: [0xFF, 0xFE])
        try assertRenderedText(value, encoding: .utf16BigEndian, bom: [0xFE, 0xFF])
        try assertRenderedText(
            value,
            encoding: .utf32LittleEndian,
            bom: [0xFF, 0xFE, 0x00, 0x00]
        )
        try assertRenderedText(
            value,
            encoding: .utf32BigEndian,
            bom: [0x00, 0x00, 0xFE, 0xFF]
        )
    }

    func testJapaneseEncodingFixturesDecodeToUTF8() throws {
        let value = "日本語のテキスト\n"

        try assertRenderedText(value, encoding: .iso2022JP)
        try assertRenderedText(value, encoding: .shiftJIS)
        try assertRenderedText(value, encoding: .japaneseEUC)
    }

    func testCJKEncodingFixturesDecodeToUTF8() throws {
        try assertRenderedText("한국어 텍스트\n", encoding: cfEncoding(.EUC_KR))
        try assertRenderedText("简体中文文本\n", encoding: cfEncoding(.GB_18030_2000))
        try assertRenderedText("繁體中文文本\n", encoding: cfEncoding(.big5))
    }

    func testWesternEncodingFixtureDecodesToUTF8() throws {
        try assertRenderedText("café €\n", encoding: .windowsCP1252)
    }

    func testMalformedBOMPayloadThrows() throws {
        let url = try writeFile(name: "malformed-utf16.txt", bytes: Data([0xFF, 0xFE, 0x41]))

        XCTAssertThrowsError(try PreviewRenderer.render(fileAt: url)) { error in
            XCTAssertEqual(error as? PreviewRenderer.Error, .invalidTextEncoding)
        }
    }

    func testTruncationPreservesUTF8CodePointBoundary() throws {
        let value = String(repeating: "日", count: PreviewRenderer.truncationLimit)
        let url = try writeFile(name: "large-utf8.txt", bytes: Data(value.utf8))

        let result = try PreviewRenderer.render(fileAt: url)

        XCTAssertLessThanOrEqual(result.count, PreviewRenderer.truncationLimit)
        XCTAssertNotNil(String(data: result, encoding: .utf8))
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
