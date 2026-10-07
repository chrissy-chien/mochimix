//
//  ParentGenre.swift
//  mochimix
//

import SwiftUI

/// Maps a free-form genre tag (e.g. "dubstep", "house", "indie pop") to
/// one of a small, fixed set of "umbrella" genre families, so subgenres
/// sharing a family (dubstep + house -> Electronic) render in the same
/// color everywhere the Stats tab shows genres -- the bar list and the
/// genre breakdown view both key off this, never off the raw tag string.
///
/// `allCases`' declaration order is NOT cosmetic for two reasons:
/// 1. `classify(_:)` checks families in this order, first match wins --
///    `indie` must come before `pop`/`rock` so "indie pop"/"indie rock"
///    land in Indie rather than being swallowed by those broader families.
/// 2. The 8 *colored* families (everything except `other`) use a hue
///    sequence validated (dataviz skill, `scripts/validate_palette.js`)
///    for adjacent-pair CVD safety. `other` deliberately is NOT part of
///    that 8-hue ring -- it's a neutral gray (see `color`), since a
///    catch-all bucket isn't a real "identity" the categorical palette
///    needs to keep distinguishable, and giving it one would have meant
///    a 9th competing hue (the palette's documented ceiling is 8; see
///    `references/anti-patterns.md`'s "Cycling / generating hues past 8").
///    If you reorder the colored cases or swap which one maps to which
///    Assets.xcassets color, re-run the validator on the new sequence
///    before shipping.
enum ParentGenre: CaseIterable, Hashable {
    case electronic
    case hipHop
    case indie
    case pop
    case rnb
    case country
    case rock
    case latin
    case other

    var displayName: String {
        switch self {
        case .electronic: return "Electronic"
        case .hipHop: return "Hip-Hop/Rap"
        case .indie: return "Indie"
        case .pop: return "Pop"
        case .rnb: return "R&B/Soul"
        case .country: return "Country"
        case .rock: return "Rock"
        case .latin: return "Latin"
        case .other: return "Other"
        }
    }

    /// Named Assets.xcassets color (light/dark variants baked in, same
    /// convention as AppTheme.swift) -- edit these color sets directly in
    /// Xcode to retheme without touching code. See the validator note on
    /// this type before reordering cases or swapping which hue goes where.
    /// `other` intentionally reuses the neutral "Muted" gray rather than
    /// a slot from the 8-hue categorical ring -- see that note.
    var color: Color {
        switch self {
        case .electronic: return Color("GenreElectronic")
        case .hipHop: return Color("GenreHipHop")
        case .indie: return Color("GenreIndie")
        case .pop: return Color("GenrePop")
        case .rnb: return Color("GenreRnB")
        case .country: return Color("GenreCountry")
        case .rock: return Color("GenreRock")
        case .latin: return Color("GenreLatin")
        case .other: return Color("GenreOther")
        }
    }

    /// Keyword substrings (checked case-insensitively against a
    /// lowercased genre tag) that indicate this family. Checked in
    /// `allCases` order, first match wins -- a tag matching none of these
    /// falls back to `.other`. Some genre words are genuinely ambiguous
    /// across families (e.g. "trap" is claimed by both hip-hop and EDM,
    /// "garage" by both electronic and rock) -- this picks one side for
    /// each; hand-edit the lists below if your own listening makes the
    /// other reading more useful.
    ///
    /// A few entries are deliberately bare word fragments rather than
    /// full genre names -- "step", "core", "bass" -- because an entire
    /// subgenre *family* is built on that fragment (drumstep/brostep/
    /// deathstep, deathcore/grindcore/mathcore/nintendocore, future
    /// bass/bass house/bassline, etc). Listing each variant by name only
    /// ever covers the ones already known about; the fragment covers
    /// the whole family, including names that don't exist yet. This is
    /// safe specifically because, within real genre tag vocabulary (not
    /// arbitrary text), these fragments are used almost exclusively by
    /// their one family -- "step"/"bass" by bass-music electronic
    /// subgenres, "core" by hardcore/metal-adjacent rock subgenres.
    /// "bass" is the riskiest of the three (electronic is checked
    /// first, so a miss here has no fallback, and instrument words like
    /// "bassoon"/"contrabass" technically contain it too) -- accepted
    /// because none of those show up as genre-classification tags in
    /// practice. If you ever find a tag where one of these fragments
    /// picks the wrong family, move it to a literal keyword instead of
    /// widening the fragment further.
    private var keywords: [String] {
        switch self {
        case .electronic:
            // "drum and bass"/"future bass" are subsumed by bare "bass"
            // below -- kept off this list so there's one place, not two,
            // to look for the actual keyword set.
            return ["electronic", "edm", "house", "techno", "trance", "dubstep",
                     "dnb", "electro", "synth", "idm", "garage",
                     "breakbeat", "jungle", "hardstyle", "downtempo",
                     "synthwave", "vaporwave", "step", "bass", "riddim", "ambient",
                     "trip hop", "glitch", "psytrance"]
        case .hipHop:
            return ["hip hop", "hip-hop", "rap", "trap", "drill", "boom bap", "grime", "phonk"]
        case .indie:
            return ["indie", "lo-fi", "lofi"]
        case .pop:
            return ["pop"]
        case .rnb:
            // jazz lives here by default -- it has no dedicated family
            // (adding a 9th would exceed the categorical color ceiling,
            // same reasoning as `other`'s neutral gray), and it shares
            // more lineage/cross-tagging with soul and R&B than with any
            // other family mochimix tracks. Move it elsewhere by hand if
            // your own listening makes a different bucket feel more right.
            return ["r&b", "rnb", "soul", "funk", "jazz", "gospel", "motown"]
        case .country:
            return ["country", "americana", "bluegrass", "honky tonk"]
        case .rock:
            return ["rock", "metal", "punk", "grunge", "emo", "shoegaze", "screamo",
                     "core", "industrial", "goth"]
        case .latin:
            return ["latin", "reggaeton", "salsa", "bachata", "cumbia", "banda",
                     "merengue", "mambo", "bolero", "bossa nova"]
        case .other:
            return []
        }
    }

    /// Classifies a genre tag by checking each family's keywords, in
    /// `allCases` order, for a case-insensitive substring match. `.other`
    /// is the fallback for anything that matches no family -- never a
    /// thrown error, since an unrecognized tag is a normal, expected
    /// outcome (genre tags are free-form, not a closed vocabulary).
    ///
    /// "alternative" is handled separately, by exact match rather than
    /// substring, before the general loop: "alternative" and "alt" on
    /// their own read as Indie (today's closest usage), but "alternative
    /// rock"/"alternative metal"/"alt-pop" must still resolve through
    /// their other half via the normal keyword checks. A plain substring
    /// match on "alternative" couldn't do both -- Indie is checked
    /// *before* Rock (so "indie rock" lands correctly), which means a
    /// substring match would hijack "alternative rock" into Indie before
    /// Rock's own "rock" keyword ever got a chance to see it.
    static func classify(_ tag: String) -> ParentGenre {
        let lowercased = tag.lowercased()
        if lowercased == "alternative" || lowercased == "alt" {
            return .indie
        }
        for family in ParentGenre.allCases where family != .other {
            if family.keywords.contains(where: { lowercased.contains($0) }) {
                return family
            }
        }
        return .other
    }
}
