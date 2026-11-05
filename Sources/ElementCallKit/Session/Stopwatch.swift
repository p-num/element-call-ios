//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Time on `clock` since this was called. Opens the existential so its instant can be kept:
/// `any Clock` has no `now` to subtract.
func stopwatch(_ clock: some Clock<Duration>) -> () -> Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
}
