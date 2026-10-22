//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The fixture list the app opens on, and what a minimized call is minimized *over*.
///
/// Every identifier here is prefixed `example.`, never `elementCall.`. The UI tests find tiles by
/// matching the `elementCall.tile.` prefix across the whole hierarchy, so an example-app identifier
/// borrowing the package's namespace would quietly join that set.
struct ElementCallExampleCatalogue: View {
    let target: ElementCallExampleLaunchTarget
    /// Something the host wants read, such as a scenario that did not parse.
    var notice: String?
    /// The row to come back to. The catalogue is unmounted while a call is up, so it would
    /// otherwise reappear at the top, a long scroll away from the fixture just closed.
    var returningTo: String?
    let onPick: (ElementCallExampleFixture) -> Void
    let onPickScenario: (ElementCallExampleScenario) -> Void
    
    /// Each row's identifier, which is also its scroll identity.
    static func rowID(_ fixture: ElementCallExampleFixture) -> String {
        "example.fixture.\(fixture.rawValue)"
    }
    
    static func rowID(_ scenario: ElementCallExampleScenario) -> String {
        "example.scenario.\(scenario.name)"
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            list
                .onAppear {
                    guard let returningTo else { return }
                    proxy.scrollTo(returningTo, anchor: .center)
                }
        }
    }
    
    private var list: some View {
        List {
            if case .unknown(let flag, let name) = target {
                unknownTarget(flag: flag, name: name)
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("example.notice")
            }
            ForEach(ElementCallExampleFixture.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(ElementCallExampleFixture.fixtures(in: category), id: \.self) { fixture in
                        row(fixture)
                    }
                }
            }
            Section("Scenarios") {
                ForEach(ElementCallExampleScenario.all) { scenario in
                    Button {
                        onPickScenario(scenario)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scenario.name).font(.body)
                            Text(scenario.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(Self.rowID(scenario))
                    .id(Self.rowID(scenario))
                }
            }
        }
    }
    
    private func row(_ fixture: ElementCallExampleFixture) -> some View {
        Button {
            onPick(fixture)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.title)
                    .font(.body)
                Text(fixture.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The label is a whole stack, so without this the button answers to both lines run
            // together and a test would have to know the detail string to find a row.
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.rowID(fixture))
        .id(Self.rowID(fixture))
    }
    
    /// Shown rather than silently substituted. The launch flag used to fall back to `.group` on
    /// anything it did not recognise, so a typo ran the strip tests against an eight-person stage
    /// and failed with "this tile is not hittable" — a true statement about nothing. On screen, it
    /// is in the failure screenshot; logged, it is in the run's console too.
    private func unknownTarget(flag: String, name: String) -> some View {
        let isScenario = flag == ElementCallExampleFixture.scenarioLaunchArgument
        let known = isScenario ? ElementCallExampleScenario.all.map(\.name) : ElementCallExampleFixture.allCases.map(\.rawValue)
        return VStack(alignment: .leading, spacing: 4) {
            Text(name.isEmpty ? "Nothing given after \(flag)"
                : "Unknown \(isScenario ? "scenario" : "fixture") \u{201C}\(name)\u{201D}")
                .font(.headline)
            Text("Showing the catalogue. Known: \(known.joined(separator: ", "))")
                .font(.caption)
        }
        .foregroundStyle(.red)
        .accessibilityIdentifier("example.unknownTarget")
    }
}
