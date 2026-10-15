//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Testing

/// The camera's format is chosen for its view and published at 720 on the short edge. The lists are
/// the 420f formats two real phones report, as `CameraCapturer.describeFormats` logs them.
nonisolated struct CameraCaptureFormatTests {
    private typealias Size = CameraCaptureFormat.Size
    
    @Test
    func iPhone15BackTakesTheWidestFourByThree() throws {
        let candidates = Self.parse(Self.iPhone15Back)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        // 1024x768 is narrower (65.7°); the binned 1920x1440 has the full view at the cheaper readout.
        #expect(candidates[format.candidate] == .init(width: 1920, height: 1440, maxFrameRate: 60, fieldOfView: 68.2, isBinned: true))
        #expect(format.output == Size(width: 960, height: 720))
    }
    
    @Test
    func iPhone15FrontTakesTheSmallestWhenTheViewIsTheSame() throws {
        let candidates = Self.parse(Self.iPhone15Front)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        #expect(candidates[format.candidate] == .init(width: 1024, height: 768, maxFrameRate: 60, fieldOfView: 73.7, isBinned: false))
        #expect(format.output == Size(width: 960, height: 720))
    }
    
    @Test
    func iPhoneXRBackTakesTheWidestFourByThree() throws {
        let candidates = Self.parse(Self.iPhoneXRBack)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        #expect(candidates[format.candidate] == .init(width: 1920, height: 1440, maxFrameRate: 60, fieldOfView: 67.2, isBinned: true))
        #expect(format.output == Size(width: 960, height: 720))
    }
    
    @Test
    func iPhoneXRFrontTakesTheFullViewAtThirty() throws {
        let candidates = Self.parse(Self.iPhoneXRFront)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        // Its 60 fps 1920x1440 and its 1024x768 are cropped to 52.2°, narrower than its 16:9.
        #expect(candidates[format.candidate] == .init(width: 1920, height: 1440, maxFrameRate: 30, fieldOfView: 56.6, isBinned: false))
        #expect(format.output == Size(width: 960, height: 720))
    }
    
    @Test
    func neverTakesSixteenByNineFromAFourByThreeCamera() throws {
        for list in [Self.iPhone15Back, Self.iPhone15Front, Self.iPhoneXRBack, Self.iPhoneXRFront] {
            let candidates = Self.parse(list)
            let format = try #require(CameraCaptureFormat.choose(from: candidates))
            #expect(candidates[format.candidate].aspectRatio == 4.0 / 3.0)
        }
    }
    
    @Test
    func aSixteenByNineCameraKeepsItsShape() throws {
        let candidates = Self.parse("""
        640x360 1-30 fps fov 70
        1280x720 1-30 fps fov 70
        1920x1080 1-30 fps fov 70
        """)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        #expect(candidates[format.candidate].width == 1280)
        #expect(format.output == Size(width: 1280, height: 720))
    }
    
    @Test
    func aFormatThatCannotReachThirtyLosesToOneThatCan() throws {
        let candidates = Self.parse("""
        1024x768 1-30 fps fov 60
        1920x1440 1-24 fps fov 66
        4032x3024 1-15 fps fov 66
        """)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        #expect(candidates[format.candidate].width == 1024)
        #expect(format.output == Size(width: 960, height: 720))
    }
    
    @Test
    func aCameraBelowSevenTwentyRunsTheClosestItHasUnscaled() throws {
        let candidates = Self.parse("""
        320x240 1-30 fps fov 60
        640x480 1-30 fps fov 60
        """)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        #expect(format.output == Size(width: 640, height: 480))
    }
    
    @Test
    func aCameraBelowFourEightyRunsTheLargestItHas() throws {
        let candidates = Self.parse("""
        160x120 1-30 fps fov 60
        320x240 1-30 fps fov 60
        """)
        let format = try #require(CameraCaptureFormat.choose(from: candidates))
        
        #expect(format.output == Size(width: 320, height: 240))
    }
    
    @Test
    func camerasOfDifferentShapesKeepTheShortEdge() throws {
        let fourByThree = try #require(CameraCaptureFormat.choose(from: Self.parse("1920x1440 1-30 fps fov 66")))
        let sixteenByNine = try #require(CameraCaptureFormat.choose(from: Self.parse("1920x1080 1-30 fps fov 70")))
        
        #expect(fourByThree.output.height == sixteenByNine.output.height)
    }
    
    @Test
    func theOutputIsEven() throws {
        let format = try #require(CameraCaptureFormat.choose(from: Self.parse("1001x750 1-30 fps fov 66")))
        
        #expect(format.output.width.isMultiple(of: 2))
        #expect(format.output.height == 720)
    }
    
    @Test
    func noFormatsIsNoChoice() {
        #expect(CameraCaptureFormat.choose(from: []) == nil)
    }
    
    // MARK: - Lists
    
    /// One `describeFormats` line per format: `<w>x<h> <min>-<max> fps fov <degrees>[ binned]`.
    private static func parse(_ list: String) -> [CameraCaptureFormat.Candidate] {
        list.split(separator: "\n").map { line in
            let words = line.split(separator: " ")
            let size = words[0].split(separator: "x")
            return .init(width: Int(size[0])!,
                         height: Int(size[1])!,
                         maxFrameRate: Double(words[1].split(separator: "-")[1])!,
                         fieldOfView: Double(words[4])!,
                         isBinned: words.count > 5)
        }
    }
    
    private static let iPhone15Back = """
    192x144 1-60 fps fov 65.7
    352x288 1-60 fps fov 61.2
    480x360 1-60 fps fov 65.7
    640x480 1-60 fps fov 65.7
    640x480 1-60 fps fov 65.7 binned
    960x540 1-60 fps fov 70.7
    1024x768 1-60 fps fov 65.7
    1280x720 1-30 fps fov 70.7
    1280x720 1-60 fps fov 70.7
    1280x720 1-60 fps fov 70.7 binned
    1280x720 1-240 fps fov 70.7 binned
    1440x1080 1-60 fps fov 65.7 binned
    1920x1080 1-30 fps fov 70.7
    1920x1080 1-60 fps fov 70.7
    1920x1080 1-60 fps fov 70.7 binned
    1920x1080 1-120 fps fov 70.7
    1920x1080 1-240 fps fov 70.7 binned
    1920x1440 1-60 fps fov 68.2
    1920x1440 1-60 fps fov 68.2 binned
    2592x1944 1-30 fps fov 68.2
    3264x2448 1-30 fps fov 68.2
    3840x2160 1-30 fps fov 70.7
    3840x2160 1-60 fps fov 70.7
    4032x3024 1-30 fps fov 68.2
    """
    
    private static let iPhone15Front = """
    192x144 1-60 fps fov 73.7
    352x288 1-60 fps fov 69.0
    480x360 1-60 fps fov 73.7
    640x480 1-60 fps fov 73.7
    640x480 1-60 fps fov 73.7 binned
    960x540 1-30 fps fov 73.7
    1024x768 1-60 fps fov 73.7
    1280x720 1-30 fps fov 73.7
    1280x720 1-60 fps fov 73.7
    1280x720 1-60 fps fov 73.7 binned
    1280x720 1-120 fps fov 73.7 binned
    1440x1080 1-60 fps fov 73.7 binned
    1920x1080 1-30 fps fov 73.7
    1920x1080 1-60 fps fov 73.7
    1920x1080 1-60 fps fov 73.7 binned
    1920x1080 1-120 fps fov 73.7 binned
    1920x1440 1-30 fps fov 73.7
    1920x1440 1-60 fps fov 73.7 binned
    3088x2316 1-30 fps fov 59.7
    3840x2160 1-30 fps fov 73.7
    3840x2160 1-60 fps fov 73.7
    4032x3024 1-30 fps fov 73.7
    """
    
    private static let iPhoneXRBack = """
    192x144 1-60 fps fov 64.7
    352x288 1-60 fps fov 60.3
    480x360 1-60 fps fov 64.7
    640x480 1-60 fps fov 64.7
    640x480 1-60 fps fov 64.7 binned
    960x540 1-60 fps fov 69.7
    1024x768 1-60 fps fov 64.7
    1280x720 1-30 fps fov 69.7
    1280x720 1-60 fps fov 69.7
    1280x720 1-60 fps fov 69.7 binned
    1280x720 1-240 fps fov 69.7 binned
    1440x1080 1-60 fps fov 64.7 binned
    1920x1080 1-30 fps fov 69.7
    1920x1080 1-60 fps fov 69.7
    1920x1080 1-60 fps fov 69.7 binned
    1920x1080 1-120 fps fov 38.4
    1920x1080 1-240 fps fov 69.7 binned
    1920x1440 1-30 fps fov 67.2
    1920x1440 1-60 fps fov 67.2 binned
    2592x1944 1-30 fps fov 67.2
    3264x2448 1-30 fps fov 67.2
    3840x2160 1-30 fps fov 69.7
    3840x2160 1-60 fps fov 69.7
    4032x3024 1-30 fps fov 67.2
    """
    
    private static let iPhoneXRFront = """
    192x144 1-60 fps fov 52.2
    352x288 1-60 fps fov 48.3
    480x360 1-60 fps fov 52.2
    640x480 1-60 fps fov 52.2
    640x480 1-60 fps fov 54.7 binned
    960x540 1-30 fps fov 61.2
    1024x768 1-60 fps fov 52.2
    1280x720 1-30 fps fov 61.2
    1280x720 1-60 fps fov 61.2
    1280x720 1-60 fps fov 61.2 binned
    1440x1080 1-60 fps fov 54.7 binned
    1920x1080 1-30 fps fov 61.2
    1920x1080 1-60 fps fov 61.2
    1920x1440 1-30 fps fov 56.6
    1920x1440 1-60 fps fov 52.2
    3088x2316 1-30 fps fov 56.6
    """
}
