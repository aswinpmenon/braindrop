import Foundation
import PDFKit
import ImageIO

enum FileInspector {

    struct Info {
        var size: Int64? = nil
        var kind: String? = nil     // "PDF", "JPEG", "MP4", …
        var extraMeta: String? = nil // "42 pages", "1920×1080 px", "3:24"
    }

    static func inspect(_ path: String) -> Info {
        let url = URL(fileURLWithPath: path)
        var info = Info()

        // Size (bytes)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            info.size = attrs[.size] as? Int64
        }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            info.kind = "PDF"
            if let doc = PDFDocument(url: url) {
                info.extraMeta = "\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")"
            }

        case "jpg", "jpeg":
            info.kind = "JPEG"
            info.extraMeta = imageDimensions(url)
        case "png":
            info.kind = "PNG"
            info.extraMeta = imageDimensions(url)
        case "heic", "heif":
            info.kind = "HEIC"
            info.extraMeta = imageDimensions(url)
        case "gif":
            info.kind = "GIF"
            info.extraMeta = imageDimensions(url)
        case "tiff", "tif":
            info.kind = "TIFF"
            info.extraMeta = imageDimensions(url)
        case "webp":
            info.kind = "WebP"
            info.extraMeta = imageDimensions(url)

        case "mp4":   info.kind = "MP4 video"
        case "mov":   info.kind = "MOV video"
        case "avi":   info.kind = "AVI video"
        case "mkv":   info.kind = "MKV video"
        case "webm":  info.kind = "WebM video"
        case "mp3":   info.kind = "MP3 audio"
        case "wav":   info.kind = "WAV audio"
        case "aac":   info.kind = "AAC audio"
        case "flac":  info.kind = "FLAC audio"
        case "m4a":   info.kind = "M4A audio"

        case "zip":   info.kind = "ZIP archive"
        case "tar":   info.kind = "TAR archive"
        case "gz":    info.kind = "GZ archive"
        case "7z":    info.kind = "7-Zip archive"
        case "rar":   info.kind = "RAR archive"

        case "txt":   info.kind = "Text file"
        case "md":    info.kind = "Markdown"
        case "rtf":   info.kind = "RTF document"
        case "doc":   info.kind = "Word document"
        case "docx":  info.kind = "Word document"
        case "xls", "xlsx": info.kind = "Spreadsheet"
        case "ppt", "pptx": info.kind = "Presentation"
        case "csv":   info.kind = "CSV"

        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt":
            info.kind = ext.uppercased() + " source"

        default:
            if !ext.isEmpty { info.kind = ext.uppercased() }
        }

        return info
    }

    // MARK: - Helpers

    private static func imageDimensions(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int
        else { return nil }
        return "\(w)×\(h) px"
    }
}
