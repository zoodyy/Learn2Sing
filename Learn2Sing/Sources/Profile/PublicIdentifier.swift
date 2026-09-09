//
//  PublicIdentifier.swift
//  Learn2Sing
//

import Foundation
import CryptoKit

/// Deterministic, one-way public identifiers derived from the private device and
/// exercise ids.
///
/// The community endpoints are unauthenticated and echo back every id they are
/// called with (in query params and each record's `entityId`), so the Keychain
/// device id must never travel over them: it is the secret key to this install's
/// `fetch-private/<id>/PROFILE` backup, and anyone who scraped it from the public
/// feed could pull the whole profile and library. Every value sent to a public
/// endpoint is instead an RFC 4122 v5 (name-based, SHA-1) UUID derived from the
/// private id. The mapping is stable — the same input always yields the same
/// public id, so usernames and exercises still correlate across calls — but not
/// reversible: a private id is a full-entropy UUID, so it can't be recovered
/// from, or brute-forced through, its derived public id. v5 also keeps the
/// bare-UUID shape the backend requires for its ids.
enum PublicIdentifier {
    /// Fixed app namespace for the derivation; any constant UUID works.
    private static let namespace = UUID(uuidString: "6C7E2A9B-4F13-5D8A-B0E6-1A2C3D4E5F60")!

    /// This install's public user id — safe to expose on the Community feed.
    static var user: String { derived(from: DeviceIdentifier.uuidString) }

    /// The public id an exercise is published under, as a string (URL path / query).
    static func exerciseID(_ rawUUIDString: String) -> String { derived(from: rawUUIDString) }

    /// The public id an exercise is published under, as a UUID (the value stored
    /// in the shared document's `id`). Matches `exerciseID(_:)` for the same input.
    static func exercise(_ id: UUID) -> UUID {
        UUID(uuidString: derived(from: id.uuidString)) ?? id
    }

    /// Version-5 UUID of `name` under the app namespace, as a lowercase string.
    private static func derived(from name: String) -> String {
        var input = [UInt8]()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(contentsOf: Array(name.lowercased().utf8))
        var bytes = Array(Insecure.SHA1.hash(data: Data(input)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                               bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }
}
