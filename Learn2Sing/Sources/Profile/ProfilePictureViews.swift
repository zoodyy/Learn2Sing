//
//  ProfilePictureViews.swift
//  Learn2Sing
//

import SwiftUI
import UIKit

/// A profile picture in the round frame it is normally shown in, falling back to
/// the same placeholder the Community tab used before there were pictures.
struct ProfileAvatar: View {
    let image: UIImage?
    let side: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
    }
}

/// The whole picture, opened by a tap on the circle: the biggest rendition the
/// profile carries, drawn to fit the screen and pinchable from there.
///
/// Shown over a dimmed backdrop rather than pushed, because it is a look at one
/// thing and not a place — a tap anywhere, a swipe down or the close button all
/// put it away again.
struct ProfilePictureViewer: View {
    /// Re-renders when the language is changed in Settings; the strings are
    /// resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    let image: UIImage

    /// The pinch that is happening now, kept apart from the one that settled so
    /// letting go doesn't snap the picture back to where the gesture started.
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    /// How far the picture has been dragged down, which both moves it and fades
    /// the backdrop — the usual "flick it away" gesture. Only while it is not
    /// zoomed in: a drag then belongs to panning around the picture.
    @State private var dragDown: CGFloat = 0

    private var scale: CGFloat { max(1, zoom * gestureZoom) }
    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(dragDown / 400, 0.6))
                .ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(y: dragDown)
                .gesture(
                    MagnifyGesture()
                        .onChanged { gestureZoom = $0.magnification }
                        .onEnded { _ in
                            zoom = max(1, zoom * gestureZoom)
                            gestureZoom = 1
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard !isZoomed else { return }
                            dragDown = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            guard !isZoomed else { return }
                            if value.translation.height > 120 {
                                dismiss()
                            } else {
                                withAnimation(.snappy) { dragDown = 0 }
                            }
                        }
                )
                // A tap puts it away, but only while it is not zoomed in — a tap
                // to steady a pinch shouldn't close what the user is looking at.
                .onTapGesture { if !isZoomed { dismiss() } }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel(L("Close"))
            .padding(20)
        }
        // Double tap to zoom back out, so a pinched-in picture doesn't strand the
        // drag-to-dismiss gesture.
        .onTapGesture(count: 2) {
            withAnimation(.snappy) {
                zoom = 1
                gestureZoom = 1
            }
        }
    }
}

/// Move-and-scale for the profile picture: the whole picture behind a round
/// window, dragged and pinched until the part that should show is in it.
///
/// It edits an alignment rather than cropping anything — the picture on the
/// server keeps its full frame, and only the round rendition is redrawn from
/// what is set here (see `ProfilePictureCodec.realigned`).
struct ProfilePictureEditor: View {
    /// Re-renders when the language is changed in Settings; the strings are
    /// resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let onSave: (ProfilePictureAlignment) -> Void

    /// What has been settled on so far. The in-flight gesture is held apart from
    /// it and folded in for display, so a pinch and a drag compose instead of
    /// fighting, and letting go of one doesn't undo the other.
    @State private var settled: ProfilePictureAlignment
    @State private var gestureZoom: Double = 1
    @State private var gestureDrag: CGSize = .zero

    init(image: UIImage,
         alignment: ProfilePictureAlignment,
         onSave: @escaping (ProfilePictureAlignment) -> Void) {
        self.image = image
        self.onSave = onSave
        _settled = State(initialValue: alignment)
    }

    private var aspect: Double {
        guard image.size.height > 0 else { return 1 }
        return Double(image.size.width / image.size.height)
    }

    /// The alignment as it stands this frame, gesture included and kept in range.
    private func live(side: Double) -> ProfilePictureAlignment {
        var result = settled
        result.scale *= gestureZoom
        result.offsetX += Double(gestureDrag.width) / side
        result.offsetY += Double(gestureDrag.height) / side
        return result.clamped(aspect: aspect)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // A round window as wide as the screen comfortably allows, and
                // never taller than the space left over for it.
                let side = min(geometry.size.width - 48, geometry.size.height - 120, 340)
                let alignment = live(side: side)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .scaleEffect(alignment.scale)
                        .offset(x: alignment.offsetX * side,
                                y: alignment.offsetY * side)
                        .frame(width: side, height: side)
                        .clipShape(.circle)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { gestureDrag = $0.translation }
                                .onEnded { _ in
                                    settled = live(side: side)
                                    gestureDrag = .zero
                                }
                        )
                        .simultaneousGesture(
                            MagnifyGesture()
                                .onChanged { gestureZoom = $0.magnification }
                                .onEnded { _ in
                                    settled = live(side: side)
                                    gestureZoom = 1
                                }
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Text("Drag and pinch to choose what shows in the circle.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                }
            }
            .background(Color.black)
            .navigationTitle(L("Adjust Picture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        onSave(settled.clamped(aspect: aspect))
                        dismiss()
                    }
                }
            }
        }
    }
}
