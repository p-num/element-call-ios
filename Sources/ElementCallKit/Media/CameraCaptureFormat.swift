//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Which of a camera's formats to run, and what size every published frame is scaled to.
///
/// The published size is what the layers are derived from, so it is held at 720 on the short edge
/// whatever the format: LiveKit then encodes 180, 360 and 720, the heights a web sender's layers
/// have. The format is chosen for its view, not its size. Formats of one shape do not all show the
/// same scene: on an iPhone 15's back camera 640x480 and 1024x768 are cropped against 1920x1440, and
/// on an iPhone XR's front camera they show less than 16:9 does. A 16:9 format such as
/// `.hd1280x720`, the obvious one, loses about a quarter of the height of a 4:3 sensor.
nonisolated struct CameraCaptureFormat: Equatable {
    /// One of the camera's formats, in the sensor's landscape orientation.
    struct Candidate: Equatable {
        var width: Int
        var height: Int
        var maxFrameRate: Double
        /// Horizontal, in degrees.
        var fieldOfView: Double
        var isBinned: Bool
        
        var shortEdge: Int {
            min(width, height)
        }
        
        var longEdge: Int {
            max(width, height)
        }
        
        var area: Int {
            width * height
        }
        
        var aspectRatio: Double {
            Double(longEdge) / Double(shortEdge)
        }
    }
    
    struct Size: Equatable {
        var width: Int
        var height: Int
    }
    
    /// Index into the candidates the camera offered.
    var candidate: Int
    /// What every frame is scaled to; the candidate's own size when it needs no scaling.
    var output: Size
    
    static let targetShortEdge = 720
    /// Below this the core publishes a single layer.
    static let minimumLongEdge = 480
    static let frameRate: Double = 30
    /// What is published when no camera can be asked: a 4:3 camera's output.
    static let fallbackOutput = Size(width: 960, height: 720)
    
    static func choose(from candidates: [Candidate]) -> CameraCaptureFormat? {
        // The native shape is the full sensor's, which is the largest format's: every smaller one of
        // that shape is the same picture binned or scaled, give or take a crop.
        guard let largest = candidates.max(by: { $0.area < $1.area }) else { return nil }
        let shaped = candidates.indices.filter { abs(candidates[$0].aspectRatio - largest.aspectRatio) / largest.aspectRatio < 0.01 }
        let fastEnough = shaped.filter { candidates[$0].maxFrameRate >= frameRate }
        let pool = fastEnough.isEmpty ? shaped : fastEnough
        
        let tallEnough = pool.filter { candidates[$0].shortEdge >= targetShortEdge }
        let widest = tallEnough.map { candidates[$0].fieldOfView }.max() ?? 0
        // The widest view, then the least to read off the sensor, then binned, which is the cheaper
        // readout of the same view.
        if let index = tallEnough.filter({ widest - candidates[$0].fieldOfView < 0.05 }).min(by: { lhs, rhs in
            let (lhs, rhs) = (candidates[lhs], candidates[rhs])
            return lhs.area != rhs.area ? lhs.area < rhs.area : lhs.isBinned && !rhs.isBinned
        }) {
            let chosen = candidates[index]
            let longEdge = Int((Double(targetShortEdge) * chosen.aspectRatio / 2).rounded()) * 2
            let output = chosen.width >= chosen.height
                ? Size(width: longEdge, height: targetShortEdge)
                : Size(width: targetShortEdge, height: longEdge)
            return CameraCaptureFormat(candidate: index, output: output)
        }
        
        // A camera that cannot reach 720 runs the closest it has, unscaled; under 480 on the long
        // edge too, the largest it has, which the core publishes as one layer.
        let usable = pool.filter { candidates[$0].longEdge >= minimumLongEdge }
        guard let index = (usable.isEmpty ? pool : usable).max(by: { lhs, rhs in
            let (lhs, rhs) = (candidates[lhs], candidates[rhs])
            return lhs.area != rhs.area ? lhs.area < rhs.area : lhs.fieldOfView < rhs.fieldOfView
        }) else { return nil }
        return CameraCaptureFormat(candidate: index, output: Size(width: candidates[index].width, height: candidates[index].height))
    }
}
