//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The material behind a floating control: liquid glass on iOS 26 (spec 003 R46), the flat fill
/// the design used before it everywhere else. The deployment target stays at 18, so both exist.
///
/// A modifier rather than a branch at each call site so the bar, the top bar's buttons and the
/// fullscreen exit button cannot drift onto different materials. The buttons keep their own
/// active and inactive fills, because those carry state; only the surface behind them is glass.
/// The fallback colour is passed in and read at the call site, so it stays a theme computed
/// property read at draw time rather than a colour captured here.
struct ElementCallGlass<S: Shape>: ViewModifier {
    @Environment(\.elementCallGlassEnabled) private var isGlassEnabled
    let shape: S
    let fallback: Color
    /// A colour the glass carries, for a state the button has to show: the highlighted control,
    /// the hang-up button. Nil is plain glass. Below iOS 26 the tint is the fill.
    var tint: Color?
    /// Every button is interactive glass, and not only for the highlight it gives a press: plain
    /// glass is not wired for touch, and a plain-glass button drawn over the scrolling content
    /// took no taps at all, on the simulator and on a phone, with the double tap falling through
    /// to the tile beneath. Outside the scroller plain glass happened to work; interactive is
    /// what a button is meant to be.
    var isInteractive = false
    
    func body(content: Content) -> some View {
        if #available(iOS 26, *), isGlassEnabled {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(isInteractive ? glass.interactive() : glass, in: shape)
        } else {
            content.background(tint ?? fallback, in: shape)
        }
    }
}

extension View {
    func elementCallGlass(in shape: some Shape, fallback: Color, tint: Color? = nil, isInteractive: Bool = false) -> some View {
        modifier(ElementCallGlass(shape: shape, fallback: fallback, tint: tint, isInteractive: isInteractive))
    }
    
    /// A surface that exists only where there is no glass: the control bar's capsule. On iOS 26
    /// the buttons are the glass and nothing sits behind them — glass does not nest, and a glass
    /// capsule around glass buttons left the buttons with no material of their own.
}
