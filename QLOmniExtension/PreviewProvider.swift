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
            let data = try Data(contentsOf: url)
            let limit = 1024 * 1024  // 1 MiB cap
            let displayData = data.count > limit ? data.prefix(limit) : data
            return Data(displayData)
        }

        return reply
    }
}
