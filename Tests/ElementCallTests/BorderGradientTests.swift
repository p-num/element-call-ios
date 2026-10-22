//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
import Foundation
import SwiftUI
import Testing

/// The tile rings' diagonal is a CSS angle laid out in unit points, and a mistake in that
/// conversion shows as a ring that is all one colour on any tile that is not square. The snapshot of
/// one portrait tile cannot tell a wrong angle from a right one; this can.
@Suite("Tile ring gradient")
struct BorderGradientTests {
    /// Where a point falls along the gradient, 0 at the start and 1 at the end, in points.
    private func position(of point: CGPoint, in size: CGSize) -> CGFloat {
        let ends = ElementCallBorderGradient.diagonalEnds(in: size)
        let start = CGPoint(x: ends.start.x * size.width, y: ends.start.y * size.height)
        let end = CGPoint(x: ends.end.x * size.width, y: ends.end.y * size.height)
        let line = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let lengthSquared = line.x * line.x + line.y * line.y
        return ((point.x - start.x) * line.x + (point.y - start.y) * line.y) / lengthSquared
    }
    
    @Test("The end colours land exactly in the corners, at any proportions",
          arguments: [CGSize(width: 180, height: 240), CGSize(width: 400, height: 200), CGSize(width: 100, height: 100)])
    func endColoursInTheCorners(size: CGSize) {
        #expect(abs(position(of: .zero, in: size)) < 0.0001)
        #expect(abs(position(of: CGPoint(x: size.width, y: size.height), in: size) - 1) < 0.0001)
    }
    
    @Test("It runs down and to the right")
    func direction() {
        let ends = ElementCallBorderGradient.diagonalEnds(in: CGSize(width: 180, height: 240))
        #expect(ends.end.x > ends.start.x)
        #expect(ends.end.y > ends.start.y)
    }
}

/// The raised-hand ring is the speaking ring's shape in the design's orange: `#DC6700` to `#F1BD00`.
@Suite("Raised hand ring colours")
@MainActor
struct RaisedHandRingColourTests {
    @Test
    func theRaisedHandPairIsTheDesigns() {
        let gradient = ElementCallBorderGradient.raisedHand
        #expect(hex(gradient.top) == "DC6700")
        #expect(hex(gradient.bottom) == "F1BD00")
    }
    
    private func hex(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        // Resolved components are linear; the hex is sRGB, which `cgColor` gives back.
        let components = resolved.cgColor.components ?? []
        return components.prefix(3).map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}
