//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import SwiftUI

/// Where one tile sits on the stage and how it draws itself there.
struct ElementCallTilePlacement: Identifiable, Equatable {
    let tile: ElementCallTile
    /// In **content** coordinates: origin at the top leading corner of the scrolling content, the
    /// bottom safe area included. The stage scrolls the content; the spotlight counter-scrolls.
    var frame: CGRect
    var appearance: ElementCallTileAppearance
    var isSpotlight: Bool
    /// How much of this tile's video is worth asking for. Never ``ElementCallTileVisibility/released``
    /// here: a tile that far away is not composed at all, and is in ``ElementCallStageLayout/hiddenTileIDs``.
    var visibility: ElementCallTileVisibility
    /// This tile's index in the model's order, for the detail window; nil for our own tile, which
    /// is not in the order.
    var orderIndex: Int?
    var zIndex: Double
    /// How the picture sits in the frame. Last and defaulted so the grid's placements need not say.
    var contentFit: ElementCallTileFit = .standard
    
    var id: MatrixRTCTileID {
        tile.id
    }
}

/// How a placement asks its picture to sit in the frame.
///
/// A rule rather than a value because the layout cannot see a remote stream's shape, for the reason
/// the full-screen arrangement gives: the tile resolves it against the aspect its renderer reports.
enum ElementCallTileFit: Equatable {
    /// The tile's own rule: a camera fills, a share fits, the spotlight sits between the two.
    case standard
    /// Shown whole when the picture is landscape and the frame is not, filled otherwise: the one
    /// exception R4 makes to filling the screen.
    case fitWhenLandscape
}

/// How much of a tile's video is still worth asking the SFU for.
///
/// Three states rather than two because the core draws the same distinction: a tile a scroll away
/// is paused so its picture comes straight back, while a tile further away is released, which is
/// the only one that stops a two-hundred-person call from holding two hundred subscriptions.
enum ElementCallTileVisibility: Equatable {
    /// On screen, drawing: subscribed at the size it draws.
    case live
    /// Within one viewport of the screen: subscribed but not sent, so it resumes at once and its
    /// last picture is still there when it scrolls in (003 R49, R56).
    case paused
    /// Further than that: unsubscribed as fully as the transport allows (R48).
    case released
    
    /// By distance from the viewport, in content coordinates, with one asymmetry: a tile that is
    /// live stays live until it is more than half a viewport past the edge. Without that a tile
    /// bouncing at the edge of the screen would stop and restart its stream on every bounce; the
    /// call's own linger only guards the release step, not the pause (R58).
    static func forFrame(_ frame: CGRect, viewport: CGRect, wasLive: Bool) -> ElementCallTileVisibility {
        let distance = max(viewport.minY - frame.maxY, frame.minY - viewport.maxY, 0)
        if frame.intersects(viewport) || distance == 0 {
            return .live
        }
        if wasLive, distance <= viewport.height / 2 {
            return .live
        }
        return distance <= viewport.height ? .paused : .released
    }
}

/// The arrangement of every tile for one state of the call, computed as rects so that a tile keeps
/// its view identity however the call changes around it: a tile promoted into the spotlight, a
/// third person turning two rows into a grid, a rotation, all become the same tiles moving and
/// resizing, which is what makes the screen feel native rather than a sequence of fades.
///
/// Spec 003: a 4:3 grid that scrolls vertically, and a 16:9 spotlight that stays put above it for a
/// hero or, in a large call, the speaker. Only what is near the screen is composed at all, so a call
/// of two hundred costs the phone what is on its screen rather than what is in the room. Calls of up
/// to five with no remote share are spec 019's instead (`ElementCallSmallCallLayout`), producing
/// this same value so a tile crossing between the two is a move rather than a remount.
struct ElementCallStageLayout: Equatable {
    /// What the stage has to work with. Distances in points.
    struct Metrics: Equatable {
        /// The whole stage, bottom safe area included. Also the viewport: what one screen shows.
        var area: CGSize
        /// The bottom safe area, which only a full-bleed picture may run under.
        var bottomInset: CGFloat
        /// The side safe areas, for a stage that extends under them. The shipping stage does not:
        /// it sits inside them, so it passes zero, and passing what the reader reports put a second
        /// housing's width of nothing on each side in landscape.
        var leadingInset: CGFloat = 0
        var trailingInset: CGFloat = 0
        /// How far the floating controls reach up from the safe area. Along the bottom in both
        /// orientations: in landscape the bar floats over the spotlight, which runs under it,
        /// and only the grid's content end keeps clear of it.
        var controlsClearance: CGFloat
        /// How far above the content's zero the screen's top edge is: the portrait top bar's room
        /// and the top safe area. Only a picture that runs behind the top bar reaches up into it
        /// (019 R4).
        var topBleed: CGFloat = 0
        
        static let horizontalMargin: CGFloat = 16
        static let spacing: CGFloat = 12
        /// A grid tile is 4 wide by 3 high, in every orientation and at every call size (R10):
        /// filling crops a portrait and a landscape camera by an acceptable amount (R11).
        static let tileAspect: CGFloat = 4.0 / 3.0
        /// The spotlight in portrait: the width of the stage and exactly 16:9 of it, whatever the
        /// stage height (R13); a screen share at the default presentation ratio fits it exactly.
        static let spotlightAspect: CGFloat = 16.0 / 9.0
        static let columns = 2
        /// Landscape without a spotlight: four across, width-driven like portrait's two, as the
        /// design draws it. R32's height-driven row gives three on a phone; the frame has four.
        static let landscapeColumns = 4
        /// Room under the portrait spotlight for the hero stack's dots, between it and the grid.
        static let heroDotsClearance: CGFloat = 20
        /// The landscape tile column's share of the width, and the bounds it is held within: a
        /// share alone gives a useless 90 pt column on a small phone and a 300 pt one on an iPad.
        static let landscapeColumnFraction: CGFloat = 0.22
        static let landscapeColumnRange: ClosedRange<CGFloat> = 140...220
        /// The fewest whole tiles the landscape column shows (R31). A share of the width alone put a
        /// 179 pt column on a 375 pt phone whose cells missed a second row by 8 pt.
        static let landscapeColumnMinimumRows = 2
        
        /// Landscape is a stage wider than it is tall, and that is the whole of what the layout
        /// needs to know (R33). Not the device, not the size class: a half-screen iPad app in
        /// portrait wants the portrait arrangement whatever the hardware is doing.
        var isLandscape: Bool {
            area.width > area.height
        }
        
        /// Where the bottom safe area starts.
        var safeBottom: CGFloat {
            area.height - bottomInset
        }
        
        /// The lowest point a card may reach on one screen. In portrait the controls float above
        /// the safe area and cards stop short of them; in landscape the spotlight takes the full
        /// height and the bar floats over it, so a card may reach the safe area itself.
        var cardsBottom: CGFloat {
            isLandscape ? safeBottom - Self.spacing : safeBottom - controlsClearance - Self.spacing
        }
        
        var cardsLeading: CGFloat {
            leadingInset + Self.horizontalMargin
        }
        
        /// Inside the safe area. Landscape used to keep a controls rail here; the bar is along
        /// the bottom now in both orientations.
        var cardsTrailing: CGFloat {
            area.width - trailingInset - Self.horizontalMargin
        }
        
        var cardsWidth: CGFloat {
            cardsTrailing - cardsLeading
        }
        
        /// The whole area a card may use on one screen, both orientations.
        var cardsFrame: CGRect {
            CGRect(x: cardsLeading, y: 0, width: cardsWidth, height: cardsBottom)
        }
        
        /// What the grid's last row has to clear once scrolled to the end: the controls, the safe
        /// area and a gap (R44). The same in both orientations, since the bar is along the bottom
        /// in both; in landscape that is more than `cardsBottom` leaves, because the spotlight may
        /// run under the bar and the grid's end may not.
        var bottomClearance: CGFloat {
            bottomInset + controlsClearance + Self.spacing
        }
    }
    
    /// Everything the arrangement depends on, so a test states one value and the stage passes one.
    struct Input: Equatable {
        /// Ourselves first, then the model's order untouched (R1).
        var tiles: [ElementCallTile]
        /// Chosen by the screen (`ElementCallSpotlight`); nil when every tile is the same size.
        var spotlightID: MatrixRTCTileID?
        var fullscreenID: MatrixRTCTileID?
        /// How far the content has scrolled, in points. The spotlight is placed relative to it.
        var scrollOffset: CGFloat = 0
        /// Tiles that were live on the previous pass, for the edge hysteresis.
        var liveTileIDs: Set<MatrixRTCTileID> = []
        var metrics: Metrics
        // What only the small-call layout reads (019). Last and defaulted, so a grid test states
        // none of them.
        /// `ElementCallSmallCallLayout.speaker(...)`'s choice, held through silence.
        var speakerID: MatrixRTCTileID?
        var ownCorner: ElementCallOwnTileCorner = .bottomRight
        /// Our own picture's upright width over height, once one has been drawn.
        var ownVideoAspect: CGFloat?
        var floatingInsets = ElementCallSmallCallLayout.FloatingInsets.zero
    }
    
    /// What the layout asks the core for full records of: a rank range over the remote order for
    /// the grid, plus the tiles drawn out of rank (R52, R53). Ranks rather than pages, and carried
    /// by each tile through the arrangement, so nothing translates "row N" into a rank.
    typealias DetailWindow = MatrixRTCDetailWindow
    
    /// Several heroes, one shown (R19).
    struct HeroStack: Equatable {
        var count: Int
        var shown: Int
    }
    
    /// Clear of every z position the arrangements hand out: the spotlight's 1, which is above the
    /// grid because the grid scrolls underneath it. Named so the relationship is something a test
    /// can assert rather than something the next person has to notice.
    static let fullscreenZIndex: Double = 3
    /// The scrim behind a tile going full screen: over everything it replaces, the spotlight's
    /// controls included, and under the tile itself.
    static let fullscreenScrimZIndex = 2.5
    static let spotlightZIndex: Double = 1
    
    var placements: [ElementCallTilePlacement]
    /// How tall the scrolling content is; at least one viewport.
    var contentHeight: CGFloat
    /// The screen, in content coordinates, for the offset the arrangement was computed at.
    var viewport: CGRect
    var detailWindow: DetailWindow = .none
    var heroStack: HeroStack?
    /// Which tile hosts the Picture in Picture source view: the picture the window continues. A
    /// tile rather than a member, because when somebody shares it is their *screen* the window
    /// continues, and their camera is a different picture elsewhere on the same stage.
    var pictureInPictureTileID: MatrixRTCTileID?
    /// Tiles the arrangement leaves out altogether: everything but the one tile filling the
    /// screen, the heroes not currently shown, and the grid rows more than a viewport away. The
    /// stage releases them: it derives the released set from the placements, and a single placement
    /// would otherwise compute the empty set and un-release the whole call at the very moment
    /// nobody is looking at it. **Declared last** because the memberwise initialiser follows
    /// declaration order and the arrangements below call it with trailing labels.
    var hiddenTileIDs: Set<MatrixRTCTileID> = []
    /// Nothing scrolls: the content is exactly one viewport, and the stage disables its scroller so
    /// it does not even bounce, which would compete with dragging our own tile (019 R30).
    var isStatic = false
    /// The order a screen reader walks the tiles in, when it is not the order they are drawn in
    /// (019 R27). Empty means the stage's own order.
    var readingOrder: [MatrixRTCTileID] = []
    
    /// The furthest the content can scroll. What a shrinking grid settles to (R42).
    var maxScrollOffset: CGFloat {
        max(0, contentHeight - viewport.height)
    }
    
    static func compute(_ input: Input) -> ElementCallStageLayout {
        let metrics = input.metrics
        let viewport = CGRect(x: 0, y: input.scrollOffset, width: metrics.area.width, height: metrics.area.height)
        guard !input.tiles.isEmpty else {
            return ElementCallStageLayout(placements: [], contentHeight: viewport.height, viewport: viewport)
        }
        // The ordinary arrangement is computed even when one tile fills the screen, for its
        // content height: a scroller whose content shrank to one screen would clamp the offset to
        // zero, and leaving fullscreen would land at the top instead of where you were (R63).
        var layout = ElementCallSmallCallLayout.applies(to: input.tiles)
            ? ElementCallSmallCallLayout.arrange(input, viewport: viewport)
            : arrange(input, viewport: viewport)
        // A tile that has gone is no longer in `tiles` — its member left, or their share stopped —
        // and the arrangement falls back on its own rather than showing an empty screen. The screen
        // clears the stale id when it notices.
        if let fullscreenID = input.fullscreenID, let tile = input.tiles.first(where: { $0.id == fullscreenID }) {
            layout = fullscreen(tile: tile, others: input.tiles.filter { $0.id != fullscreenID }, over: layout)
        }
        return layout
    }
    
    // MARK: - Full screen
    
    /// One tile and nothing else, edge to edge on the screen as scrolled. The others keep their
    /// place in the call but not on the stage, so they are named as hidden rather than simply
    /// dropped.
    ///
    /// The picture fits rather than fills at this size (see ``VideoPresentation``), so the frame is
    /// the whole area whatever shape the picture turns out to be: the letterbox is the renderer's
    /// business, and giving the tile an aspect-shaped frame here would make the layout depend on a
    /// stream it cannot see.
    ///
    /// Above everything, hence ``fullscreenZIndex``: the tiles it replaces are *leaving*, and a
    /// leaving view keeps its z position for as long as its transition runs. At the grid's own
    /// zero, a tile growing out of the grid had the spotlight's 1 fading out on top of it all the
    /// way up, which is the one moment in the whole move when something is covering the thing you
    /// just asked to see.
    private static func fullscreen(tile: ElementCallTile, others: [ElementCallTile], over layout: ElementCallStageLayout) -> ElementCallStageLayout {
        ElementCallStageLayout(placements: [ElementCallTilePlacement(tile: tile,
                                                                     frame: layout.viewport,
                                                                     appearance: .fullscreen,
                                                                     isSpotlight: false,
                                                                     visibility: .live,
                                                                     orderIndex: layout.placements.first { $0.id == tile.id }?.orderIndex,
                                                                     zIndex: fullscreenZIndex)],
                               contentHeight: layout.contentHeight,
                               viewport: layout.viewport,
                               // Nothing but the one tile is drawn, so nothing but the one tile is
                               // asked for (R53): a window of zero ranks and one identity is valid.
                               detailWindow: DetailWindow(ranks: 0..<0, also: [tile.id]),
                               heroStack: nil,
                               pictureInPictureTileID: tile.id,
                               hiddenTileIDs: Set(others.map(\.id)))
    }
    
    // MARK: - The arrangement
    
    private static func arrange(_ input: Input, viewport: CGRect) -> ElementCallStageLayout {
        let heroes = ElementCallSpotlight.heroes(in: input.tiles)
        let spotlit = input.tiles.firstIndex { $0.id == input.spotlightID && !$0.isLocal }.map { (rank: $0 - 1, tile: input.tiles[$0]) }
        let spotlight = spotlit?.tile
        
        // A hero is only ever drawn in the spotlight (R17); one not shown is neither drawn nor sent
        // video (R24). The spotlight itself comes out of the grid, own tile first as given (R1).
        let unshownHeroes = Set(heroes).subtracting([spotlight?.id].compactMap { $0 })
        // Each with its rank, so nothing searches the order for it per tile on every scroll frame.
        let grid = input.tiles.indices
            .filter { input.tiles[$0].id != spotlight?.id && !unshownHeroes.contains(input.tiles[$0].id) }
            .map { (rank: $0 - 1, tile: input.tiles[$0]) }
        
        var heroStack: HeroStack?
        if let spotlight, heroes.count > 1, let shown = heroes.firstIndex(of: spotlight.id) {
            heroStack = HeroStack(count: heroes.count, shown: shown)
        }
        // No small-call case here: a stage of five tiles or fewer without a spotlight never gets
        // this far (019 supersedes 003 R34–R36).
        var layout = ranked(grid, spotlight: spotlit, heroStack: heroStack, input: input, viewport: viewport)
        layout.hiddenTileIDs.formUnion(unshownHeroes)
        layout.heroStack = heroStack
        return layout
    }
    
    /// The spotlight slot, if there is a spotlight, and the grid: two columns in portrait, a
    /// one-tile column beside the spotlight in landscape, a grid of two full rows in landscape
    /// without one. Rows start at the top of the grid area and a partial last row is left-aligned
    /// (R29): centring either would move every neighbour each time someone joins. Every grid tile
    /// is the same size (R12).
    ///
    /// Only the rows within a viewport of the screen are composed; the rest are hidden and so
    /// released (R47, R48). Each composed remote tile carries its rank, and the detail window is the
    /// range over them plus the spotlight (R52, R53).
    private static func ranked(_ grid: [(rank: Int, tile: ElementCallTile)], spotlight: (rank: Int, tile: ElementCallTile)?, heroStack: HeroStack?, input: Input, viewport: CGRect) -> ElementCallStageLayout {
        let metrics = input.metrics
        var placements = [ElementCallTilePlacement]()
        var hidden = Set<MatrixRTCTileID>()
        var also = Set<MatrixRTCTileID>()
        
        let spotlightFrame: CGRect?
        let gridFrame: CGRect
        let columns: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        
        if !metrics.isLandscape {
            // Full-bleed, as the design draws it: the whole stage width and exactly 16:9 of it,
            // while the grid keeps its margins. It counter-scrolls to sit at the top of the
            // viewport (R27), so its frame is placed at the offset it was computed for.
            if spotlight != nil {
                spotlightFrame = CGRect(x: 0, y: viewport.minY, width: metrics.area.width, height: metrics.area.width / Metrics.spotlightAspect)
            } else {
                spotlightFrame = nil
            }
            // Several heroes put a row of dots under the spotlight (R19), and the grid starts
            // under those.
            let gridTop = spotlightFrame.map { $0.height + (heroStack == nil ? 0 : Metrics.heroDotsClearance) + Metrics.spacing } ?? 0
            gridFrame = CGRect(x: metrics.cardsLeading, y: gridTop, width: metrics.cardsWidth, height: 0)
            columns = Metrics.columns
            // Half the grid width less the gap, however much that leaves below the last row (R30).
            cellWidth = (metrics.cardsWidth - CGFloat(columns - 1) * Metrics.spacing) / CGFloat(columns)
            cellHeight = cellWidth / Metrics.tileAspect
        } else if spotlight != nil {
            // Landscape has height to spare nowhere and width to spare everywhere: the spotlight
            // takes the full stage height and all the width the column leaves (R14), the column is
            // one tile wide and shows at least two whole tiles (R31). The column is as wide as the
            // share allows or as wide as two rows allow, whichever is less.
            let rows = CGFloat(Metrics.landscapeColumnMinimumRows)
            let widthThatFitsTheRows = (metrics.cardsBottom - (rows - 1) * Metrics.spacing) / rows * Metrics.tileAspect
            let columnWidth = min(max(min(metrics.area.width * Metrics.landscapeColumnFraction, widthThatFitsTheRows),
                                      Metrics.landscapeColumnRange.lowerBound),
                                  Metrics.landscapeColumnRange.upperBound)
            let columnX = metrics.cardsTrailing - columnWidth
            spotlightFrame = CGRect(x: metrics.cardsLeading,
                                    y: viewport.minY,
                                    width: columnX - Metrics.spacing - metrics.cardsLeading,
                                    height: metrics.cardsBottom)
            gridFrame = CGRect(x: columnX, y: 0, width: columnWidth, height: 0)
            columns = 1
            cellWidth = columnWidth
            cellHeight = columnWidth / Metrics.tileAspect
        } else {
            // Four across, width-driven, rows scrolling under the bar: what the design draws.
            // Left-aligned like every other row; the centring this used to do is exactly what
            // R29 rules out.
            spotlightFrame = nil
            columns = Metrics.landscapeColumns
            cellWidth = (metrics.cardsWidth - CGFloat(columns - 1) * Metrics.spacing) / CGFloat(columns)
            cellHeight = cellWidth / Metrics.tileAspect
            gridFrame = CGRect(x: metrics.cardsLeading, y: 0, width: metrics.cardsWidth, height: 0)
        }
        
        if let spotlight, let spotlightFrame {
            placements.append(ElementCallTilePlacement(tile: spotlight.tile,
                                                       frame: spotlightFrame,
                                                       appearance: metrics.isLandscape ? .card : .spotlight,
                                                       isSpotlight: true,
                                                       visibility: .live,
                                                       orderIndex: spotlight.rank,
                                                       zIndex: spotlightZIndex))
            also.insert(spotlight.tile.id)
        }
        
        // The band a tile has to be within to be composed at all: one viewport either side. A tile
        // in it is live or paused; a tile beyond it is hidden and thereby released. Composition
        // therefore costs three viewports of tiles at most, whatever the call size (R47).
        let rowCount = (grid.count + columns - 1) / columns
        var lowestRank = Int.max
        var highestRank = -1
        for (index, (rank, tile)) in grid.enumerated() {
            let row = index / columns
            let column = index % columns
            let frame = CGRect(x: gridFrame.minX + CGFloat(column) * (cellWidth + Metrics.spacing),
                               y: gridFrame.minY + CGFloat(row) * (cellHeight + Metrics.spacing),
                               width: cellWidth,
                               height: cellHeight)
            let visibility = ElementCallTileVisibility.forFrame(frame, viewport: viewport, wasLive: input.liveTileIDs.contains(tile.id))
            guard visibility != .released else {
                hidden.insert(tile.id)
                continue
            }
            if !tile.isLocal {
                lowestRank = min(lowestRank, rank)
                highestRank = max(highestRank, rank)
            }
            placements.append(ElementCallTilePlacement(tile: tile,
                                                       frame: frame,
                                                       appearance: .card,
                                                       isSpotlight: false,
                                                       visibility: visibility,
                                                       orderIndex: tile.isLocal ? nil : rank,
                                                       zIndex: 0))
        }
        
        let gridHeight = rowCount == 0 ? 0 : CGFloat(rowCount) * cellHeight + CGFloat(rowCount - 1) * Metrics.spacing
        // Scrolled to the end the last row sits above the controls; scrolled to the top the first
        // row sits under the spotlight, or at the top of the stage (R44).
        let contentHeight = max(viewport.height, gridFrame.minY + gridHeight + metrics.bottomClearance)
        let ranks = highestRank < lowestRank ? 0..<0 : lowestRank..<(highestRank + 1)
        
        return ElementCallStageLayout(placements: placements,
                                      contentHeight: contentHeight,
                                      viewport: viewport,
                                      detailWindow: DetailWindow(ranks: ranks, also: also),
                                      // Falls back to any tile rather than going nil. The spotlight
                                      // is never ourselves, so with nobody spotlit there is none —
                                      // and a nil here left the source view unmounted, which AVKit
                                      // refuses with "the UIScene for the content source has an
                                      // activation state other than foregroundActive". A view in no
                                      // window belongs to no scene. Minimizing then did nothing at
                                      // all, twice, because the retry fails the same way.
                                      pictureInPictureTileID: spotlight?.tile.id ?? placements.first?.tile.id,
                                      hiddenTileIDs: hidden)
    }
}
