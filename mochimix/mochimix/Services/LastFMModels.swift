//
//  LastFMModels.swift
//  mochimix
//

import Foundation

/// A single genre/style tag Last.fm's community has voted on for an
/// artist, via artist.gettoptags. Not Spotify data -- see
/// LastFMAPIClient/GenreStatsStore for why this exists.
struct LastFMTag: Decodable {
    let name: String
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case name, count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // Last.fm's JSON is converted from XML and inconsistently emits
        // numeric fields as either a JSON number or a numeric string
        // (e.g. "count": "100" instead of 100) -- decode leniently
        // rather than letting the whole tag list fail to parse.
        if let intValue = try? container.decode(Int.self, forKey: .count) {
            count = intValue
        } else {
            let stringValue = try container.decode(String.self, forKey: .count)
            count = Int(stringValue) ?? 0
        }
    }
}

private struct LastFMTopTagsBody: Decodable {
    let tag: [LastFMTag]

    private enum CodingKeys: String, CodingKey {
        case tag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Last.fm's XML->JSON conversion collapses a single-item list
        // into a bare object instead of a one-element array -- handle
        // both shapes rather than letting a sparsely-tagged artist fail
        // to decode entirely.
        if let tags = try? container.decode([LastFMTag].self, forKey: .tag) {
            tag = tags
        } else if let single = try? container.decode(LastFMTag.self, forKey: .tag) {
            tag = [single]
        } else {
            tag = []
        }
    }
}

/// GET artist.gettoptags response. `toptags` is absent entirely (rather
/// than present-but-empty) when Last.fm doesn't recognize the artist name
/// at all -- LastFMAPIClient treats that the same as "no tags" rather
/// than throwing, since an unrecognized artist is a normal, frequent
/// outcome here, not a failure worth surfacing.
struct LastFMTopTagsResponse: Decodable {
    fileprivate let toptags: LastFMTopTagsBody?

    var tags: [LastFMTag] { toptags?.tag ?? [] }
}
