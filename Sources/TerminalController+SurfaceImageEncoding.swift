import AppKit
import Foundation

// MARK: - Surface image encoding

// Fork (cmux Mochi): shared encoding/rasterizing helpers behind the capture
// socket commands (`surface.screenshot`, `workspace.screenshot`). The rebase
// carried the control-socket execution policy for those commands across but
// dropped this implementation, so they answered `method_not_found`.

nonisolated enum V2SurfaceImageFormat: String {
    case png
    case jpeg

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    var base64Key: String {
        switch self {
        case .png: return "png_base64"
        case .jpeg: return "jpeg_base64"
        }
    }

    var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        }
    }
}

nonisolated struct V2SurfaceImageEncoding {
    let format: V2SurfaceImageFormat
    let jpegQuality: Double
    let maxDimension: Int?
    let profile: String
}

nonisolated struct V2EncodedSurfaceImage {
    let data: Data
    let format: V2SurfaceImageFormat
    let width: Int
    let height: Int
    let originalWidth: Int
    let originalHeight: Int
    let jpegQuality: Double?
    let maxDimension: Int?
    let profile: String

    var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }
}

extension TerminalController {
    nonisolated func v2SurfaceImageEncoding(params: [String: Any]) -> (encoding: V2SurfaceImageEncoding?, error: V2CallResult?) {
        let profile = (v2String(params, "profile") ?? "lossless").lowercased()
        let formatRaw = (v2String(params, "format") ?? v2String(params, "image_format") ?? "png").lowercased()
        let format: V2SurfaceImageFormat
        switch formatRaw {
        case "png":
            format = .png
        case "jpg", "jpeg":
            format = .jpeg
        default:
            return (nil, .err(code: "invalid_params", message: "format must be png or jpeg", data: nil))
        }

        let jpegQualityRaw = v2Double(params, "jpeg_quality") ?? v2Double(params, "quality") ?? 0.92
        guard jpegQualityRaw.isFinite else {
            return (nil, .err(code: "invalid_params", message: "jpeg_quality must be numeric", data: nil))
        }
        let jpegQuality = min(max(jpegQualityRaw, 0.1), 1.0)

        let maxDimensionRaw = v2RawString(params, "max_dimension")
            ?? v2RawString(params, "maxDimension")
            ?? v2RawString(params, "max_image_dimension")
        let maxDimension: Int?
        if let maxDimensionRaw {
            let normalized = maxDimensionRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "none" || normalized == "0" {
                maxDimension = nil
            } else if let parsed = Int(normalized), parsed > 0 {
                maxDimension = parsed
            } else {
                return (nil, .err(code: "invalid_params", message: "max_dimension must be a positive integer or none", data: nil))
            }
        } else if let numericMaxDimension = v2Int(params, "max_dimension") ?? v2Int(params, "maxDimension") ?? v2Int(params, "max_image_dimension") {
            guard numericMaxDimension > 0 else {
                return (nil, .err(code: "invalid_params", message: "max_dimension must be greater than 0", data: nil))
            }
            maxDimension = numericMaxDimension
        } else {
            maxDimension = nil
        }

        return (
            V2SurfaceImageEncoding(
                format: format,
                jpegQuality: jpegQuality,
                maxDimension: maxDimension,
                profile: profile
            ),
            nil
        )
    }

    nonisolated func v2Image(from cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private nonisolated func v2CGImage(from image: NSImage) -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private nonisolated func v2SourceCGImage(from image: NSImage) -> CGImage? {
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let cgImage = bitmap.cgImage {
            return cgImage
        }
        return v2CGImage(from: image)
    }

    private nonisolated func v2RasterizedBitmap(from cgImage: CGImage, maxDimension: Int?) -> (bitmap: NSBitmapImageRep?, width: Int, height: Int) {
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let longest = max(originalWidth, originalHeight)
        guard let maxDimension, longest > maxDimension else {
            return (NSBitmapImageRep(cgImage: cgImage), originalWidth, originalHeight)
        }

        let scale = Double(maxDimension) / Double(longest)
        let targetWidth = max(1, Int((Double(originalWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(originalHeight) * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return (nil, targetWidth, targetHeight)
        }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor.clear.setFill()
            let targetRect = NSRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(targetHeight))
            targetRect.fill()
            let image = NSImage(cgImage: cgImage, size: targetRect.size)
            image.draw(
                in: targetRect,
                from: targetRect,
                operation: .sourceOver,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        return (bitmap, targetWidth, targetHeight)
    }

    nonisolated func v2EncodeSurfaceImage(_ image: NSImage, encoding: V2SurfaceImageEncoding) -> V2EncodedSurfaceImage? {
        guard let cgImage = v2SourceCGImage(from: image) else { return nil }
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let rasterized = v2RasterizedBitmap(from: cgImage, maxDimension: encoding.maxDimension)
        guard let bitmap = rasterized.bitmap else { return nil }

        let data: Data?
        let jpegQuality: Double?
        switch encoding.format {
        case .png:
            data = bitmap.representation(using: .png, properties: [:])
            jpegQuality = nil
        case .jpeg:
            data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: encoding.jpegQuality])
            jpegQuality = encoding.jpegQuality
        }
        guard let data else { return nil }

        return V2EncodedSurfaceImage(
            data: data,
            format: encoding.format,
            width: rasterized.width,
            height: rasterized.height,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            jpegQuality: jpegQuality,
            maxDimension: encoding.maxDimension,
            profile: encoding.profile
        )
    }

    private nonisolated func v2PixelDimensions(from image: NSImage) -> (width: Int, height: Int) {
        for representation in image.representations where representation.pixelsWide > 0 && representation.pixelsHigh > 0 {
            return (width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return (width: Int(image.size.width), height: Int(image.size.height))
    }

    private nonisolated func v2PNGDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let representation = NSBitmapImageRep(data: data),
              representation.pixelsWide > 0,
              representation.pixelsHigh > 0 else {
            return nil
        }
        return (width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    nonisolated func v2AttachEncodedSurfaceImage(
        _ image: V2EncodedSurfaceImage,
        to result: inout [String: Any],
        includeBase64: Bool
    ) {
        if includeBase64 {
            result[image.format.base64Key] = image.data.base64EncodedString()
        }
        result["format"] = image.format.rawValue
        result["mime_type"] = image.format.mimeType
        result["file_extension"] = image.format.fileExtension
        result["byte_count"] = image.data.count
        result["width"] = image.width
        result["height"] = image.height
        result["original_width"] = image.originalWidth
        result["original_height"] = image.originalHeight
        result["aspect_ratio"] = image.aspectRatio
        result["profile"] = image.profile
        if let maxDimension = image.maxDimension {
            result["max_dimension"] = maxDimension
        }
        if let jpegQuality = image.jpegQuality {
            result["jpeg_quality"] = jpegQuality
        }
        var compression: [String: Any] = [
            "format": image.format.rawValue,
            "lossless": image.format == .png,
            "resized": image.width != image.originalWidth || image.height != image.originalHeight
        ]
        if let jpegQuality = image.jpegQuality {
            compression["jpeg_quality"] = jpegQuality
        }
        if let maxDimension = image.maxDimension {
            compression["max_dimension"] = maxDimension
        }
        result["compression"] = compression
    }
}
