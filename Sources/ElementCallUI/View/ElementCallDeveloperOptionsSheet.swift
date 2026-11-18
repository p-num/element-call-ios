//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// What only a developer needs: tile stats, the membership format and the video codec (043 R10,
/// R11, R15). Reached from the settings menu, and only with the host's developer mode (R4).
///
/// The format and the codec are read when a call joins, so each says it takes effect on the next
/// join rather than pretending to change the call in progress (R14, R16a). The codec also warns that
/// a receiver that cannot decode it sees no video from us, since nothing publishes a backup (R15b).
/// Either format can be
/// chosen: a homeserver that cannot carry MSC fails that join, and the failure says so (R18).
struct ElementCallDeveloperOptionsSheet: View {
    @Bindable var context: ElementCallScreenContext
    
    var body: some View {
        ElementCallSettingsSheet(context: context,
                                 title: L10n.preferencesDeveloperOptions,
                                 sheetIdentifier: ElementCallAccessibilityIdentifiers.developerOptionsSheet,
                                 closeIdentifier: ElementCallAccessibilityIdentifiers.developerOptionsClose) {
            // Untitled: the sheet's title already says what it is.
            ElementCallSettingsSection {
                ElementCallSettingsToggle(title: L10n.preferencesTileStats,
                                          description: L10n.preferencesTileStatsDescription,
                                          isOn: context.viewState.isTileStatsVisible,
                                          identifier: ElementCallAccessibilityIdentifiers.developerOptionsTileStats) { _ in
                    context.send(viewAction: .toggleTileStats)
                }
            }
            // Each choice a card of its own, every value a row, what it does in the footer at full
            // width, as Element X's settings draw a choice (043 R11, R14, R15, R15b).
            ElementCallSettingsSection(title: L10n.developerOptionsMembershipFormat,
                                       footer: L10n.developerOptionsNextJoin) {
                ElementCallSettingsChoices(selection: context.viewState.membershipFormat,
                                           values: MatrixRTCMembershipFormat.allCases,
                                           label: Self.title(of:),
                                           identifier: ElementCallAccessibilityIdentifiers.developerOptionsMembershipFormat(_:)) {
                    context.send(viewAction: .setMembershipFormat($0))
                }
            }
            ElementCallSettingsSection(title: L10n.developerOptionsVideoCodec,
                                       footer: L10n.developerOptionsVideoCodecDescription) {
                ElementCallSettingsChoices(selection: shownCodec,
                                           values: context.viewState.videoCodecs,
                                           label: Self.title(of:),
                                           identifier: ElementCallAccessibilityIdentifiers.developerOptionsVideoCodec(_:)) {
                    context.send(viewAction: .setVideoCodec($0))
                }
            }
        }
    }
    
    /// A stored codec this device no longer encodes publishes as Auto, so it reads as Auto: the
    /// list offers only what the device can do (043 R15).
    private var shownCodec: MatrixRTCVideoCodec {
        context.viewState.videoCodecs.contains(context.viewState.videoCodec) ? context.viewState.videoCodec : .auto
    }
    
    static func title(of format: MatrixRTCMembershipFormat) -> String {
        switch format {
        case .msc: L10n.developerOptionsMembershipFormatMsc
        case .roomState: L10n.developerOptionsMembershipFormatRoomState
        }
    }
    
    /// Codec names are the same in every language, Auto excepted.
    static func title(of codec: MatrixRTCVideoCodec) -> String {
        switch codec {
        // Auto names what it publishes, so it does not read as a choice of its own (043 R15a).
        case .auto: L10n.developerOptionsVideoCodecAuto(title(of: MatrixRTCVideoCodec.autoCodec))
        case .vp8: "VP8"
        case .h264: "H.264"
        case .vp9: "VP9"
        case .av1: "AV1"
        }
    }
}

// MARK: - Previews

struct ElementCallDeveloperOptionsSheet_Previews: PreviewProvider, TestablePreview {
    static func sheet(format: MatrixRTCMembershipFormat, codec: MatrixRTCVideoCodec, isTileStatsVisible: Bool) -> some View {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group)
        state.isDeveloperModeEnabled = true
        state.isTileStatsVisible = isTileStatsVisible
        state.membershipFormat = format
        state.videoCodec = codec
        // Pinned: the device's own list would make the image depend on the simulator.
        state.videoCodecs = [.auto, .vp8, .h264, .vp9]
        return ElementCallDeveloperOptionsSheet(context: .preview(state: state))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        sheet(format: .roomState, codec: .auto, isTileStatsVisible: false)
            .previewDisplayName("Defaults")
        sheet(format: .msc, codec: .h264, isTileStatsVisible: true)
            .previewDisplayName("Changed")
    }
}
