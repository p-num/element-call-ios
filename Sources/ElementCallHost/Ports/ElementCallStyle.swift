//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

// MARK: - Theme

/// Colours and fonts, supplied by the host.
///
/// Every member is a computed property read at draw time, never a value captured once. That matters
/// for a host whose design system can be re-branded at runtime: a snapshot taken at construction
/// would leave the call screen on stock colours while the rest of the app changed.
public nonisolated protocol ElementCallThemeProtocol: Sendable {
    // Backgrounds
    @MainActor var bgCanvasDefault: Color { get }
    @MainActor var bgCanvasDefaultLevel: Color { get }
    @MainActor var bgSubtleSecondary: Color { get }
    @MainActor var bgAccentRest: Color { get }
    @MainActor var bgActionPrimaryRest: Color { get }
    @MainActor var bgCriticalPrimary: Color { get }
    
    // Icons
    @MainActor var iconPrimary: Color { get }
    @MainActor var iconQuaternary: Color { get }
    @MainActor var iconAccentPrimary: Color { get }
    @MainActor var iconCriticalPrimary: Color { get }
    /// For an icon drawn on top of a filled button, where the usual icon colour would disappear.
    @MainActor var iconOnSolidPrimary: Color { get }
    
    // Text
    @MainActor var textPrimary: Color { get }
    @MainActor var textSecondary: Color { get }
    @MainActor var textCriticalPrimary: Color { get }
    
    // Borders
    @MainActor var borderSuccessSubtle: Color { get }
    @MainActor var borderInteractiveSecondary: Color { get }
    
    // Fonts
    @MainActor var bodySM: Font { get }
    @MainActor var bodySMSemibold: Font { get }
    @MainActor var bodyLGSemibold: Font { get }
    
    /// The ring round a grid tile whose member is speaking, as layers drawn bottom first. Asked for
    /// with the tile's own size because the design's diagonal is a CSS angle, and where that puts
    /// the colours depends on the tile's proportions: computed once for the screen, a narrow tile
    /// would show only the middle of the sweep. Return a single colour for a plain ring.
    @MainActor func activeSpeakerBorder(in size: CGSize) -> [AnyShapeStyle]
    
    /// The ring round a tile whose member has a hand up, the same way.
    @MainActor func raisedHandBorder(in size: CGSize) -> [AnyShapeStyle]
}

public extension ElementCallThemeProtocol {
    /// The design's gradients, so a host theme written before these existed keeps compiling and
    /// gets the designed rings rather than none.
    @MainActor func activeSpeakerBorder(in size: CGSize) -> [AnyShapeStyle] {
        ElementCallBorderGradient.activeSpeaker.layers(in: size)
    }
    
    @MainActor func raisedHandBorder(in size: CGSize) -> [AnyShapeStyle] {
        ElementCallBorderGradient.raisedHand.layers(in: size)
    }
}

/// The design's tile rings: a vertical gradient over a diagonal one between the same two colours,
/// as the Figma's CSS layers them, the diagonal at 0.7 and the vertical at 0.9. Literal colours
/// because Compound has no token for any of them; Android's `ActiveSpeakerBrush` uses the same
/// speaking pair.
public nonisolated struct ElementCallBorderGradient: Sendable {
    /// Blue to teal.
    public static let activeSpeaker = ElementCallBorderGradient(top: Color(red: 13 / 255, green: 92 / 255, blue: 189 / 255),
                                                                bottom: Color(red: 13 / 255, green: 189 / 255, blue: 168 / 255))
    /// Orange to yellow.
    public static let raisedHand = ElementCallBorderGradient(top: Color(red: 220 / 255, green: 103 / 255, blue: 0),
                                                             bottom: Color(red: 241 / 255, green: 189 / 255, blue: 0))
    
    private static let diagonalCSSDegrees = 119.36
    
    public let top: Color
    public let bottom: Color
    
    public init(top: Color, bottom: Color) {
        self.top = top
        self.bottom = bottom
    }
    
    public func layers(in size: CGSize) -> [AnyShapeStyle] {
        let diagonal = Self.diagonalEnds(in: size)
        return [
            AnyShapeStyle(LinearGradient(colors: [top.opacity(0.7), bottom.opacity(0.7)],
                                         startPoint: diagonal.start,
                                         endPoint: diagonal.end)),
            AnyShapeStyle(LinearGradient(colors: [top.opacity(0.9), bottom.opacity(0.9)],
                                         startPoint: .top,
                                         endPoint: .bottom))
        ]
    }
    
    /// Where CSS puts a gradient line: through the centre, at the angle measured clockwise from up,
    /// and |w·sin θ| + |h·cos θ| long, which is exactly long enough for the end colours to land in
    /// the corners. In unit points, since that is what a gradient filling a shape is laid out in.
    static func diagonalEnds(in size: CGSize) -> (start: UnitPoint, end: UnitPoint) {
        guard size.width > 0, size.height > 0 else { return (.topLeading, .bottomTrailing) }
        let angle = diagonalCSSDegrees * .pi / 180
        let dx = sin(angle)
        let dy = -cos(angle)
        let half = (abs(size.width * dx) + abs(size.height * dy)) / 2
        let offsetX = dx * half / size.width
        let offsetY = dy * half / size.height
        return (UnitPoint(x: 0.5 - offsetX, y: 0.5 - offsetY), UnitPoint(x: 0.5 + offsetX, y: 0.5 + offsetY))
    }
}

// MARK: - Icons

public nonisolated enum ElementCallIcon: Sendable, CaseIterable {
    case endCall
    case micOn
    case micOff
    case videoCall
    case videoCallOff
    case switchCamera
    case shareScreen
    case volumeOn
    case volumeOff
    case headphones
    case bluetooth
    case raisedHand
    case userProfile
    case overflow
    case collapse
}

public nonisolated enum ElementCallIconSize: Sendable {
    case xSmall, small, medium
}

/// The text style an icon scales alongside, so it grows with Dynamic Type the way its label does.
public nonisolated enum ElementCallTextStyle: Sendable {
    case bodySM, bodySMSemibold, bodyLGSemibold
}

/// Icons, supplied by the host so they match the rest of its app and scale with Dynamic Type.
public nonisolated protocol ElementCallIconRenderingProtocol: Sendable {
    @MainActor
    func icon(_ icon: ElementCallIcon, size: ElementCallIconSize, relativeTo textStyle: ElementCallTextStyle?) -> AnyView
}

public extension ElementCallIconRenderingProtocol {
    @MainActor
    func icon(_ icon: ElementCallIcon, size: ElementCallIconSize = .medium) -> AnyView {
        self.icon(icon, size: size, relativeTo: nil)
    }
}

// MARK: - Avatars

public nonisolated enum ElementCallAvatarSize: Sendable {
    /// Not requested by the built-in stage.
    case thumbnail
    /// Every tile, and the Picture in Picture placeholder. A grid tile draws it scaled down to
    /// 52 pt, so it grows into the spotlight or full screen as one picture.
    case full
}

/// Avatars, supplied by the host. Keeping this on the host's side means the package never loads or
/// caches media, and avatars keep whatever placeholder colours and initials the host already uses.
public nonisolated protocol ElementCallAvatarRenderingProtocol: Sendable {
    @MainActor
    func avatar(userID: String, displayName: String?, avatarURL: URL?, size: ElementCallAvatarSize) -> AnyView
}

// MARK: - The bag

/// Everything presentational the host supplies, gathered so it can be handed to the view tree once.
public nonisolated struct ElementCallStyle: Sendable {
    public let theme: any ElementCallThemeProtocol
    public let icons: any ElementCallIconRenderingProtocol
    public let avatars: any ElementCallAvatarRenderingProtocol
    public let strings: ElementCallStrings
    
    public init(theme: any ElementCallThemeProtocol,
                icons: any ElementCallIconRenderingProtocol,
                avatars: any ElementCallAvatarRenderingProtocol,
                strings: ElementCallStrings = .init()) {
        self.theme = theme
        self.icons = icons
        self.avatars = avatars
        self.strings = strings
    }
    
    /// The real Compound design tokens, for previews, snapshots and any host with no design system
    /// of its own to plug in. Tokens only, never the Compound component library: see
    /// `ElementCallTokenStyle.swift` for why that distinction matters.
    public static let stock = ElementCallStyle(theme: ElementCallTokenTheme(),
                                               icons: ElementCallTokenIcons(),
                                               avatars: ElementCallTokenAvatars())
}
