//
//  ProfilePicture.swift
//  Learn2Sing
//

import Foundation
import Combine
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import UIKit

/// How the picture sits inside the round frame it is normally shown in.
///
/// Kept as numbers rather than baked into the stored picture alone, so the
/// alignment can be edited again later without the user picking the photo a
/// second time — and so the round rendition can be redrawn from the big one at
/// any point. `scale` is relative to the framing that exactly fills the circle,
/// so 1 is "as large as it has to be and no larger"; the offsets are fractions
/// of the circle's side, positive right and down the way SwiftUI measures them.
nonisolated struct ProfilePictureAlignment: Codable, Equatable {
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let identity = ProfilePictureAlignment()

    /// The largest offset, in circle-sides, that still leaves the picture
    /// covering the circle at this scale — pan any further and an edge would
    /// show through. `aspect` is the source picture's width over its height.
    func limits(aspect: Double) -> (x: Double, y: Double) {
        let width = (aspect >= 1 ? aspect : 1) * scale
        let height = (aspect >= 1 ? 1 : 1 / aspect) * scale
        return (max(0, (width - 1) / 2), max(0, (height - 1) / 2))
    }

    /// This alignment with its scale and offsets brought back into range: never
    /// smaller than filling the circle, never panned far enough to expose a gap.
    func clamped(aspect: Double) -> ProfilePictureAlignment {
        var result = self
        result.scale = min(max(scale, 1), ProfilePictureCodec.maxZoom)
        let limit = result.limits(aspect: aspect)
        result.offsetX = min(max(offsetX, -limit.x), limit.x)
        result.offsetY = min(max(offsetY, -limit.y), limit.y)
        return result
    }
}

/// The profile picture as it travels inside the PUBLIC_PROFILE document: two
/// AVIF renditions, Base64-encoded, because that document is JSON and the
/// backend stores it as text.
///
/// Two of them because the two uses want very different things. `thumb` is the
/// round one the Community tab draws next to a username — small enough that
/// fetching a profile isn't a download, and with the alignment already applied,
/// so drawing it is a clip and nothing more. `full` is the whole picture, up to
/// 1024×1024 and uncropped, which is what a tap on the circle opens.
///
/// AVIF rather than WebP: iOS can *read* WebP but has no encoder for it
/// (`CGImageDestinationCopyTypeIdentifiers()` lists no `org.webmproject.webp`
/// on iOS 26), so writing one would mean bundling libwebp. AVIF is written by
/// ImageIO out of the box and is the smaller of the two formats anyway, which
/// matters here more than usual — see `ProfilePictureCodec` for the budget.
nonisolated struct ProfilePictureDoc: Codable, Equatable {
    /// The whole picture, longest side at most 1024px.
    var full: String
    /// The round rendition, `ProfilePictureCodec.thumbPixels` square, with the
    /// alignment already applied.
    var thumb: String
    /// The alignment `thumb` was drawn with, so the editor can pick up where it
    /// left off — including on a device that has only ever seen this document,
    /// after a reinstall. Optional so a document written before it existed still
    /// decodes.
    var alignment: ProfilePictureAlignment? = nil
}

/// Turns a picked photo into the two renditions that go on the server, and back
/// again. Nothing here touches the main actor: encoding a 1024px AVIF is slow
/// enough to drop frames, so the store below runs it off the main thread.
nonisolated enum ProfilePictureCodec {
    /// The longest side of the big rendition. The most the user asked to keep,
    /// and about as much as the document budget below can afford.
    static let fullMaxPixels = 1024
    /// The side of the round rendition. The circle it is drawn in is 56pt, so
    /// this covers a 3× screen with room to spare — enough that the same
    /// rendition still looks right if the circle ever grows a little.
    static let thumbPixels = 192
    /// How far the alignment editor lets the picture be zoomed in.
    static let maxZoom: Double = 4

    /// ImageIO's identifier for AVIF, exactly as `CGImageDestinationCopyType-
    /// Identifiers()` reports it.
    private static let avif = "public.avif" as CFString

    /// What the two renditions may cost, counted in Base64 characters — the form
    /// they actually take in the document, a third larger than the bytes.
    ///
    /// The backend stores each document in a TEXT column and answers 500 to
    /// anything over roughly 64KB; an oversized POST once took the whole
    /// `fetch-private` endpoint down for every user, so this stays well clear of
    /// the ceiling rather than close to it. 42KB of picture leaves the username,
    /// the description and the join date all the room they could want.
    private static let fullBudget = 34_000
    private static let thumbBudget = 8_000

    /// Qualities to try, in order, until one fits the budget. AVIF holds up
    /// remarkably well at the bottom of this range — a 1024px photo lands around
    /// 8KB at 0.45 — so reaching the end of it means a picture with a lot of
    /// fine detail, and the caller falls back to fewer pixels instead.
    private static let qualities: [Double] = [0.8, 0.65, 0.5, 0.4, 0.3, 0.22]

    /// The pixel sizes to fall back through when even the lowest quality at the
    /// size before it won't fit.
    private static let fullSizes = [1024, 896, 768, 640, 512]

    /// Decodes picked photo data and scales it down so its longest side is at
    /// most `maxPixels`, applying whatever orientation the file was tagged with
    /// — a photo shot in portrait is stored landscape with an EXIF flag, and
    /// baking that in here is what keeps it upright everywhere afterwards.
    static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// Draws `source` into a square of `side` pixels the way the circle shows it:
    /// scaled to fill, then moved by the alignment. The alignment is clamped
    /// first, so a stored one from a picture of a different shape can't leave a
    /// gap at an edge.
    static func square(_ source: CGImage,
                       side: Int,
                       alignment: ProfilePictureAlignment) -> CGImage? {
        let aspect = Double(source.width) / Double(source.height)
        let aligned = alignment.clamped(aspect: aspect)
        let size = Double(side)
        let fill = max(size / Double(source.width), size / Double(source.height)) * aligned.scale
        let width = Double(source.width) * fill
        let height = Double(source.height) * fill
        guard let context = CGContext(data: nil,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        // Core Graphics counts y upwards and SwiftUI counts it down, so the
        // vertical offset — which the editor produced in SwiftUI's terms — is
        // subtracted rather than added.
        let x = (size - width) / 2 + aligned.offsetX * size
        let y = (size - height) / 2 - aligned.offsetY * size
        context.draw(source, in: CGRect(x: x, y: y, width: width, height: height))
        return context.makeImage()
    }

    /// AVIF data for `image` at one quality, or nil if ImageIO declines.
    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, avif, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The length the Base64 of `count` bytes comes to.
    private static func base64Length(_ count: Int) -> Int { (count + 2) / 3 * 4 }

    /// Encodes at the best quality whose Base64 fits `budget`, or nil when even
    /// the lowest one is too big.
    ///
    /// The order the qualities are tried in is picked to keep the number of
    /// encodes down, because an AVIF encode of a big picture is not cheap. The
    /// best quality goes first, since nearly every photo fits at it and then it
    /// is the only encode that happens at all. When it doesn't fit, the *lowest*
    /// goes next: that one answers "can this size fit at any quality", and a no
    /// costs two encodes instead of six before the caller drops to fewer pixels.
    private static func encode(_ image: CGImage, withinBudget budget: Int) -> Data? {
        func fitting(_ quality: Double) -> Data? {
            guard let data = encode(image, quality: quality),
                  base64Length(data.count) <= budget
            else { return nil }
            return data
        }
        if let best = fitting(qualities[0]) { return best }
        guard let floor = fitting(qualities[qualities.count - 1]) else { return nil }
        for quality in qualities.dropFirst().dropLast() {
            if let data = fitting(quality) { return data }
        }
        return floor
    }

    /// Redraws `image` so its longest side is `maxPixels`. Used to step the big
    /// rendition down a size, which is much cheaper than decoding the original
    /// again — a photo straight off a modern camera is tens of megabytes, and
    /// decoding one five times is most of the wait.
    private static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let factor = Double(maxPixels) / Double(max(image.width, image.height))
        guard factor < 1 else { return image }
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Both renditions for a picked photo, or nil if it can't be read or won't
    /// fit however hard it is squeezed.
    ///
    /// The big one is tried at 1024px first and then at fewer and fewer pixels:
    /// a picture with enough detail to blow the budget at every quality is
    /// better served by being a little smaller and sharp than by 1024px of
    /// mush.
    static func renditions(from data: Data,
                           alignment: ProfilePictureAlignment) -> ProfilePictureDoc? {
        // Decoded once, at the largest size, and stepped down from there.
        guard let original = decode(data, maxPixels: fullMaxPixels) else { return nil }
        var full: Data?
        for pixels in fullSizes {
            guard let image = scaled(original, maxPixels: pixels) else { continue }
            if let encoded = encode(image, withinBudget: fullBudget) {
                full = encoded
                break
            }
        }
        guard let full,
              let source = decode(full, maxPixels: fullMaxPixels),
              let square = square(source, side: thumbPixels, alignment: alignment),
              let thumb = encode(square, withinBudget: thumbBudget)
        else { return nil }
        let aspect = Double(source.width) / Double(source.height)
        return ProfilePictureDoc(full: full.base64EncodedString(),
                                 thumb: thumb.base64EncodedString(),
                                 alignment: alignment.clamped(aspect: aspect))
    }

    /// A new round rendition for an alignment the user has just changed, drawn
    /// from the big rendition already stored — so re-aligning never asks for the
    /// original photo again, and never re-encodes the big one.
    static func realigned(_ document: ProfilePictureDoc,
                          to alignment: ProfilePictureAlignment) -> ProfilePictureDoc? {
        guard let data = Data(base64Encoded: document.full),
              let source = decode(data, maxPixels: fullMaxPixels),
              let square = square(source, side: thumbPixels, alignment: alignment),
              let thumb = encode(square, withinBudget: thumbBudget)
        else { return nil }
        let aspect = Double(source.width) / Double(source.height)
        var result = document
        result.thumb = thumb.base64EncodedString()
        result.alignment = alignment.clamped(aspect: aspect)
        return result
    }
}

/// This device's own profile picture: the renditions on disk, the decoded images
/// the screens draw, and the one place that changes either.
///
/// The picture deliberately does **not** live in `UserProfile`. That file is
/// what `ProfileSync` uploads as the private backup, whole, every time the
/// library or the settings change — a picture in there would be re-sent with
/// each of those edits. It lives in its own file beside it instead, and reaches
/// the server only as part of the public profile document (see `CommunitySync`).
@MainActor
final class ProfilePictureStore: ObservableObject {
    static let shared = ProfilePictureStore()

    /// The renditions as they stand, or nil when this user has no picture.
    @Published private(set) var document: ProfilePictureDoc?
    /// The round rendition, decoded — what the circles draw.
    @Published private(set) var thumb: UIImage?
    /// The whole picture, decoded on demand: only the expanded view wants it, and
    /// it is several times the size of the round one.
    @Published private(set) var full: UIImage?

    /// How the picture is currently framed in the circle.
    var alignment: ProfilePictureAlignment {
        document?.alignment ?? .identity
    }

    /// Whether this device knows what its own picture is — false on a fresh
    /// install until `restoreIfNeeded()` has had an answer. The public profile
    /// document is not published while this is false, so a reinstall can't
    /// overwrite the picture on the server before it has fetched it.
    private(set) var isResolved = false

    /// Set once the server has answered about this install's picture, so the
    /// many users who never set one don't pay for a fetch on every launch. A
    /// call that went unanswered doesn't set it — "we couldn't ask" must not be
    /// remembered as "there is nothing there".
    private static let restoreCheckedKey = "profilePictureRestoreChecked"

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profilePicture.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode(ProfilePictureDoc.self, from: data) {
            document = stored
            thumb = Self.image(fromBase64: stored.thumb)
            // A picture on disk is this device's own, and newer than anything the
            // server could hand back.
            isResolved = true
        } else {
            // Nothing on disk: either this user has no picture, or this install
            // has never asked. Only the second is worth a fetch.
            isResolved = UserDefaults.standard.bool(forKey: Self.restoreCheckedKey)
        }
    }

    /// Decodes the whole picture, once, for the expanded view.
    func loadFull() {
        guard full == nil, let document else { return }
        full = Self.image(fromBase64: document.full)
    }

    /// Replaces the picture with a freshly picked photo. Encoding happens off the
    /// main thread — a 1024px AVIF takes long enough to be seen as a stutter.
    /// Returns whether the photo could be used.
    func setPicture(from data: Data) async -> Bool {
        let alignment = ProfilePictureAlignment.identity
        let encoded = await Task.detached(priority: .userInitiated) {
            ProfilePictureCodec.renditions(from: data, alignment: alignment)
        }.value
        guard let encoded else { return false }
        apply(encoded)
        return true
    }

    /// Redraws the round rendition for an alignment the user has just settled on.
    func setAlignment(_ alignment: ProfilePictureAlignment) async {
        guard let document else { return }
        guard alignment != (document.alignment ?? .identity) else { return }
        let encoded = await Task.detached(priority: .userInitiated) {
            ProfilePictureCodec.realigned(document, to: alignment)
        }.value
        guard let encoded else { return }
        apply(encoded)
    }

    /// Drops the picture, here and — once the upload lands — on the server.
    func removePicture() {
        document = nil
        thumb = nil
        full = nil
        isResolved = true
        try? FileManager.default.removeItem(at: Self.fileURL)
        CommunitySync.shared.scheduleUpload()
    }

    /// Takes the picture off this user's own published profile when there is
    /// nothing on disk — the case after a reinstall, where the picture is the one
    /// thing the private backup doesn't carry. Awaited before the first upload of
    /// a session (see `CommunitySync.start()`), so an empty install never
    /// publishes its emptiness over a picture that is still on the server.
    func restoreIfNeeded() async {
        guard !isResolved else { return }
        // A fetch that went unanswered leaves this unresolved on purpose: the
        // next launch asks again, and until one of them answers nothing is
        // published over whatever the server holds.
        guard case .answered(let profile) =
                await CommunitySync.shared.fetchPublicProfile(for: PublicIdentifier.user)
        else { return }
        // Another edit resolved it while the fetch was out; that one is newer.
        guard !isResolved else { return }
        isResolved = true
        UserDefaults.standard.set(true, forKey: Self.restoreCheckedKey)
        guard let picture = profile?.picture else { return }
        document = picture
        thumb = Self.image(fromBase64: picture.thumb)
        write(picture)
    }

    /// Stores new renditions, redraws the screens showing them, and publishes.
    private func apply(_ document: ProfilePictureDoc) {
        self.document = document
        thumb = Self.image(fromBase64: document.thumb)
        // The expanded view decodes the new one the next time it opens.
        full = nil
        isResolved = true
        write(document)
        // The picture is part of the public profile document, so publishing it
        // is the ordinary upload — debounced with everything else, retried on
        // the next launch if it doesn't land.
        CommunitySync.shared.scheduleUpload()
    }

    private func write(_ document: ProfilePictureDoc) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(document).write(to: Self.fileURL, options: .atomic)
    }

    private static func image(fromBase64 text: String) -> UIImage? {
        Data(base64Encoded: text).flatMap(UIImage.init(data:))
    }
}
