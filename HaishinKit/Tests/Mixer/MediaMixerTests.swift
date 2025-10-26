import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct MediaMixerTests {
    @Test func videoConfiguration() async throws {
        let mixer = MediaMixer()
        await #expect(throws: (MediaMixer.Error).self) {
            try await mixer.configuration(video: 0) { _ in }
        }
        try await mixer.attachVideo(AVCaptureDevice.default(for: .video), track: 0) { unit in
            #expect(throws: (any Error).self) {
                try unit.setFrameRate(60)
            }
        }
        try await mixer.configuration(video: 0) { _ in }
    }

    @Test func release() {
        weak var weakMixer: MediaMixer?
        _ = {
            let mixer = MediaMixer(captureSessionMode: .manual)
            weakMixer = mixer
        }()
        #expect(weakMixer == nil)
    }
}
