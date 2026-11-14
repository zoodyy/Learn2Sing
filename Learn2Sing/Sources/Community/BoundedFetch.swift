//
//  BoundedFetch.swift
//  Learn2Sing
//

import Foundation

/// Downloads that stop once they pass a size, for the answers that carry other
/// people's documents.
///
/// The backend takes a document of up to 4 GB from anybody, so a page of the
/// community can be as big as whoever posted the biggest exercise on it wants it
/// to be — and `URLSession.data(from:)` holds the whole of an answer in memory
/// before anything can look at it. These read the answer as it arrives instead
/// and give up past `maxBytes`, which is far more than anything this app posts
/// could ever add up to.
nonisolated enum BoundedFetch {
    /// A page of the community listing: `CommunityFeed.pageSize` documents, each
    /// of which this app keeps well under a megabyte.
    static let maxPageBytes = 16_000_000
    /// One user's public profile.
    static let maxProfileBytes = 1_000_000

    /// What `data(from:maxBytes:)` came back with.
    enum Result {
        case answered(Data, HTTPURLResponse)
        /// The answer was bigger than allowed, and was dropped unread.
        case tooBig
    }

    /// The body at `url`, read until it ends or passes `maxBytes`. Throws what
    /// `URLSession` throws (offline, timed out, cancelled). Off the main actor:
    /// the answer is read a byte at a time.
    @concurrent
    static func data(from url: URL, maxBytes: Int) async throws -> Result? {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { return nil }
        // A length the server announces up front settles it before a byte is read.
        guard http.expectedContentLength <= Int64(maxBytes) else {
            bytes.task.cancel()
            return .tooBig
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                return .tooBig
            }
        }
        return .answered(data, http)
    }
}
