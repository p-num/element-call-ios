//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import SwiftUI
import UIKit

/// The corner our own floating tile sits in (019 R18, R20). Physical rather than leading and
/// trailing: a right-to-left locale does not mirror it.
public enum ElementCallOwnTileCorner: Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    
    var isTop: Bool {
        self == .topLeft || self == .topRight
    }
    
    var isLeft: Bool {
        self == .topLeft || self == .bottomLeft
    }
}

/// The layout for calls of up to five people (spec 019), as pure arithmetic beside the grid's.
///
/// It produces the same ``ElementCallStageLayout`` the grid does, rather than being a view of its
/// own, so a tile keeps its identity when the call crosses between the two: its video view is
/// never remounted, and the switch is every tile moving to its new place (R31).
///
/// Static and caseless, as `ElementCallSpotlight` is, so every rule is a unit test with no view.
enum ElementCallSmallCallLayout {
    /// Room the chrome takes from the floating tile's corners. Not part of the arrangement: only
    /// the floating tile follows the chrome, on the chrome's own animation (R19).
    struct FloatingInsets: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        
        static let zero = FloatingInsets(top: 0, bottom: 0)
    }
    
    private typealias Metrics = ElementCallStageLayout.Metrics
    
    /// Tiles, ourselves included, up to which this layout applies (R1).
    nonisolated static let maximumTiles = 5
    /// The core's ranking threshold: at or below this many remote tiles it orders them by join time,
    /// heroes first, rather than by what people are doing. Every remote tile of this layout, so the
    /// order it receives is arrival (R7) and nobody moves when someone talks (R13).
    nonisolated static let rankingThreshold = maximumTiles - 1
    
    /// R17, R28. Being tuned on a device (hq 019 ios.md, appendix).
    static let floatingPortraitSize = CGSize(width: 100, height: 150)
    static let floatingLandscapeSize = CGSize(width: 150, height: 100)
    static let floatingAvatarSize = CGSize(width: 100, height: 100)
    static let floatingMargin = Metrics.horizontalMargin
    
    /// Above every tile it floats over, and below a tile going full screen and its scrim, which
    /// replace it like everything else.
    static let floatingZIndex: Double = 2
    
    // MARK: - Selection
    
    /// Whether the stage gets this layout rather than the grid: at most five tiles and no remote
    /// screen share (R1, R8). Counted in tiles rather than members, a share excluded from the count
    /// because its presence alone selects the grid; keyed on the share rather than on being a hero,
    /// because a hero is "a share today, a pin later" and R8 is about shares. Our own share is
    /// never a tile, so it does not switch layouts. No margin and no memory: crossing five and six
    /// switches on every crossing (R33).
    nonisolated static func applies(to tiles: [ElementCallTile]) -> Bool {
        !tiles.contains { $0.isScreenShare && !$0.isLocal }
            && tiles.count { !$0.isScreenShare } <= maximumTiles
    }
    
    /// Whether the arrangement is one picture behind all the chrome: one other person (R4). The
    /// screen extends the stage under the side safe areas for it, which is why it asks here rather
    /// than reading the arrangement, which needs the stage's size first.
    nonisolated static func isFullBleed(_ tiles: [ElementCallTile]) -> Bool {
        applies(to: tiles) && tiles.count { !$0.isLocal && !$0.isScreenShare } == 1
    }
    
    // MARK: - Arrangement
    
    /// Remote tiles in the core's order, which below ``rankingThreshold`` is join order (R7). Our own
    /// tile floats over the stage alone and in a one-to-one call (R2, R3); with three tiles or more
    /// it is inline and first, the same size as the others (R5, R16).
    ///
    /// Everything is on screen, so everything is live and nothing is hidden or released, and the
    /// detail window covers every remote tile (R12).
    static func arrange(_ input: ElementCallStageLayout.Input, viewport: CGRect) -> ElementCallStageLayout {
        let metrics = input.metrics
        let own = input.tiles.first(where: \.isLocal)
        let remote = remote(input.tiles)
        let ranks = Dictionary(uniqueKeysWithValues: input.tiles.filter { !$0.isLocal }.enumerated().map { ($1.id, $0) })
        let isFloating = own != nil && remote.count <= 1
        
        var placements = [ElementCallTilePlacement]()
        func place(_ tile: ElementCallTile, _ frame: CGRect, _ appearance: ElementCallTileAppearance, zIndex: Double = 0, fit: ElementCallTileFit = .standard) {
            placements.append(ElementCallTilePlacement(tile: tile,
                                                       frame: frame,
                                                       appearance: appearance,
                                                       isSpotlight: false,
                                                       visibility: .live,
                                                       orderIndex: ranks[tile.id],
                                                       zIndex: zIndex,
                                                       contentFit: fit))
        }
        
        if remote.isEmpty {
            // R3: only us, floating in our corner, so the tile stays put when someone arrives.
        } else if remote.count == 1 {
            // R4: filled, except a landscape picture on a portrait stage, which is shown whole.
            place(remote[0], fullBleedFrame(metrics), .fullBleed, fit: metrics.isLandscape ? .standard : .fitWhenLandscape)
        } else {
            let inline = (own.map { [$0] } ?? []) + remote
            let frames = metrics.isLandscape
                ? inlineFrames(count: inline.count, metrics: metrics)
                : portraitFrames(count: inline.count, metrics: metrics)
            for (tile, frame) in zip(inline, frames) {
                place(tile, frame, .card)
            }
        }
        
        if isFloating, let own {
            let size = floatingSize(hasVideo: own.hasVideo, videoAspect: input.ownVideoAspect, isLandscape: metrics.isLandscape)
            place(own, floatingFrame(corner: input.ownCorner, size: size, metrics: metrics, insets: input.floatingInsets), .floating, zIndex: floatingZIndex)
        }
        
        // R27: remote tiles by arrival, then ourselves; ourselves first when drawn first.
        let ownID = own.map { [$0.id] } ?? []
        let remoteIDs = remote.map(\.id)
        return ElementCallStageLayout(placements: placements,
                                      contentHeight: viewport.height,
                                      viewport: viewport,
                                      detailWindow: .init(ranks: 0..<ranks.count, also: []),
                                      heroStack: nil,
                                      pictureInPictureTileID: pictureInPictureTile(tiles: input.tiles, speakerID: input.speakerID),
                                      isStatic: true,
                                      readingOrder: isFloating ? remoteIDs + ownID : ownID + remoteIDs)
    }
    
    /// The remote person tiles, in the order given.
    private nonisolated static func remote(_ tiles: [ElementCallTile]) -> [ElementCallTile] {
        tiles.filter { !$0.isLocal && !$0.isScreenShare }
    }
    
    /// The whole screen, behind both bars (R4). In content coordinates, which start under the
    /// portrait top bar, so it reaches above zero by the room the bar and the status bar take. The
    /// sides are the stage's own, which runs under the side safe areas while this is up; the bottom
    /// already includes the home indicator.
    static func fullBleedFrame(_ metrics: ElementCallStageLayout.Metrics) -> CGRect {
        CGRect(x: 0, y: -metrics.topBleed, width: metrics.area.width, height: metrics.area.height + metrics.topBleed)
    }
    
    /// R5, R6, R11: three tiles stacked in rows, four as a 2×2, five as 2+2+1 with the fifth centred.
    /// All 4:3 and from the top of the stage.
    static func portraitFrames(count: Int, metrics: ElementCallStageLayout.Metrics) -> [CGRect] {
        count <= 3 ? rowFrames(count: count, metrics: metrics) : twoColumnFrames(count: count, metrics: metrics)
    }
    
    /// R5: one tile per row, as wide as the stage allows while every row fits above the controls,
    /// and centred when that is narrower than the stage.
    private static func rowFrames(count: Int, metrics: Metrics) -> [CGRect] {
        let rows = CGFloat(count)
        let height = min(metrics.cardsWidth / Metrics.tileAspect, (metrics.cardsBottom - (rows - 1) * Metrics.spacing) / rows)
        let width = height * Metrics.tileAspect
        let leading = metrics.cardsLeading + (metrics.cardsWidth - width) / 2
        return (0..<count).map { CGRect(x: leading, y: CGFloat($0) * (height + Metrics.spacing), width: width, height: height) }
    }
    
    /// R6, R11: two columns from the top, a lone last tile centred under them.
    private static func twoColumnFrames(count: Int, metrics: Metrics) -> [CGRect] {
        let width = (metrics.cardsWidth - Metrics.spacing) / 2
        let height = width / Metrics.tileAspect
        return (0..<count).map { index in
            let isLoneLast = index == count - 1 && count % 2 == 1
            let column = isLoneLast ? 0.5 : CGFloat(index % 2)
            return CGRect(x: metrics.cardsLeading + column * (width + Metrics.spacing),
                          y: CGFloat(index / 2) * (height + Metrics.spacing),
                          width: width,
                          height: height)
        }
    }
    
    /// R16: 4:3, rows of at most four, every tile the same size, each row centred across the stage
    /// and the whole block centred on the screen's height. As wide as the stage allows, shrinking
    /// only when two rows do not fit above the bottom safe area.
    static func inlineFrames(count: Int, metrics: ElementCallStageLayout.Metrics) -> [CGRect] {
        let perRow = min(count, 4)
        let rows = (count + 3) / 4
        let widthThatFitsTheRow = (metrics.cardsWidth - CGFloat(perRow - 1) * Metrics.spacing) / CGFloat(perRow)
        let widthThatFitsTheRows = (metrics.cardsBottom - CGFloat(rows - 1) * Metrics.spacing) / CGFloat(rows) * Metrics.tileAspect
        let width = min(widthThatFitsTheRow, widthThatFitsTheRows)
        let height = width / Metrics.tileAspect
        let blockHeight = CGFloat(rows) * height + CGFloat(rows - 1) * Metrics.spacing
        let top = (metrics.area.height - blockHeight) / 2
        return (0..<count).map { index in
            let row = index / 4
            let inRow = min(count - row * 4, 4)
            let rowWidth = CGFloat(inRow) * width + CGFloat(inRow - 1) * Metrics.spacing
            let leading = metrics.cardsLeading + (metrics.cardsWidth - rowWidth) / 2
            return CGRect(x: leading + CGFloat(index % 4) * (width + Metrics.spacing),
                          y: top + CGFloat(row) * (height + Metrics.spacing),
                          width: width,
                          height: height)
        }
    }
    
    // MARK: - Our own floating tile
    
    /// R10, R17, R28: a square avatar with the camera off, otherwise the shape of the picture.
    /// Before the first frame the stage's own orientation stands in for it, since our capture is
    /// upright in the interface orientation.
    static func floatingSize(hasVideo: Bool, videoAspect: CGFloat?, isLandscape: Bool) -> CGSize {
        guard hasVideo else { return floatingAvatarSize }
        let isLandscapePicture = videoAspect.map { $0 > 1 } ?? isLandscape
        return isLandscapePicture ? floatingLandscapeSize : floatingPortraitSize
    }
    
    /// Where the floating tile's frame may be: inside the cards' margins, and clear of whatever
    /// chrome is showing at the top and the bottom (R19). Its corners are the four snap points, and
    /// a drag cannot take the tile outside it (R21).
    static func floatingBounds(metrics: ElementCallStageLayout.Metrics, insets: FloatingInsets) -> CGRect {
        let top = insets.top + floatingMargin
        let bottom = metrics.safeBottom - insets.bottom - floatingMargin
        return CGRect(x: metrics.cardsLeading, y: top, width: metrics.cardsWidth, height: bottom - top)
    }
    
    static func floatingFrame(corner: ElementCallOwnTileCorner, size: CGSize, metrics: ElementCallStageLayout.Metrics, insets: FloatingInsets) -> CGRect {
        let bounds = floatingBounds(metrics: metrics, insets: insets)
        return CGRect(x: corner.isLeft ? bounds.minX : bounds.maxX - size.width,
                      y: corner.isTop ? bounds.minY : bounds.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }
    
    /// The corner whose quadrant the tile's centre was released in (R21).
    static func nearestCorner(to center: CGPoint, in bounds: CGRect) -> ElementCallOwnTileCorner {
        switch (center.y < bounds.midY, center.x < bounds.midX) {
        case (true, true): .topLeft
        case (true, false): .topRight
        case (false, true): .bottomLeft
        case (false, false): .bottomRight
        }
    }
    
    /// The corner a released tile goes to (R21): the one nearest where it would coast to from the
    /// finger's velocity, so a flick towards a corner reaches it from wherever it was let go. A slow
    /// release projects almost nowhere, and is the corner of the quadrant it was dropped in.
    static func releaseCorner(center: CGPoint, velocity: CGSize, in bounds: CGRect) -> ElementCallOwnTileCorner {
        nearestCorner(to: CGPoint(x: center.x + projectedDistance(velocity.width),
                                  y: center.y + projectedDistance(velocity.height)),
                      in: bounds)
    }
    
    /// How far something moving at `velocity` points per second coasts before it stops, at the
    /// rate a scroll view decelerates. The projection Apple's own fluid interfaces use for a flick.
    static func projectedDistance(_ velocity: CGFloat) -> CGFloat {
        let rate = UIScrollView.DecelerationRate.normal.rawValue
        return velocity / 1000 * rate / (1 - rate)
    }
    
    /// A drag's translation, held so the whole tile stays inside the bounds (R21).
    static func clampedDrag(_ translation: CGSize, from frame: CGRect, in bounds: CGRect) -> CGSize {
        CGSize(width: min(max(translation.width, bounds.minX - frame.minX), bounds.maxX - frame.maxX),
               height: min(max(translation.height, bounds.minY - frame.minY), bounds.maxY - frame.maxY))
    }
    
    // MARK: - Speaker
    
    /// Who counts as speaking for the small layout: the one Picture in Picture continues (R15).
    ///
    /// - Parameters:
    ///   - tiles: the composed tiles, ourselves included; we are never the speaker (R15).
    ///   - held: the previous answer. Kept while it is still speaking, so two people talking over
    ///     each other do not swap on every word, and kept through silence, so the last speaker
    ///     stays rather than the window emptying (R15). Dropped once they leave.
    nonisolated static func speaker(tiles: [ElementCallTile], held: MatrixRTCTileID?) -> MatrixRTCTileID? {
        let remote = remote(tiles)
        if let held, remote.contains(where: { $0.id == held && $0.isSpeaking }) {
            return held
        }
        if let first = remote.first(where: \.isSpeaking) {
            return first.id
        }
        if let held, remote.contains(where: { $0.id == held }) {
            return held
        }
        return nil
    }
    
    /// The tile the Picture in Picture window continues while the small layout is up (R15): the
    /// speaker, else whoever arrived first, else ourselves when we are alone.
    nonisolated static func pictureInPictureTile(tiles: [ElementCallTile], speakerID: MatrixRTCTileID?) -> MatrixRTCTileID? {
        speakerID ?? remote(tiles).first?.id ?? tiles.first(where: \.isLocal)?.id
    }
}
