import Cocoa
import Quartz
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL

        let reply = QLPreviewReply(
            dataOfContentType: .plainText,
            contentSize: .zero
        ) { (replyToUpdate: QLPreviewReply) -> Data in
            replyToUpdate.stringEncoding = .utf8
            return try PreviewRenderer.render(fileAt: url)
        }

        return reply
    }
}
