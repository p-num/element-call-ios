//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CompoundDesignTokens
import SwiftUI

// The package's default look, backed by the real Compound design tokens.
//
// This is the tokens package only, never the Compound component library. Tokens are static values,
// so linking them here is harmless. Compound's own `CompoundColors` is a shared instance that a host
// re-brands at runtime, and a second copy of it linked into this package would never receive that
// override, leaving a re-branded host with a stock-coloured call screen.
//
// So a host that wants its own brand still supplies `ElementCallThemeProtocol` and reads its own instance.
// These types are what previews, snapshots and the example harness use, and what a host with no
// design system of its own gets for free.

public nonisolated struct ElementCallTokenTheme: ElementCallThemeProtocol {
    // Built per read rather than stored: the tokens are a bag of `Color` values, so there is
    // nothing here worth caching. It also had to be this way under compound-design-tokens 10.x,
    // where CompoundColorTokens was not Sendable; it is Sendable from 11.0.0, so that half of the
    // reason has gone and only the first half still holds.
    private var colors: CompoundColorTokens {
        CompoundColorTokens()
    }
    
    public init() { }
    
    public var bgCanvasDefault: Color {
        colors.bgCanvasDefault
    }
    
    public var bgCanvasDefaultLevel: Color {
        colors.bgCanvasDefaultLevel1
    }
    
    public var bgSubtleSecondary: Color {
        colors.bgSubtleSecondary
    }
    
    public var bgAccentRest: Color {
        colors.bgAccentRest
    }
    
    public var bgActionPrimaryRest: Color {
        colors.bgActionPrimaryRest
    }
    
    public var bgCriticalPrimary: Color {
        colors.bgCriticalPrimary
    }
    
    public var iconPrimary: Color {
        colors.iconPrimary
    }
    
    public var iconQuaternary: Color {
        colors.iconQuaternary
    }
    
    public var iconAccentPrimary: Color {
        colors.iconAccentPrimary
    }
    
    public var iconCriticalPrimary: Color {
        colors.iconCriticalPrimary
    }
    
    public var iconOnSolidPrimary: Color {
        colors.iconOnSolidPrimary
    }
    
    public var textPrimary: Color {
        colors.textPrimary
    }
    
    public var textSecondary: Color {
        colors.textSecondary
    }
    
    public var textCriticalPrimary: Color {
        colors.textCriticalPrimary
    }
    
    public var borderSuccessSubtle: Color {
        colors.borderSuccessSubtle
    }
    
    public var borderInteractiveSecondary: Color {
        colors.borderInteractiveSecondary
    }
    
    // Fonts are not generated into the tokens package: Compound hand-writes them on top of the
    // system text styles. These match that approach, which also means they scale with Dynamic Type.
    public var bodySM: Font {
        .system(.subheadline)
    }
    
    public var bodySMSemibold: Font {
        .system(.subheadline, weight: .semibold)
    }
    
    public var bodyLGSemibold: Font {
        .system(.body, weight: .semibold)
    }
}

public nonisolated struct ElementCallTokenIcons: ElementCallIconRenderingProtocol {
    public init() { }
    
    public func icon(_ icon: ElementCallIcon, size: ElementCallIconSize, relativeTo textStyle: ElementCallTextStyle?) -> AnyView {
        AnyView(ScaledCompoundIcon(image: Self.image(for: icon),
                                   size: Self.pointSize(for: size),
                                   textStyle: Self.uiTextStyle(for: textStyle)))
    }
    
    /// One for the process: it holds every icon Compound has, and making one per lookup was most
    /// of what a tile's body cost on each frame of a scroll.
    private static let icons = CompoundIcons()
    
    private static func image(for icon: ElementCallIcon) -> Image {
        switch icon {
        case .endCall: icons.endCall
        case .micOn: icons.micOnSolid
        case .micOff: icons.micOffSolid
        case .videoCall: icons.videoCallSolid
        case .videoCallOff: icons.videoCallOffSolid
        case .switchCamera: icons.switchCameraSolid
        case .shareScreen: icons.shareScreenSolid
        case .volumeOn: icons.volumeOnSolid
        case .volumeOff: icons.volumeOffSolid
        case .headphones: icons.headphonesSolid
        // Compound has no Bluetooth glyph yet; design is drawing one.
        case .bluetooth: icons.headphonesSolid
        case .raisedHand: icons.raisedHandSolid
        case .userProfile: icons.userProfileSolid
        case .overflow: icons.overflowHorizontal
        case .collapse: icons.collapse
        }
    }
    
    private static func pointSize(for size: ElementCallIconSize) -> CGFloat {
        // The sizes Compound uses for the same three roles.
        switch size {
        case .xSmall: 16
        case .small: 20
        case .medium: 24
        }
    }
    
    private static func uiTextStyle(for textStyle: ElementCallTextStyle?) -> Font.TextStyle {
        switch textStyle {
        case .bodySM, .bodySMSemibold: .subheadline
        case .bodyLGSemibold: .body
        case nil: .body
        }
    }
}

/// Grows the icon with Dynamic Type, the way Compound's own icon view does, so an icon beside a
/// label does not stay put while the label grows.
private struct ScaledCompoundIcon: View {
    let image: Image
    let size: CGFloat
    let textStyle: Font.TextStyle
    
    @ScaledMetric private var scale: CGFloat = 1
    
    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: size * scale, height: size * scale)
    }
    
    init(image: Image, size: CGFloat, textStyle: Font.TextStyle) {
        self.image = image
        self.size = size
        self.textStyle = textStyle
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: textStyle)
    }
}

/// Initials on a colour derived from the user ID, which is what most Matrix clients do. Media
/// loading stays with the host, so the avatar URL is ignored here on purpose: a snapshot test must
/// not reach the network.
public nonisolated struct ElementCallTokenAvatars: ElementCallAvatarRenderingProtocol {
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
    
    public init() { }
    
    /// Swift seeds `hashValue` differently in every process, so using it here gave a member a new
    /// avatar colour on each launch. Sum the bytes instead: stable across runs and across devices,
    /// which is what every other Matrix client does.
    private static func paletteIndex(for userID: String) -> Int {
        let sum = userID.utf8.reduce(0) { ($0 + Int($1)) % 4096 }
        return sum % palette.count
    }
    
    public func avatar(userID: String, displayName: String?, avatarURL: URL?, size: ElementCallAvatarSize) -> AnyView {
        let diameter: CGFloat = size == .thumbnail ? 52 : 96
        let name = displayName ?? userID
        let initial = name.trimmingCharacters(in: .whitespaces)
            .drop { !$0.isLetter && !$0.isNumber }
            .first
            .map { String($0).uppercased() } ?? "?"
        let colour = Self.palette[Self.paletteIndex(for: userID)]
        
        return AnyView(Circle()
            .fill(colour)
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initial)
                    .font(.system(size: diameter * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            })
    }
}
