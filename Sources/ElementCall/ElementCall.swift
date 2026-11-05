//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// One dependency and one import for a host that wants the whole thing, without collapsing the three
// modules into one. This module is the bare name because that is the name a host reaches for: it
// used to belong to the lifecycle-and-ports layer, which is now ElementCallHost, and the umbrella
// was called ElementCallAll. Hosts asked why, and there was no answer beyond "the name was taken".
//
// The split behind it is load-bearing and stays: it is what stops the media layer growing a
// dependency on the view layer. A host that only wants the media layer can still depend on
// ElementCallKit alone, because all three products are still published.
//
// The core's bindings are re-exported as well, as Android exposes the whole core to its hosts. A host
// needs none of them to integrate: the Matrix backend it implements is ours,
// ElementCallMatrixBackendProtocol, so that its code never repeats the bindings' generated names.
//
// `@_exported` is underscored, and it is the only way to do this: a product listing several
// targets still makes the host write one import per module, because a product is a linkage unit
// rather than a module. Re-exporting is stable, widely used for exactly this, and the failure mode
// if it ever went away is a compile error in the host rather than anything subtle.

@_exported import ElementCallHost
@_exported import ElementCallKit
@_exported import ElementCallUI
@_exported import MatrixRtc
