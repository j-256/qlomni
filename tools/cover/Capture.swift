import AppKit
import Quartz

@main
struct CoverCapture {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { exit(2) }
        let source = URL(fileURLWithPath: arguments[1])
        let rendered = try PreviewRenderer.render(fileAt: source)
        guard let text = String(data: rendered, encoding: .utf8), text.contains("GET https://api.example.com/") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let temporaryPreview = URL(fileURLWithPath: arguments[2]).appendingPathComponent("sample.txt")
        try rendered.write(to: temporaryPreview)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = source.lastPathComponent
        window.appearance = NSAppearance(named: .darkAqua)
        let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal)!
        window.contentView = preview
        preview.previewItem = temporaryPreview as NSURL
        window.makeKeyAndOrderFront(nil)
        defer { preview.close(); window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        let frame = window.contentView!.superview!
        let scale = 4
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(frame.bounds.width) * scale,
            pixelsHigh: Int(frame.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = frame.bounds.size
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 10_000 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = URL(fileURLWithPath: arguments[3])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        print("Captured \(output.path)")
    }
}
