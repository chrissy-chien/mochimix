//
//  BackgroundOption.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// The text/play-button color to use *on top of* a given background image
/// -- e.g. a dark background would use `.white` here so its text stays
/// readable. This is deliberately not "the background's own tone" -- it's
/// the color someone picks by hand for each background when writing the
/// manifest entry, based on how that specific image actually looks.
enum BackgroundTextColor: String, Codable {
    case white
    case black
}

/// One entry from `Backgrounds/backgrounds.json`. Adding a new background
/// is just: drop a PNG into `Shared/Backgrounds/`, add an entry here
/// naming it, done -- no Swift code changes needed.
struct BackgroundOption: Codable, Identifiable, Equatable {
    let id: String
    /// The PNG's filename (without extension) in `Shared/Backgrounds/`.
    let image: String
    let color: BackgroundTextColor

    /// A human-readable label derived from `id` (e.g. "bg_5" -> "Bg 5").
    /// Shown under each preview swatch in Settings -- without this, every
    /// swatch would look visually identical while no real PNGs are
    /// bundled yet, making it impossible to tell the row is actually
    /// scrolling.
    var displayName: String {
        id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, image, color, textColor
    }

    init(id: String, image: String, color: BackgroundTextColor) {
        self.id = id
        self.image = image
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        // "image" is optional -- defaults to the id itself, so a minimal
        // entry like {"id": "bg_1", "color": "white"} still works.
        self.image = try container.decodeIfPresent(String.self, forKey: .image) ?? id
        // Accept "color" (documented key) or "textColor" (an alias some
        // entries might use) -- either way we end up with one color.
        if let color = try container.decodeIfPresent(BackgroundTextColor.self, forKey: .color) {
            self.color = color
        } else if let textColor = try container.decodeIfPresent(BackgroundTextColor.self, forKey: .textColor) {
            self.color = textColor
        } else {
            self.color = .white
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(image, forKey: .image)
        try container.encode(color, forKey: .color)
    }
}

/// Loads and resolves background options from the bundled JSON manifest.
enum BackgroundManifest {
    /// Used if `backgrounds.json` is missing, unreadable, or empty, so the
    /// app/widget always has *something* to show instead of crashing or
    /// leaving Settings with zero options.
    static let fallback: [BackgroundOption] = [
        BackgroundOption(id: "bg_1", image: "background_1", color: .white),
        BackgroundOption(id: "bg_2", image: "background_2", color: .black),
    ]

    /// Loaded once per process (the manifest is static bundled data, so
    /// there's nothing to gain from re-reading the file every time this is
    /// used).
    static let all: [BackgroundOption] = load()

    /// Looks up an option by id, falling back to the first available
    /// option if the id is unrecognized (e.g. it was chosen before a
    /// manifest edit removed it).
    static func resolve(id: String) -> BackgroundOption {
        all.first(where: { $0.id == id }) ?? all.first ?? fallback[0]
    }

    private static func load() -> [BackgroundOption] {
        guard let data = BundledResource.data(named: "backgrounds", extension: "json"),
              let decoded = try? JSONDecoder().decode([BackgroundOption].self, from: data),
              !decoded.isEmpty else {
            return fallback
        }
        return decoded
    }
}
