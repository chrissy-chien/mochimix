//
//  BundledResource.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import UIKit

/// Looks up plain bundled files (the `backgrounds.json` manifest, and the
/// PNGs it references) rather than asset-catalog entries -- this is what
/// lets backgrounds be added just by dropping a PNG + editing JSON,
/// without touching an .xcassets catalog at all.
///
/// Files are expected in the `Backgrounds/` folder (see
/// Shared/Backgrounds/), but this also checks the bundle root as a
/// fallback, since Xcode's synchronized-group resource copying can land
/// loose files at the bundle's top level rather than preserving the
/// on-disk subfolder -- checking both means this keeps working either way.
enum BundledResource {
    private static let subdirectory = "Backgrounds"

    static func url(named name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func data(named name: String, extension ext: String) -> Data? {
        guard let url = url(named: name, extension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// `nil` if the named PNG hasn't been added yet -- callers should show
    /// a graceful placeholder in that case, not treat it as an error.
    static func image(named name: String) -> UIImage? {
        guard let url = url(named: name, extension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
