import AppKit

enum ImageClipboard {
    enum CopyError: LocalizedError {
        case invalidImage, writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法生成图片，请重试。"
            case .writeFailed: return "剪贴板写入失败，请重试。"
            }
        }
    }

    /// Prepare both formats before replacing the clipboard; report success only after a confirmed write.
    static func write(_ image: NSImage, to pasteboard: NSPasteboard = .general) throws {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.max {
            Int64($0.pixelsWide) * Int64($0.pixelsHigh) < Int64($1.pixelsWide) * Int64($1.pixelsHigh)
        }
        let cgImage = bitmap?.cgImage ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw CopyError.invalidImage
        }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { throw CopyError.writeFailed }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CopyError.writeFailed }
    }
}
