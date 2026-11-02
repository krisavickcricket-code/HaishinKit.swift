import Accelerate
import AVFoundation

extension AVAudioPCMBuffer {
    final func makeSampleBuffer(_ when: AVAudioTime) -> CMSampleBuffer? {
        var status: OSStatus = noErr
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: Int(frameLength),
            presentationTimeStamp: when.makeTime(),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else {
            logger.warn("CMAudioSampleBufferCreateWithPacketDescriptions returned error: ", status)
            return nil
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        )
        if status != noErr {
            logger.warn("CMSampleBufferSetDataBufferFromAudioBufferList returned error: ", status)
        }
        return sampleBuffer
    }

    @discardableResult
    @inlinable
    final func copy(_ audioBuffer: AVAudioBuffer) -> Bool {
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer, frameLength == audioBuffer.frameLength else {
            return false
        }
        let numSamples = Int(frameLength)
        if format.isInterleaved {
            let channelCount = Int(format.channelCount)
            switch format.commonFormat {
            case .pcmFormatInt16:
                memcpy(int16ChannelData?[0], audioBuffer.int16ChannelData?[0], numSamples * channelCount * 2)
            case .pcmFormatInt32:
                memcpy(int32ChannelData?[0], audioBuffer.int32ChannelData?[0], numSamples * channelCount * 4)
            case .pcmFormatFloat32:
                memcpy(floatChannelData?[0], audioBuffer.floatChannelData?[0], numSamples * channelCount * 4)
            default:
                break
            }
        } else {
            for i in 0..<Int(format.channelCount) {
                switch format.commonFormat {
                case .pcmFormatInt16:
                    memcpy(int16ChannelData?[i], audioBuffer.int16ChannelData?[i], numSamples * 2)
                case .pcmFormatInt32:
                    memcpy(int32ChannelData?[i], audioBuffer.int32ChannelData?[i], numSamples * 4)
                case .pcmFormatFloat32:
                    memcpy(floatChannelData?[i], audioBuffer.floatChannelData?[i], numSamples * 4)
                default:
                    break
                }
            }
        }
        return true
    }

    final func clone() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        buffer.frameLength = frameLength
        buffer.copy(self)
        return buffer
    }

    /// CN-VOL-1: multiplies every sample by `value` in place, clamped at full
    /// scale (no Int16 wrap like the Android version guards against). Unity 
    /// (1.0) or non-finite values are fast no-op returns so golden sessions
    /// stay byte-identical. Chain order at the mixer site is gain THEN mute,
    /// so mute always wins (scaled silence is still silence).
    @discardableResult
    @inlinable
    final func gain(_ value: Float) -> AVAudioPCMBuffer {
        guard value != 1.0, value.isFinite else {
            return self
        }
        @inline(__always) func scaleInt16(_ sample: Int16) -> Int16 {
            let scaled = Double(sample) * Double(value)
            if scaled >= 32767.0 { return Int16.max }
            if scaled <= -32768.0 { return Int16.min }
            return Int16(scaled.rounded(.toNearestOrAwayFromZero))
        }
        @inline(__always) func scaleInt32(_ sample: Int32) -> Int32 {
            let scaled = Double(sample) * Double(value)
            if scaled >= Double(Int32.max) { return Int32.max }
            if scaled <= Double(Int32.min) { return Int32.min }
            return Int32(scaled.rounded(.toNearestOrAwayFromZero))
        }
        @inline(__always) func scaleFloat32(_ sample: Float) -> Float {
            max(-1.0, min(1.0, sample * value))
        }
        let numSamples = Int(frameLength)
        if format.isInterleaved {
            let channelCount = Int(format.channelCount)
            switch format.commonFormat {
            case .pcmFormatInt16:
                int16ChannelData?[0].withMemoryRebound(to: Int16.self, capacity: numSamples * channelCount) { samples in
                    for i in 0..<numSamples * channelCount {
                        samples[i] = scaleInt16(samples[i])
                    }
                }
            case .pcmFormatInt32:
                int32ChannelData?[0].withMemoryRebound(to: Int32.self, capacity: numSamples * channelCount) { samples in
                    for i in 0..<numSamples * channelCount {
                        samples[i] = scaleInt32(samples[i])
                    }
                }
            case .pcmFormatFloat32:
                if let data = floatChannelData?[0] {
                    for i in 0..<numSamples * channelCount {
                        data[i] = scaleFloat32(data[i])
                    }
                }
            default:
                break
            }
        } else {
            for ch in 0..<Int(format.channelCount) {
                switch format.commonFormat {
                case .pcmFormatInt16:
                    int16ChannelData?[ch].withMemoryRebound(to: Int16.self, capacity: numSamples) { samples in
                        for i in 0..<numSamples {
                            samples[i] = scaleInt16(samples[i])
                        }
                    }
                case .pcmFormatInt32:
                    int32ChannelData?[ch].withMemoryRebound(to: Int32.self, capacity: numSamples) { samples in
                        for i in 0..<numSamples {
                            samples[i] = scaleInt32(samples[i])
                        }
                    }
                case .pcmFormatFloat32:
                    if let data = floatChannelData?[ch] {
                        for i in 0..<numSamples {
                            data[i] = scaleFloat32(data[i])
                        }
                    }
                default:
                    break
                }
            }
        }
        return self
    }

    @discardableResult
    @inlinable
    final func muted(_ isMuted: Bool) -> AVAudioPCMBuffer {
        guard isMuted else {
            return self
        }
        let numSamples = Int(frameLength)
        if format.isInterleaved {
            let channelCount = Int(format.channelCount)
            switch format.commonFormat {
            case .pcmFormatInt16:
                int16ChannelData?[0].update(repeating: 0, count: numSamples * channelCount)
            case .pcmFormatInt32:
                int32ChannelData?[0].update(repeating: 0, count: numSamples * channelCount)
            case .pcmFormatFloat32:
                floatChannelData?[0].update(repeating: 0, count: numSamples * channelCount)
            default:
                break
            }
        } else {
            for i in 0..<Int(format.channelCount) {
                switch format.commonFormat {
                case .pcmFormatInt16:
                    int16ChannelData?[i].update(repeating: 0, count: numSamples)
                case .pcmFormatInt32:
                    int32ChannelData?[i].update(repeating: 0, count: numSamples)
                case .pcmFormatFloat32:
                    floatChannelData?[i].update(repeating: 0, count: numSamples)
                default:
                    break
                }
            }
        }
        return self
    }
}