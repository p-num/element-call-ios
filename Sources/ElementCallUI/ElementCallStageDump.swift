//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// One frame of a scenario as text: the declared window, what is composed and subscribed, and one
/// line per tile with its slot, rect, band, detail and the last constraints sent for its stream.
///
/// The format is feature-hq's (`plans/003.call_layout/scenarios/README.md`), so Android can emit
/// the same text for the same scenario and the two can be diffed: two platforms producing the same
/// dump is the parity check that repository exists for. A `.png` cannot say "this tile fell out of
/// the window"; a line of text can, and a reviewer reads the diff.
///
/// Differences in `rect` by a point or two are platform rounding; differences in `slot`, `vis`,
/// `detail`, `window` or `constraints` are findings.
enum ElementCallStageDump {
    /// - Parameters:
    ///   - frame: the scenario frame just applied, for the header.
    ///   - layout: the arrangement at that moment.
    ///   - tiles: the composed tiles, ourselves first, as the layout was given them.
    ///   - call: the call, for the roster's detail and the constraints last sent.
    static func render(frame: MatrixRTCScenario.Frame,
                       layout: ElementCallStageLayout,
                       tiles: [ElementCallTile],
                       call: MatrixRTCMediaSession) -> String {
        var lines = ["== \(describe(frame.time)) \(frame.text)"]
        let window = layout.detailWindow
        let subscribed = call.tiles.order.map(\.id).filter { id in
            call.requestedVideoConstraints(memberID: id.memberID, kind: id.kind.videoStreamKind).map { $0.isEnabled && $0.isVisible } ?? false
        }
        let spotlight = layout.placements.first(where: \.isSpotlight).map { token($0.tile) } ?? "-"
        let fullscreen = layout.placements.first { $0.appearance == .fullscreen }.map { token($0.tile) } ?? "-"
        lines.append("window ranks \(window.ranks.lowerBound)..<\(window.ranks.upperBound) also \(window.also.isEmpty ? "-" : window.also.sorted { $0.memberID < $1.memberID }.map(describe).joined(separator: ","))  composed \(layout.placements.count)  subscribed \(subscribed.count)  spotlight \(spotlight)  fullscreen \(fullscreen)")
        lines.append("rank slot      rect                 vis      detail constraints")
        
        let placements = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        let columns = layout.placements.filter { !$0.isSpotlight && $0.appearance != .fullscreen }
            .map(\.frame.minX).reduce(into: Set<CGFloat>()) { $0.insert($1) }.sorted()
        let rows = layout.placements.filter { !$0.isSpotlight && $0.appearance != .fullscreen }
            .map(\.frame.minY).reduce(into: Set<CGFloat>()) { $0.insert($1) }.sorted()
        
        func line(rank: String, tile: ElementCallTile) -> String {
            let placement = placements[tile.id]
            let slot: String
            let rect: String
            if let placement {
                if placement.appearance == .fullscreen {
                    slot = "full"
                } else if placement.isSpotlight {
                    slot = "spot"
                } else if placement.appearance == .floating {
                    slot = "float \(corner(of: placement.frame, in: layout.viewport))"
                } else if layout.isStatic, layout.viewport.width <= layout.viewport.height || placement.appearance == .fullBleed {
                    // A small call's own places, by the order it reads them in (019 R7, R27).
                    slot = "small \(layout.readingOrder.firstIndex(of: tile.id) ?? 0)"
                } else if layout.isStatic {
                    let row = rows.firstIndex(of: placement.frame.minY) ?? 0
                    let column = columns.firstIndex(of: placement.frame.minX) ?? 0
                    slot = "inline \(row),\(column)"
                } else {
                    let row = rows.firstIndex(of: placement.frame.minY) ?? 0
                    let column = columns.firstIndex(of: placement.frame.minX) ?? 0
                    slot = "grid \(row),\(column)"
                }
                rect = [placement.frame.minX, placement.frame.minY, placement.frame.width, placement.frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
            } else {
                slot = "hidden"
                rect = "-"
            }
            let visibility: String = if let placement {
                placement.visibility == .live ? "live" : "paused"
            } else {
                "released"
            }
            let detail = tile.isLocal ? "-" : (call.tiles.detail[tile.id] != nil ? "detail" : "ref")
            let constraints = if tile.isLocal {
                "-"
            } else if let sent = call.requestedVideoConstraints(memberID: tile.memberID, kind: tile.kind.videoStreamKind) {
                "\(sent.isEnabled ? "enabled" : "disabled") \(sent.isVisible ? "visible" : "hidden") \(sent.pixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "auto")"
            } else {
                "-"
            }
            return [pad(rank, 4), pad(slot, 9), pad(rect, 20), pad(visibility, 8), pad(detail, 6), constraints].joined(separator: " ")
        }
        
        for (rank, tile) in tiles.filter({ !$0.isLocal }).enumerated() {
            lines.append(line(rank: String(rank), tile: tile))
        }
        if let own = tiles.first(where: \.isLocal) {
            lines.append(line(rank: "-", tile: own))
        }
        return lines.joined(separator: "\n")
    }
    
    /// A tile as the scenario spells it: the member's name, `#` for a share, then its flags.
    static func token(_ tile: ElementCallTile) -> String {
        var token = name(of: tile.id)
        if tile.isScreenShare {
            token += "#"
        }
        if tile.isHero {
            token += "*"
        }
        if tile.isSpeaking {
            token += "!"
        }
        if tile.hasHandRaised {
            token += "^"
        }
        if tile.hasVideo {
            token += "v"
        }
        if tile.isMicrophoneMuted {
            token += "m"
        }
        return token
    }
    
    static func describe(_ id: MatrixRTCTileID) -> String {
        name(of: id) + (id.kind == .screenShare ? "#" : "")
    }
    
    /// `@A:example.com:DEVICE` → `A`; anything else stays as it is.
    private static func name(of id: MatrixRTCTileID) -> String {
        let member = id.memberID
        guard member.hasPrefix("@"), let colon = member.firstIndex(of: ":") else { return member }
        return String(member[member.index(after: member.startIndex)..<colon])
    }
    
    private static func describe(_ time: Duration) -> String {
        let seconds = Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
        return seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
    }
    
    /// Our floating tile's corner, by which quadrant of the screen it is in: `tl`, `tr`, `bl`, `br`,
    /// short enough for the slot column.
    private static func corner(of frame: CGRect, in viewport: CGRect) -> String {
        (frame.midY < viewport.midY ? "t" : "b") + (frame.midX < viewport.midX ? "l" : "r")
    }
    
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
