//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
@testable import ElementCallUI
import Foundation
import Testing

/// Pins the rects the stage hands its tiles: a tile keeps its identity across every arrangement, so
/// these frames are what the moves animate between. Spec 003, rule by rule; the arrangement is a
/// pure function, so this is where arrangement belongs.
struct ElementCallStageLayoutTests {
    /// An iPhone in portrait: 393 wide, 700 of stage above a 34 pt home indicator, 84 pt of controls.
    /// Typed so the expectations compare like with like: `#expect` types each operand on its own.
    let width: CGFloat = 393
    let height: CGFloat = 734
    let margin: CGFloat = 16
    let spacing: CGFloat = 12
    /// 734 - 34 - 84 - 12: the lowest point a card reaches on one screen.
    let cardsBottom: CGFloat = 604
    let metrics = ElementCallStageLayout.Metrics(area: CGSize(width: 393, height: 734), bottomInset: 34, controlsClearance: 84)
    
    /// The same phone on its side: 874 x 402, a 21 pt home indicator along the bottom, the sensor
    /// housing 59 pt in on the leading edge, and the bar floating over the bottom as in portrait.
    let landscape = ElementCallStageLayout.Metrics(area: CGSize(width: 874, height: 402),
                                                   bottomInset: 21,
                                                   leadingInset: 59,
                                                   controlsClearance: 84)
    /// Where a landscape card may go: inside the sensor housing and the trailing margin, above the
    /// indicator. The spotlight takes all of this; the bar floats over its bottom.
    let landscapeCards = CGRect(x: 75, y: 0, width: 783, height: 369)
    
    let local = tile("alice", isLocal: true)
    let bob = tile("bob")
    let carol = tile("carol")
    
    /// A portrait grid cell: half the card width less the gap, 4:3.
    var cellWidth: CGFloat {
        (width - 2 * margin - spacing) / 2
    }
    
    var cellHeight: CGFloat {
        cellWidth * 3 / 4
    }
    
    /// The portrait spotlight: the stage width, 16:9.
    var spotlightHeight: CGFloat {
        width * 9 / 16
    }
    
    static func tile(_ name: String, kind: MatrixRTCTileKind = .person, isLocal: Bool = false, isHero: Bool = false) -> ElementCallTile {
        ElementCallTile(id: MatrixRTCTileID(memberID: "@\(name):example.com:DEVICE", kind: kind),
                        userID: "@\(name):example.com",
                        displayName: name,
                        avatarURL: nil,
                        isLocal: isLocal,
                        isMicrophoneMuted: false,
                        hasVideo: kind == .screenShare,
                        isSpeaking: false,
                        handPosition: nil,
                        isHero: isHero,
                        stats: nil)
    }
    
    /// A member's screen: the same member ID as their camera tile, a different stream.
    static func share(_ name: String) -> ElementCallTile {
        tile(name, kind: .screenShare, isHero: true)
    }
    
    static func members(_ count: Int) -> [ElementCallTile] {
        (0..<count).map { tile("m\($0)") }
    }
    
    func compute(_ tiles: [ElementCallTile],
                 spotlight: MatrixRTCTileID? = nil,
                 fullscreen: MatrixRTCTileID? = nil,
                 offset: CGFloat = 0,
                 live: Set<MatrixRTCTileID> = [],
                 metrics: ElementCallStageLayout.Metrics? = nil) -> ElementCallStageLayout {
        ElementCallStageLayout.compute(.init(tiles: tiles,
                                             spotlightID: spotlight,
                                             fullscreenID: fullscreen,
                                             scrollOffset: offset,
                                             liveTileIDs: live,
                                             metrics: metrics ?? self.metrics))
    }
    
    func placement(_ tile: ElementCallTile, in layout: ElementCallStageLayout) throws -> ElementCallTilePlacement {
        try #require(layout.placements.first { $0.id == tile.id })
    }
    
    /// The grid's placements in reading order.
    func grid(_ layout: ElementCallStageLayout) -> [ElementCallTilePlacement] {
        layout.placements.filter { !$0.isSpotlight }.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }
    
    // MARK: - Which layout (019 R1, R8, R34)
    
    /// Up to five tiles and no spotlight are spec 019's small-call layout, which does not scroll;
    /// the sixth tile is the grid. 003's own small arrangements (R34–R36) are superseded.
    @Test
    func fiveTilesAreTheSmallCallLayoutAndSixAreTheGrid() {
        #expect(compute([local] + Self.members(4)).isStatic)
        let six = compute([local] + Self.members(5))
        #expect(!six.isStatic)
        #expect(six.placements.allSatisfy { $0.appearance == .card })
    }
    
    /// Full screen is the same one tile over either layout (019 R34).
    @Test
    func fullScreenOverTheSmallCallLayoutIsOneTile() throws {
        let layout = compute([local, bob, carol], fullscreen: bob.id)
        #expect(layout.placements.map(\.id) == [bob.id])
        #expect(try placement(bob, in: layout).appearance == .fullscreen)
        #expect(layout.hiddenTileIDs == [local.id, carol.id])
    }
    
    /// A remote share means the grid with the share in the spotlight, at any count (003 R34, 019 R8).
    @Test
    func aSpotlightMeansTheGridEvenForTwoTiles() throws {
        let share = Self.share("bob")
        let layout = compute([local, share, bob], spotlight: share.id)
        #expect(try placement(share, in: layout).isSpotlight)
        #expect(try placement(local, in: layout).frame.width == cellWidth)
        #expect(try placement(bob, in: layout).frame.minX == margin + cellWidth + spacing)
    }
    
    // MARK: - The portrait grid (R10, R12, R26, R29, R30)
    
    /// Six tiles, the fewest the grid gets without a spotlight (019 R1).
    @Test
    func aCellIsHalfTheWidthAndTheRowsStartAtTheTop() {
        let layout = compute([local] + Self.members(5))
        let cells = grid(layout)
        #expect(cells.count == 6)
        #expect(Set(cells.map(\.frame.size)).count == 1, "every grid tile is the same size (R12)")
        #expect(cells[0].frame == CGRect(x: margin, y: 0, width: cellWidth, height: cellHeight))
        #expect(cells[1].frame.minX == margin + cellWidth + spacing)
        #expect(cells[2].frame.minY == cellHeight + spacing)
        // The partial last row is left-aligned under the rows above (R29).
        #expect(cells[4].frame.minX == margin)
        #expect(cells[4].frame.minY == 2 * (cellHeight + spacing))
        #expect(abs(cellWidth / cellHeight - 4 / 3) < 0.001, "4:3 in portrait, not 3:4 (R10)")
    }
    
    @Test
    func theGridKeepsTheModelsOrderWithOurselvesFirst() {
        let tiles = [local, carol, bob] + Self.members(5)
        let layout = compute(tiles, spotlight: carol.id)
        #expect(grid(layout).map(\.id) == tiles.filter { $0.id != carol.id }.map(\.id))
        #expect(grid(layout).first?.id == local.id)
    }
    
    @Test
    func noTilesNoPlacements() {
        let layout = compute([])
        #expect(layout.placements.isEmpty)
        #expect(layout.contentHeight == height)
    }
    
    // MARK: - The portrait spotlight (R13, R27, R28)
    
    @Test
    func thePortraitSpotlightIsFullBleedSixteenByNineAndTheGridStartsUnderIt() throws {
        let layout = compute([local, bob, carol] + Self.members(3), spotlight: bob.id)
        let spotlight = try placement(bob, in: layout)
        #expect(spotlight.isSpotlight)
        #expect(spotlight.frame == CGRect(x: 0, y: 0, width: width, height: spotlightHeight))
        #expect(spotlight.appearance == .spotlight, "edge to edge, square corners")
        #expect(spotlight.zIndex == ElementCallStageLayout.spotlightZIndex)
        let ours = try placement(local, in: layout)
        #expect(spotlight.zIndex > ours.zIndex, "the grid passes underneath it")
        #expect(ours.frame == CGRect(x: margin, y: spotlightHeight + spacing, width: cellWidth, height: cellHeight))
        #expect(layout.pictureInPictureTileID == bob.id)
    }
    
    /// Sticky header: the spotlight's rect follows the offset, the grid's do not — which is what
    /// keeps the spotlight in one `ZStack` with the tiles it is promoted from.
    @Test
    func theSpotlightFollowsTheScrollOffsetAndTheGridDoesNot() throws {
        let tiles = [local, bob] + Self.members(20)
        let top = compute(tiles, spotlight: bob.id)
        let scrolled = compute(tiles, spotlight: bob.id, offset: 300)
        #expect(try placement(bob, in: scrolled).frame.minY == 300)
        #expect(try placement(bob, in: top).frame.minY == 0)
        // Our own tile scrolls with the grid (R28).
        let oursScrolled = try placement(local, in: scrolled)
        let oursAtTop = try placement(local, in: top)
        #expect(oursScrolled.frame == oursAtTop.frame)
    }
    
    // MARK: - Landscape (R14, R31, R32)
    
    @Test
    func landscapeGivesTheSpotlightTheHeightAndTheWidthTheColumnLeaves() throws {
        let tiles = [local, bob] + Self.members(6)
        let layout = compute(tiles, spotlight: bob.id, metrics: landscape)
        let spotlight = try placement(bob, in: layout)
        #expect(spotlight.frame.minX == landscapeCards.minX)
        #expect(spotlight.frame.minY == 0)
        #expect(spotlight.frame.height == landscapeCards.height, "the full stage height, not a 16:9 box centred in it")
        #expect(spotlight.appearance == .card, "inset from the housing and the rail, so rounded")
        
        let column = grid(layout)
        #expect(Set(column.map(\.frame.minX)).count == 1, "one tile wide")
        #expect(column[0].frame.minX == spotlight.frame.maxX + spacing)
        #expect(column[0].frame.maxX == landscapeCards.maxX)
        #expect(abs(column[0].frame.width / column[0].frame.height - 4 / 3) < 0.001)
        // At least two whole tiles show (R31).
        #expect(column[1].frame.maxY <= landscape.cardsBottom)
        #expect(column[1].frame.minY == column[0].frame.maxY + spacing)
    }
    
    /// The column is sized to fit its tiles, not to a share of the width and then whatever happens:
    /// 22% of 812 pt is a 179 pt column whose cells miss a second row by 8 pt.
    @Test
    func aShortLandscapeStageNarrowsTheColumnToKeepTwoWholeTiles() {
        let tight = ElementCallStageLayout.Metrics(area: CGSize(width: 812, height: 300), bottomInset: 1, controlsClearance: 84)
        let column = grid(compute([local] + Self.members(6), spotlight: bob.id, metrics: tight))
        #expect(column[0].frame.width >= 140)
        #expect(column[1].frame.maxY <= tight.cardsBottom)
    }
    
    @Test
    func landscapeWithoutASpotlightIsFourAcrossAndScrollsUnderTheBar() {
        let layout = compute([local] + Self.members(9), metrics: landscape)
        let cells = grid(layout)
        let cellWidth = (landscapeCards.width - 3 * spacing) / 4
        let cellHeight = cellWidth * 3 / 4
        #expect(cells[0].frame == CGRect(x: landscapeCards.minX, y: 0, width: cellWidth, height: cellHeight))
        #expect(cells[3].frame.maxX == landscapeCards.maxX, "four across")
        #expect(cells[4].frame.minX == landscapeCards.minX, "and the fifth starts the second row, left-aligned")
        #expect(cells[4].frame.minY == cellHeight + spacing)
        #expect(cells[8].frame.minY == 2 * (cellHeight + spacing), "a third row scrolls into view")
        // Scrolled to the end, the last row clears the bar floating over the bottom (R44).
        #expect(layout.contentHeight == 3 * cellHeight + 2 * spacing + 21 + 84 + spacing)
    }
    
    @Test
    func landscapeCardsClearTheSensorHousingAndTheTrailingMargin() {
        let layout = compute([local, bob] + Self.members(6), spotlight: bob.id, metrics: landscape)
        // 59 pt of housing plus the 16 pt margin on one side; the margin alone on the other, since
        // the bar is along the bottom rather than up the trailing edge.
        #expect(layout.placements.map(\.frame.minX).min() == 75)
        #expect(layout.placements.map(\.frame.maxX).max() == 858)
        // The column's end still clears the bar when scrolled to the bottom (R44).
        let column = compute([local, bob] + Self.members(20), spotlight: bob.id, metrics: landscape)
        let rows: CGFloat = 21
        let rowHeight = (landscape.area.width * 0.22) * 3 / 4
        #expect(abs(column.contentHeight - (rows * rowHeight + (rows - 1) * spacing + 21 + 84 + spacing)) < 0.01)
    }
    
    // MARK: - Scale (R47, R48)
    
    /// Only what is within a viewport of the screen is composed; a call of two hundred costs three
    /// viewports of tiles, whatever the roster size, and the rest are hidden and so released.
    @Test
    func twoHundredTilesComposeAtMostThreeViewportsAndHideTheRest() {
        let tiles = [local] + Self.members(199)
        let layout = compute(tiles, spotlight: tiles[1].id)
        let rowsInThreeViewports = Int((3 * height / (cellHeight + spacing)).rounded(.up))
        #expect(layout.placements.count <= rowsInThreeViewports * 2 + 1)
        #expect(layout.placements.count < 40)
        #expect(layout.hiddenTileIDs.count > 150)
        #expect(Set(layout.placements.map(\.id)).union(layout.hiddenTileIDs) == Set(tiles.map(\.id)))
        
        // Deep in the list the band moves with the offset: the top rows are hidden now.
        let deep = compute(tiles, spotlight: tiles[1].id, offset: 6000)
        #expect(deep.hiddenTileIDs.contains(tiles[2].id))
        #expect(deep.placements.count < 40)
        #expect(deep.placements.filter { $0.visibility == .live }.count <= 14)
    }
    
    /// **The invariant the release path rests on.** The stage decides what to stop asking the SFU
    /// for by taking the complement of what it draws, so a tile that is neither placed nor named
    /// hidden is a subscription nobody ever closes.
    @Test
    func everyTileIsEitherPlacedOrNamedHidden() {
        let share = Self.share("bob")
        let tiles = [local, share, bob, carol] + Self.members(30)
        let arrangements = [compute(tiles, spotlight: share.id),
                            compute(tiles, spotlight: share.id, offset: 1500),
                            compute(tiles, spotlight: share.id, fullscreen: share.id),
                            compute(tiles, metrics: landscape),
                            compute([local, bob])]
        for layout in arrangements {
            let accounted = Set(layout.placements.map(\.id)).union(layout.hiddenTileIDs)
            #expect(accounted == Set(layout.placements.isEmpty ? [] : (layout.placements.count == 2 ? [local.id, bob.id] : tiles.map(\.id))))
        }
    }
    
    // MARK: - Visibility (R48, R49, R56, R58)
    
    @Test
    func visibilityIsByDistanceFromTheViewportWithHysteresisOnTheLiveEdge() {
        let viewport = CGRect(x: 0, y: 1000, width: 393, height: 734)
        let cell = CGSize(width: 174.5, height: 130.875)
        func frame(y: CGFloat) -> CGRect {
            CGRect(origin: CGPoint(x: 16, y: y), size: cell)
        }
        // On screen, or overlapping its edge: live.
        #expect(ElementCallTileVisibility.forFrame(frame(y: 1200), viewport: viewport, wasLive: false) == .live)
        #expect(ElementCallTileVisibility.forFrame(frame(y: 900), viewport: viewport, wasLive: false) == .live)
        // Within a viewport: paused, and still composed.
        #expect(ElementCallTileVisibility.forFrame(frame(y: 1800), viewport: viewport, wasLive: false) == .paused)
        #expect(ElementCallTileVisibility.forFrame(frame(y: 200), viewport: viewport, wasLive: false) == .paused)
        // Further: released, which the layout turns into hidden.
        #expect(ElementCallTileVisibility.forFrame(frame(y: 2500), viewport: viewport, wasLive: false) == .released)
        #expect(ElementCallTileVisibility.forFrame(frame(y: 100), viewport: viewport, wasLive: false) == .released)
        // A tile that was live stays live until it is more than half a viewport past the edge, so a
        // tile bouncing at the edge does not stop and restart its stream on every bounce.
        #expect(ElementCallTileVisibility.forFrame(frame(y: 1800), viewport: viewport, wasLive: true) == .live)
        #expect(ElementCallTileVisibility.forFrame(frame(y: 2200), viewport: viewport, wasLive: true) == .paused)
        #expect(ElementCallTileVisibility.forFrame(frame(y: 600), viewport: viewport, wasLive: true) == .live)
    }
    
    @Test
    func theLayoutAppliesTheHysteresisToTheTilesItWasToldWereLive() {
        let tiles = [local] + Self.members(40)
        // Row 6 starts at 857, just under the first viewport's 734.
        let rowSix = tiles[13]
        let cold = compute(tiles)
        #expect(cold.placements.first { $0.id == rowSix.id }?.visibility == .paused)
        let warm = compute(tiles, live: [rowSix.id])
        #expect(warm.placements.first { $0.id == rowSix.id }?.visibility == .live)
    }
    
    // MARK: - The detail window (R52, R53)
    
    @Test
    func theWindowIsTheRankRangeOverTheComposedGridPlusTheSpotlight() {
        let tiles = [local] + Self.members(60)
        let top = compute(tiles)
        #expect(top.detailWindow.ranks.lowerBound == 0)
        #expect(top.detailWindow.ranks.upperBound == top.placements.compactMap(\.orderIndex).max()! + 1)
        #expect(top.detailWindow.also.isEmpty)
        
        let scrolled = compute(tiles, offset: 2000)
        #expect(scrolled.detailWindow.ranks.lowerBound > 0)
        #expect(scrolled.detailWindow.ranks.lowerBound == scrolled.placements.compactMap(\.orderIndex).min())
        #expect(scrolled.detailWindow.ranks.upperBound == scrolled.placements.compactMap(\.orderIndex).max()! + 1)
        
        // A listen-mode speaker mid-list punches a hole the explicit set covers.
        let speaker = tiles[6]
        let listen = compute(tiles, spotlight: speaker.id)
        #expect(listen.detailWindow.also == [speaker.id])
        #expect(listen.detailWindow.ranks.contains(4) && listen.detailWindow.ranks.contains(6))
        #expect(!listen.placements.contains { $0.orderIndex == 5 && !$0.isSpotlight })
        #expect(listen.placements.first { $0.isSpotlight }?.orderIndex == 5)
    }
    
    /// Within a row nothing changes: the range moves on row boundaries only, which is what keeps a
    /// scroll from declaring a new window on every pixel.
    @Test
    func theWindowIsRowQuantised() {
        let tiles = [local] + Self.members(60)
        let a = compute(tiles, offset: 300)
        let b = compute(tiles, offset: 320)
        #expect(a.detailWindow == b.detailWindow)
        #expect(Set(a.placements.map(\.id)) == Set(b.placements.map(\.id)))
    }
    
    // MARK: - Heroes (R17, R19–R24)
    
    @Test
    func unshownHeroesAreHiddenAndTheStackSaysWhichIsShown() throws {
        let a = Self.share("a")
        let m = Self.share("m")
        let tiles = [local, a, m, bob, carol]
        let first = compute(tiles, spotlight: a.id)
        #expect(try placement(a, in: first).isSpotlight)
        #expect(first.hiddenTileIDs == [m.id])
        #expect(first.heroStack == .init(count: 2, shown: 0))
        #expect(!first.placements.contains { $0.id == m.id }, "a hero is only ever drawn in the spotlight")
        
        let second = compute(tiles, spotlight: m.id)
        #expect(second.hiddenTileIDs == [a.id])
        #expect(second.heroStack == .init(count: 2, shown: 1))
        #expect(second.detailWindow.also == [m.id])
        
        #expect(compute([local, a, bob], spotlight: a.id).heroStack == nil, "one hero is not a stack")
        // The dots sit between the spotlight and the grid in portrait, so the grid starts lower.
        let clearance = ElementCallStageLayout.Metrics.heroDotsClearance
        #expect(try placement(local, in: first).frame.minY == spotlightHeight + clearance + spacing)
        #expect(try placement(local, in: compute([local, a, bob, carol], spotlight: a.id)).frame.minY == spotlightHeight + spacing)
    }
    
    /// The member you were watching can leave. The arrangement has to stand on its own when that
    /// happens; the screen clears the stale id separately, and this is what makes the gap harmless.
    @Test
    func aSpotlightOnATileThatHasGoneIsNoSpotlight() {
        let layout = compute([local, bob, carol, Self.tile("dan")], spotlight: MatrixRTCTileID(memberID: "@ghost:example.com:DEVICE"))
        #expect(!layout.placements.contains { $0.isSpotlight })
        #expect(layout.placements.count == 4)
    }
    
    // MARK: - A member on two tiles
    
    @Test
    func aSharerIsTwoTilesAndOnlyTheirScreenTakesTheSpotlight() throws {
        let share = Self.share("bob")
        let layout = compute([local, share, bob, carol], spotlight: share.id)
        let bobs = layout.placements.filter { $0.tile.memberID == bob.memberID }
        #expect(bobs.count == 2)
        #expect(Set(layout.placements.map(\.id)).count == layout.placements.count)
        #expect(try placement(share, in: layout).isSpotlight)
        let camera = try placement(bob, in: layout)
        #expect(!camera.isSpotlight, "the sharer's camera is in the grid like any other (R18)")
    }
    
    @Test
    func aCameraTileKeepsItsIdentityWhenAShareStartsAndStops() throws {
        let share = Self.share("bob")
        let before = compute([local, bob, carol])
        let during = compute([local, share, bob, carol], spotlight: share.id)
        let after = compute([local, bob, carol])
        for layout in [before, during, after] {
            #expect(try placement(bob, in: layout).id == bob.id)
        }
        #expect(Set(after.placements.map(\.id)) == Set(before.placements.map(\.id)))
    }
    
    // MARK: - Content height and shrinking (R42, R44)
    
    @Test
    func theContentEndsWithTheLastRowClearOfTheControls() {
        let layout = compute([local] + Self.members(19))
        let rows: CGFloat = 10
        #expect(layout.contentHeight == rows * cellHeight + (rows - 1) * spacing + (height - cardsBottom))
        #expect(layout.maxScrollOffset == layout.contentHeight - height)
        
        let withSpotlight = compute([local, bob] + Self.members(18), spotlight: bob.id)
        #expect(withSpotlight.contentHeight == spotlightHeight + spacing + rows * cellHeight + (rows - 1) * spacing + (height - cardsBottom))
        
        #expect(compute([local] + Self.members(3)).contentHeight == height, "never shorter than a screen")
    }
    
    @Test
    func aDepartureShortensTheContentSoTheOffsetHasSomewhereToSettle() {
        let before = compute([local] + Self.members(21), offset: 800)
        let after = compute([local] + Self.members(19), offset: 800)
        #expect(after.maxScrollOffset < before.maxScrollOffset)
        #expect(after.maxScrollOffset == after.contentHeight - height)
    }
    
    // MARK: - Full screen (R61–R63)
    
    @Test
    func fullScreenGivesOneTileTheScreenAtTheOffsetAndKeepsTheContentHeight() throws {
        let tiles = [local] + Self.members(29)
        let grid = compute(tiles, spotlight: tiles[1].id, offset: 900)
        let layout = compute(tiles, spotlight: tiles[1].id, fullscreen: tiles[7].id, offset: 900)
        let only = try #require(layout.placements.first)
        #expect(layout.placements.count == 1)
        #expect(only.id == tiles[7].id)
        #expect(only.appearance == .fullscreen)
        // The whole screen, where it is scrolled to: the frame is the viewport in content coordinates.
        #expect(only.frame == CGRect(x: 0, y: 900, width: width, height: height))
        #expect(only.zIndex == ElementCallStageLayout.fullscreenZIndex)
        // Nothing moved the content, so leaving lands where you were (R63).
        #expect(layout.contentHeight == grid.contentHeight)
        #expect(layout.pictureInPictureTileID == tiles[7].id)
        // Named rather than simply dropped: the stage releases the complement of what it draws.
        #expect(layout.hiddenTileIDs.count == 29)
        #expect(!layout.hiddenTileIDs.contains(tiles[7].id))
        // Only the one tile is asked for.
        #expect(layout.detailWindow == .init(ranks: 0..<0, also: [tiles[7].id]))
        #expect(layout.heroStack == nil)
    }
    
    /// The tiles full screen replaces do not vanish, they animate out, and a leaving view keeps its
    /// z position while it does. So the one growing has to be above every z position any other
    /// arrangement hands out, or something fades away on top of it: which is exactly what the
    /// spotlight's 1 did to a grid tile's 0.
    /// The scrim behind a growing tile covers the stage, the spotlight's arrows and dots
    /// included, and stays under the tile.
    @Test
    func theFullScreenScrimIsBetweenTheStageAndTheTile() {
        #expect(ElementCallStageLayout.fullscreenScrimZIndex > ElementCallStageLayout.spotlightZIndex + 0.5)
        #expect(ElementCallStageLayout.fullscreenScrimZIndex < ElementCallStageLayout.fullscreenZIndex)
    }
    
    @Test
    func theFullScreenTileIsAboveEveryTileItReplaces() throws {
        let tiles = [local, bob, carol] + Self.members(6)
        let everyOtherZIndex = [metrics, landscape].flatMap { metrics in
            [compute(tiles, spotlight: bob.id, metrics: metrics), compute(tiles, metrics: metrics), compute([local, bob], metrics: metrics)]
                .flatMap { $0.placements.map(\.zIndex) }
        }
        let highest = try #require(everyOtherZIndex.max())
        #expect(ElementCallStageLayout.fullscreenZIndex > highest)
    }
    
    @Test
    func fullScreenOnATileThatHasGoneFallsBackToTheOrdinaryLayout() {
        let layout = compute([local, bob, carol], spotlight: nil, fullscreen: MatrixRTCTileID(memberID: "@ghost:example.com:DEVICE"))
        #expect(layout.placements.count == 3)
        #expect(layout.hiddenTileIDs.isEmpty)
    }
    
    /// Going full screen on a share must hide its owner's camera like anybody else's, rather than
    /// treating "this member is on screen" as an answer. They are two tiles and only one is drawn.
    @Test
    func fullScreenOnAShareHidesItsOwnersCameraToo() {
        let share = Self.share("bob")
        let layout = compute([local, share, bob, carol], spotlight: share.id, fullscreen: share.id)
        #expect(layout.placements.count == 1)
        #expect(layout.hiddenTileIDs.contains(bob.id))
        #expect(!layout.hiddenTileIDs.contains(share.id))
    }
    
    // MARK: - Picture in Picture anchor
    
    /// The window is anchored to a tile that is actually on screen, in every arrangement that has
    /// one. A nil here is not a cosmetic gap: the source view is mounted as that tile's background,
    /// so nil leaves it in no window, and AVKit refuses a source view whose scene is not
    /// foreground-active. Minimizing then did nothing at all, which is how this was found.
    @Test
    func everyArrangementAnchorsThePictureInPictureSource() {
        for layout in [compute([local]), compute([local, bob]), compute([local, bob, carol]), compute([local] + Self.members(5)),
                       compute([local, bob] + Self.members(5), spotlight: bob.id), compute([local] + Self.members(5), metrics: landscape)] {
            #expect(layout.pictureInPictureTileID != nil)
            #expect(layout.placements.contains { $0.id == layout.pictureInPictureTileID })
        }
        #expect(compute([local]).pictureInPictureTileID == local.id)
        #expect(compute([local, bob, carol] + Self.members(3), spotlight: bob.id).pictureInPictureTileID == bob.id, "the spotlight wins")
    }
    
    // MARK: - Chrome (017)
    
    /// What the screen keeps clear for its chrome. Neither clearance depends on whether the chrome
    /// is up: the top bar never leaves in portrait (R30), landscape draws over the picture (R4), and
    /// the grid's end always clears where the control bar sits (R31). So hiding the chrome changes
    /// nothing the layout is given, and no tile moves or resizes. Only the banner, which is not
    /// chrome, adds to the top (R3).
    @Test
    func theClearancesDoNotDependOnTheChrome() {
        func top(landscape: Bool = false, fullscreen: Bool = false, banner: CGFloat? = nil) -> CGFloat {
            ElementCallView.topClearance(isLandscape: landscape, isFullscreen: fullscreen, topBarHeight: 44, bannerHeight: banner)
        }
        #expect(top() == 44 + spacing)
        #expect(top(banner: 28) == 44 + 28 + 2 * spacing)
        #expect(top(landscape: true) == 0)
        #expect(top(landscape: true, banner: 28) == 0)
        #expect(top(fullscreen: true) == 0)
    }
}
