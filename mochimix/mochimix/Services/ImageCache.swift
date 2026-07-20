//
//  ImageCache.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import CryptoKit
import UIKit

/// Downloads each item's artwork exactly once per unique URL and writes it
/// into the App Group's shared "Artwork" folder as a plain image file, so
/// the widget extension can load it straight from disk instead of making
/// its own network request (widgets should avoid networking).
enum ImageCache {
    /// Downloads (if needed) and returns the local filename for this item's
    /// artwork, or `nil` if there's no artwork URL or the download failed
    /// -- in which case the widget just shows its fallback icon instead of
    /// a broken image.
    static func cacheArtwork(for item: MochiMixItem) async -> String? {
        guard let artworkURL = item.artworkURL else { return nil }

        let name = fileName(for: artworkURL)
        let destination = SharedStore.shared.artworkDirectory.appendingPathComponent(name)

        // Already downloaded -- reuse it instead of re-fetching.
        if FileManager.default.fileExists(atPath: destination.path) {
            return name
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  UIImage(data: data) != nil else {
                return nil
            }
            try data.write(to: destination, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Deletes any cached artwork files that no longer belong to any
    /// currently-displayed item, so the shared container doesn't grow
    /// forever as the recently-played list changes over time.
    static func pruneUnusedArtwork(keeping items: [MochiMixItem]) {
        let keepFileNames = Set(items.compactMap(\.localArtworkFileName))
        let directory = SharedStore.shared.artworkDirectory
        guard let existingFiles = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }

        for file in existingFiles where !keepFileNames.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Derives a stable, filesystem-safe filename from the artwork URL
    /// using a SHA256 hash (not Swift's built-in `hashValue`, which is
    /// randomized per app launch and wouldn't reliably match a
    /// previously-downloaded file). Same URL always maps to the same file.
    private static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return "\(hex).\(ext)"
    }
}
