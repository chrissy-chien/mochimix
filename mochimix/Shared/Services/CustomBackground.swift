//
//  CustomBackground.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//

import UIKit

/// A widget background from the user's own photo library. The app saves
/// it into the App Group container (the widget can't reach the photo
/// library itself), downscaled so the widget extension -- which has a
/// tight memory budget -- never has to decode a full-size camera photo.
///
/// It's selected like any manifest background, via its fixed `id` in
/// `WidgetSettings.backgroundID`; `BackgroundManifest.resolve(id:)` and
/// `BackgroundImage` both special-case it.
enum CustomBackground {
    static let id = "custom-photo"

    /// Long edge of the saved image, in pixels -- comfortably sharp for a
    /// systemMedium widget at 3x, without being a full camera photo.
    private static let maxPixelSize: CGFloat = 1200

    static var fileURL: URL {
        SharedStore.shared.containerURL.appendingPathComponent("custom_background.jpg")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func image() -> UIImage? {
        UIImage(contentsOfFile: fileURL.path)
    }

    /// nil when no photo has been uploaded yet.
    static var option: BackgroundOption? {
        guard exists else { return nil }
        return BackgroundOption(id: id, image: id, color: SharedStore.shared.customBackgroundTextColor)
    }

    /// Downscales and saves picked photo data, and picks a readable text
    /// color for it (light text on dark photos, dark text on light ones).
    static func save(_ data: Data) throws {
        guard let source = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let resized = downscaled(source)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try jpeg.write(to: fileURL, options: .atomic)
        SharedStore.shared.customBackgroundTextColor = averageLuminance(of: resized) < 0.55 ? .white : .black
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height) * image.scale
        let factor = min(1, maxPixelSize / longEdge)
        let size = CGSize(width: image.size.width * image.scale * factor,
                          height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 0 (black) ... 1 (white), averaged by drawing the image into a tiny
    /// bitmap and letting the downsample do the averaging.
    private static func averageLuminance(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return total / Double(side * side) / 255
    }
}
