import Foundation
import VideoToolbox
import CoreVideo
import AudioToolbox

// [Previous code remains the same until the audio decoding section]

class MediaDecoder {
    // [Previous properties remain the same]
    
    // Audio processing properties
    private var audioBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var currentAudioPTS: CMTime = .zero
    private let audioBufferQueue = DispatchQueue(label: "com.telegram.mediaplayer.audiobuffer")
    private var pendingAudioSamples: [CMSampleBuffer] = []
    
    // Audio buffer management
    private struct AudioBufferContext {
        var data: UnsafeMutableRawPointer
        var size: UInt32
        var packetDesc: UnsafeMutablePointer<AudioStreamPacketDescription>?
        var currentPacket: UInt32
        var numPackets: UInt32
    }
    
    // [Previous methods remain the same until audio configuration]
    
    func configureAudioDecoder(format: AudioStreamBasicDescription) throws {
        audioFormat = format
        
        // Configure output format for decoded PCM audio
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // Create audio converter
        var audioConverterRef: AudioConverterRef?
        let status = AudioConverterNew(&format, &outputFormat, &audioConverterRef)
        
        guard status == noErr, let converter = audioConverterRef else {
            throw MediaDecoderError.decoderCreationFailed
        }
        
        audioConverter = converter
        
        // Allocate audio buffer list
        let channelCount = Int(format.mChannelsPerFrame)
        let size = UInt32(MemoryLayout<AudioBufferList>.stride + (channelCount - 1) * MemoryLayout<AudioBuffer>.stride)
        audioBufferList = .allocate(capacity: Int(size))
        audioBufferList?.pointee.mNumberBuffers = format.mChannelsPerFrame
        
        // Initialize audio buffers
        for i in 0..<channelCount {
            audioBufferList?.pointee.mBuffers[i].mNumberChannels = 1
            audioBufferList?.pointee.mBuffers[i].mDataByteSize = audioBufferSize
            audioBufferList?.pointee.mBuffers[i].mData = malloc(Int(audioBufferSize))
        }
    }
    
    func decodeAudioSample(_ sampleBuffer: CMSampleBuffer) {
        audioBufferQueue.async { [weak self] in
            guard let self = self,
                  let converter = self.audioConverter,
                  let format = self.audioFormat,
                  let bufferList = self.audioBufferList else {
                return
            }
            
            // Get audio data from sample buffer
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                self.delegate?.decoder(self, didEncounterError: MediaDecoderError.decodingFailed("Invalid audio data"))
                return
            }
            
            var lengthAtOffset: Int = 0
            var totalLength: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            
            guard status == noErr, let audioData = dataPointer else {
                self.delegate?.decoder(self, didEncounterError: MediaDecoderError.decodingFailed("Failed to get audio data"))
                return
            }
            
            // Prepare audio buffer context
            var context = AudioBufferContext(
                data: UnsafeMutableRawPointer(audioData),
                size: UInt32(totalLength),
                packetDesc: nil,
                currentPacket: 0,
                numPackets: UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
            )
            
            // Setup audio converter callback
            let inputDataProc: AudioConverterComplexInputDataProc = { (
                _: AudioConverterRef,
                packetCount: UnsafeMutablePointer<UInt32>,
                ioData: UnsafeMutablePointer<AudioBufferList>,
                packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                context: UnsafeMutableRawPointer?
            ) -> OSStatus in
                guard let contextData = context else {
                    return -1
                }
                
                let bufferContext = contextData.load(as: AudioBufferContext.self)
                
                if bufferContext.currentPacket >= bufferContext.numPackets {
                    packetCount.pointee = 0
                    return -1
                }
                
                ioData.pointee.mBuffers[0].mData = bufferContext.data
                ioData.pointee.mBuffers[0].mDataByteSize = bufferContext.size
                packetCount.pointee = bufferContext.numPackets
                
                return noErr
            }
            
            // Perform audio conversion
            var outputPacketCount: UInt32 = context.numPackets
            let convertStatus = AudioConverterFillComplexBuffer(
                converter,
                inputDataProc,
                &context,
                &outputPacketCount,
                bufferList,
                nil
            )
            
            guard convertStatus == noErr else {
                self.delegate?.decoder(self, didEncounterError: MediaDecoderError.decodingFailed("Audio conversion failed"))
                return
            }
            
            // Create audio sample buffer with decoded PCM data
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            )
            
            var formatDescription: CMFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &format,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            
            guard let audioFormat = formatDescription else {
                self.delegate?.decoder(self, didEncounterError: MediaDecoderError.formatDescriptionCreationFailed)
                return
            }
            
            var decodedSampleBuffer: CMSampleBuffer?
            let createStatus = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: audioFormat,
                sampleCount: CMItemCount(outputPacketCount),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &decodedSampleBuffer
            )
            
            guard createStatus == noErr,
                  let outputSampleBuffer = decodedSampleBuffer else {
                self.delegate?.decoder(self, didEncounterError: MediaDecoderError.decodingFailed("Failed to create output sample buffer"))
                return
            }
            
            // Set the decoded audio data
            let audioBlockBufferStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
                outputSampleBuffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: bufferList.pointee
            )
            
            guard audioBlockBufferStatus == noErr else {
                self.delegate?.decoder(self, didEncounterError: MediaDecoderError.decodingFailed("Failed to set audio data"))
                return
            }
            
            // Notify delegate of decoded audio
            self.delegate?.decoder(self, didOutputAudioSample: outputSampleBuffer)
        }
    }
    
    // Clean up audio resources
    private func cleanupAudioResources() {
        if let bufferList = audioBufferList {
            for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
                if let data = bufferList.pointee.mBuffers[i].mData {
                    free(data)
                }
            }
            audioBufferList?.deallocate()
            audioBufferList = nil
        }
    }
    
    // Update deinit to include audio cleanup
    deinit {
        destroyDecoders()
        cleanupAudioResources()
    }
}
