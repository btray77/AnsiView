import AnsiCore
import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Finder icons for ANSI art: the finished art, from the top, cropped to at most a square.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            handler(nil, error)
            return
        }
        let file = ArtFile(data: data, fileExtension: url.pathExtension)
        let pixels = CGSize(width: request.maximumSize.width * request.scale,
                            height: request.maximumSize.height * request.scale)
        guard let image = Thumbnail.render(file, maximum: pixels) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let size = CGSize(width: CGFloat(image.width) / request.scale, height: CGFloat(image.height) / request.scale)
        let reply = QLThumbnailReply(contextSize: size) { context in
            context.interpolationQuality = .none
            // Fill whatever area the context offers (it may be in points or in pixels).
            context.draw(image, in: context.boundingBoxOfClipPath)
            return true
        }
        reply.extensionBadge = url.pathExtension.uppercased()
        handler(reply, nil)
    }
}
