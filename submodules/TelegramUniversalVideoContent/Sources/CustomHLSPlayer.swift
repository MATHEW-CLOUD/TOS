import Foundation
import UIKit
import SwiftSignalKit
import UniversalMediaPlayer
import CoreMedia
import AVFoundation

public final class HLSVideoContent: NSObject, UniversalVideoContent {
    private let url: String
    private let id: AnyHashable
    private var status: Signal<MediaPlayerStatus, NoError>
    
    private var streamManager: HLSStreamManager?
    private var qualityController: HLSQualityController?
    
    public init(url: String, id: AnyHashable) {
        self.url = url
        self.id = id
        self.status = .single(.loading)
        
        super.init()
        
        setupPlayer()
    }
    
    private func setupPlayer() {
        // Initialize our custom HLS player components
        self.streamManager = HLSStreamManager(url: url)
        self.qualityController = HLSQualityController(delegate: self)
    }
    
    // MARK: - UniversalVideoContent Protocol
    
    public func status() -> Signal<MediaPlayerStatus, NoError> {
        return self.status
    }
    
    public func start() {
        streamManager?.startPlayback()
    }
    
    public func pause() {
        streamManager?.pausePlayback()
    }
    
    public func seek(_ position: Double) {
        streamManager?.seek(to: position)
    }
    
    public func setBaseRate(_ rate: Double) {
        streamManager?.setPlaybackRate(rate)
    }
}

// MARK: - HLSQualityControllerDelegate
extension HLSVideoContent: HLSQualityControllerDelegate {
    func qualityDidChange(_ quality: HLSStreamQuality) {
        // Handle quality change
        streamManager?.switchToQuality(quality)
    }
}// First, let's add these new structures for segment management
struct SegmentDownloadInfo {
    let segment: MediaSegment
    let data: Data
    let downloadTime: TimeInterval
    let byteSize: Int
}

enum SegmentDownloadError: Error {
    case invalidResponse
    case downloadFailed
    case cancelled
    case bufferFull
    case networkError(Error)
}

// Add these properties to the HLSStreamParser class:
private let downloadQueue = OperationQueue()
private let maxConcurrentDownloads = 3
private var downloadedSegments: [Int: SegmentDownloadInfo] = [:]
private let maxBufferDuration: TimeInterval = 30.0 // Maximum buffer size in seconds
private var activeDownloads: [Int: URLSessionDataTask] = [:]
private var downloadSemaphore: DispatchSemaphore
private let downloadSession: URLSession

// Add these methods to the HLSStreamParser class:

private func setupDownloadManager() {
    downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads
    downloadSemaphore = DispatchSemaphore(value: maxConcurrentDownloads)
    
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    downloadSession = URLSession(configuration: configuration)
}

/// Start downloading segments from a specific sequence
func startDownloadingSegments(fromSequence sequence: Int) {
    let segments = getSegments(fromSequence: sequence)
    
    for segment in segments {
        downloadQueue.addOperation { [weak self] in
            guard let self = self else { return }
            
            // Wait for semaphore
            self.downloadSemaphore.wait()
            
            Task {
                do {
                    let downloadInfo = try await self.downloadSegment(segment)
                    await self.handleDownloadedSegment(downloadInfo)
                } catch {
                    await self.handleDownloadError(error, forSegment: segment)
                }
                
                self.downloadSemaphore.signal()
            }
        }
    }
}

/// Download a single segment
private func downloadSegment(_ segment: MediaSegment) async throws -> SegmentDownloadInfo {
    let startTime = CACurrentMediaTime()
    
    // Check if we're exceeding buffer size
    let currentBufferDuration = calculateBufferDuration()
    guard currentBufferDuration < maxBufferDuration else {
        throw SegmentDownloadError.bufferFull
    }
    
    var request = URLRequest(url: segment.uri)
    if let byteRange = segment.byteRange {
        request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    
    let (data, response) = try await downloadSession.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw SegmentDownloadError.invalidResponse
    }
    
    let downloadTime = CACurrentMediaTime() - startTime
    
    return SegmentDownloadInfo(
        segment: segment,
        data: data,
        downloadTime: downloadTime,
        byteSize: data.count
    )
}

/// Handle successfully downloaded segment
private func handleDownloadedSegment(_ downloadInfo: SegmentDownloadInfo) async {
    // Store the downloaded segment
    downloadedSegments[downloadInfo.segment.sequence] = downloadInfo
    
    // Clean up old segments
    cleanupOldSegments()
    
    // Notify delegate about the new segment
    delegate?.streamParser(
        self,
        didDownloadSegment: downloadInfo.segment,
        data: downloadInfo.data
    )
}

/// Handle download errors
private func handleDownloadError(_ error: Error, forSegment segment: MediaSegment) async {
    if let error = error as? SegmentDownloadError {
        switch error {
        case .bufferFull:
            // Retry after a delay
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            Task {
                _ = try? await downloadSegment(segment)
            }
        default:
            delegate?.streamParser(self, didFailToDownloadSegment: segment, withError: error)
        }
    } else {
        delegate?.streamParser(self, didFailToDownloadSegment: segment, withError: SegmentDownloadError.networkError(error))
    }
}

/// Calculate current buffer duration
private func calculateBufferDuration() -> TimeInterval {
    downloadedSegments.values.reduce(0) { $0 + $1.segment.duration }
}

/// Clean up old segments to maintain buffer size
private func cleanupOldSegments() {
    let sortedSegments = downloadedSegments.sorted { $0.key < $1.key }
    var currentDuration: TimeInterval = 0
    
    for (sequence, info) in sortedSegments.reversed() {
        currentDuration += info.segment.duration
        if currentDuration > maxBufferDuration {
            downloadedSegments.removeValue(forKey: sequence)
        }
    }
}

/// Cancel all active downloads
func cancelDownloads() {
    downloadQueue.cancelAllOperations()
    activeDownloads.values.forEach { $0.cancel() }
    activeDownloads.removeAll()
}

/// Get downloaded segment data
func getSegmentData(forSequence sequence: Int) -> Data? {
    downloadedSegments[sequence]?.data
}

/// Update delegate protocol with new methods
protocol HLSStreamParserDelegate: AnyObject {
    func streamParser(_ parser: HLSStreamParser, didUpdateSegments segments: [MediaSegment])
    func streamParser(_ parser: HLSStreamParser, didFailWithError error: Error)
    func streamParser(_ parser: HLSStreamParser, didDownloadSegment segment: MediaSegment, data: Data)
    func streamParser(_ parser: HLSStreamParser, didFailToDownloadSegment segment: MediaSegment, withError error: Error)
    func streamParser(_ parser: HLSStreamParser, didUpdateBufferDuration duration: TimeInterval)
}

/// Add buffer management methods
extension HLSStreamParser {
    /// Get current buffer status
    var bufferStatus: (duration: TimeInterval, segments: Int) {
        (calculateBufferDuration(), downloadedSegments.count)
    }
    
    /// Check if we have enough buffer
    var hasAdequateBuffer: Bool {
        calculateBufferDuration() >= targetDuration * 3
    }
    
    /// Get downloaded segment info
    func getDownloadInfo(forSequence sequence: Int) -> SegmentDownloadInfo? {
        downloadedSegments[sequence]
    }
    
    /// Prefetch segments
    func prefetchSegments(count: Int) {
        guard let lastSegment = downloadedSegments.values.map({ $0.segment }).max(by: { $0.sequence < $1.sequence }) else {
            return
        }
        
        startDownloadingSegments(fromSequence: lastSegment.sequence + 1)
    }
}// MARK: - HLSStreamQuality
enum HLSStreamQuality {
    case auto
    case low // 240p
    case medium // 480p
    case high // 720p
    case hd // 1080p
    
    var resolution: (width: Int, height: Int) {
        switch self {
        case .auto: return (0, 0) // Dynamic
        case .low: return (426, 240)
        case .medium: return (854, 480)
        case .high: return (1280, 720)
        case .hd: return (1920, 1080)
        }
    }
}

class HLSStreamManager: NSObject {
    private let url: String
    private var videoDecoder: VideoDecoder?
    private var audioDecoder: AudioDecoder?
    private var demuxer: HLSDemuxer?
    private var currentQuality: HLSStreamQuality = .auto
    
    private var isPlaying: Bool = false
    private var currentPosition: Double = 0
    private var playbackRate: Double = 1.0
    
    // Bandwidth monitoring
    private var bandwidthMonitor: BandwidthMonitor?
    private let qualityAdjustmentQueue = DispatchQueue(label: "com.telegram.hls.quality")
    
    init(url: String) {
        self.url = url
        super.init()
        setupDecoders()
        setupBandwidthMonitoring()
    }
    
    private func setupDecoders() {
        videoDecoder = VideoDecoder()
        audioDecoder = AudioDecoder()
        demuxer = HLSDemuxer(url: url)
        
        // Setup decoder callbacks
        videoDecoder?.onFrameDecoded = { [weak self] frame in
            self?.handleDecodedVideoFrame(frame)
        }
        
        audioDecoder?.onSampleDecoded = { [weak self] sample in
            self?.handleDecodedAudioSample(sample)
        }
    }
    
    private func setupBandwidthMonitoring() {
        bandwidthMonitor = BandwidthMonitor()
        bandwidthMonitor?.onBandwidthUpdate = { [weak self] bandwidth in
            self?.handleBandwidthUpdate(bandwidth)
        }
    }
    
    private func handleBandwidthUpdate(_ bandwidth: Double) {
        guard currentQuality == .auto else { return }
        
        qualityAdjustmentQueue.async { [weak self] in
            // Calculate optimal quality based on available bandwidth
            let optimalQuality = self?.calculateOptimalQuality(for: bandwidth)
            if let quality = optimalQuality {
                DispatchQueue.main.async {
                    self?.switchToQuality(quality)
                }
            }
        }
    }
    
    private func calculateOptimalQuality(for bandwidth: Double) -> HLSStreamQuality {
        // Bandwidth thresholds in bits per second
        let hdThreshold: Double = 5_000_000 // 5 Mbps
        let highThreshold: Double = 2_500_000 // 2.5 Mbps
        let mediumThreshold: Double = 1_000_000 // 1 Mbps
        
        switch bandwidth {
        case _ where bandwidth >= hdThreshold:
            return .hd
        case _ where bandwidth >= highThreshold:
            return .high
        case _ where bandwidth >= mediumThreshold:
            return .medium
        default:
            return .low
        }
    }
    
    // MARK: - Public Methods
    
    func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        
        demuxer?.start { [weak self] packets in
            self?.processPackets(packets)
        }
    }
    
    func pausePlayback() {
        isPlaying = false
        demuxer?.pause()
    }
    
    func seek(to position: Double) {
        currentPosition = position
        demuxer?.seek(to: position) { [weak self] in
            self?.videoDecoder?.flush()
            self?.audioDecoder?.flush()
        }
    }
    
    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        videoDecoder?.setPlaybackRate(rate)
        audioDecoder?.setPlaybackRate(rate)
    }
    
    func switchToQuality(_ quality: HLSStreamQuality) {
        guard quality != currentQuality else { return }
        currentQuality = quality
        
        // Store current position for seamless switch
        let position = currentPosition
        
        // Recreate demuxer with new quality settings
        demuxer = HLSDemuxer(url: url, preferredQuality: quality)
        
        // Seek to previous position
        seek(to: position)
    }
}// Continue from previous VideoDecoder class...
    
    private func createDecompressionSession(formatDescription: CMVideoFormatDescription) {
        // Store format description
        self.formatDescription = formatDescription
        
        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]
        
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as [String: Any]
        
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallbackFunc,
            decompressionOutputRefCon: unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        )
        
        // Create decompression session
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        if status == noErr {
            decompressionSession = session
        } else {
            print("Failed to create decompression session: \(status)")
        }
    }
    
    // Handle incoming H264 NAL units
    func decode(nalUnits: [Data], presentationTime: CMTime) {
        guard let formatDescription = createFormatDescription(from: nalUnits) else {
            print("Failed to create format description")
            return
        }
        
        // Create new session if format changed
        if self.formatDescription == nil || !CMFormatDescriptionEqual(self.formatDescription!, formatDescription) {
            createDecompressionSession(formatDescription: formatDescription)
        }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), // Adjust based on actual frame rate
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: presentationTime
        )
        
        // Create block buffer from NAL units
        var blockBuffer: CMBlockBuffer?
        let concatenatedData = nalUnits.reduce(Data()) { $0 + $1 }
        
        let status = concatenatedData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: concatenatedData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: concatenatedData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        if status == noErr, let blockBuffer = blockBuffer {
            // Create sample buffer
            let sampleStatus = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
            
            if sampleStatus == noErr, let sampleBuffer = sampleBuffer {
                decodeSampleBuffer(sampleBuffer)
            }
        }
    }
    
    private func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let session = decompressionSession else { return }
        
        let decodeFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        let frameRefCon = UnsafeMutableRawPointer(bitPattern: 0)
        
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefCon: frameRefCon,
            infoFlagsOut: nil
        )
    }
    
    private func handleDecodedFrame(_ frame: VideoFrame) {
        // Apply playback rate if needed
        let adjustedTime = CMTimeMultiplyByFloat64(frame.presentationTime, multiplier: playbackRate)
        
        let adjustedFrame = VideoFrame(
            buffer: frame.buffer,
            presentationTime: adjustedTime,
            duration: frame.duration
        )
        
        // Notify delegate on main thread
        DispatchQueue.main.async { [weak self] in
            self?.onFrameDecoded?(adjustedFrame)
        }
    }
    
    // Clean up resources
    func flush() {
        VTDecompressionSessionInvalidate(decompressionSession!)
        decompressionSession = nil
        formatDescription = nil
        setupDecompressionSession()
    }// MARK: - VideoFrame
struct VideoFrame {
    let buffer: CVPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
}

class VideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    var onFrameDecoded: ((VideoFrame) -> Void)?
    private var playbackRate: Double = 1.0
    
    init() {
        setupDecompressionSession()
    }
    
    private func setupDecompressionSession() {
        // Create video decompression session attributes
        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]
        
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        // Callback for decompressed frames
        let decompressionOutputCallback: VTDecompressionOutputCallback = { decompressionOutputRefCon, _, status, flags, buffer, presentationTimeStamp, duration in
            guard let decoder = unsafeBitCast(decompressionOutputRefCon, to: VideoDecoder.self) else {
                return kVTInvalidSessionErr
            }
            
            if status == noErr {
                if let buffer = buffer {
                    let frame = VideoFrame(
                        buffer: buffer,
                        presentationTime: presentationTimeStamp,
                        duration: duration
                    )
                    decoder.handleDecodedFrame(frame)
                }
            }
            
            return status
        }
        
        // Create output callback record
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        )
        
        // We'll continue with the actual session creation in the next part...// Continue in VideoDecoder class...
    
    private func createFormatDescription(from nalUnits: [Data]) -> CMVideoFormatDescription? {
        // Find SPS and PPS NAL units
        var sps: Data?
        var pps: Data?
        
        for nalUnit in nalUnits {
            guard nalUnit.count > 4 else { continue }
            
            // Get NAL unit type from first byte after start code
            let naluType = nalUnit[4] & 0x1F
            
            switch naluType {
            case 7: // SPS
                sps = nalUnit
            case 8: // PPS
                pps = nalUnit
            default:
                break
            }
        }
        
        guard let spsData = sps, let ppsData = pps else {
            return nil
        }
        
        // Create parameter sets
        var parameterSets: [Data] = []
        parameterSets.append(spsData)
        parameterSets.append(ppsData)
        
        // Convert to format description
        let parameterSetPointers = parameterSets.map { (data: Data) -> UnsafePointer<UInt8> in
            return data.withUnsafeBytes { pointer in
                return pointer.bindMemory(to: UInt8.self).baseAddress!
            }
        }
        
        let parameterSetSizes = parameterSets.map { UInt($0.count) }
        var formatDescription: CMFormatDescription?
        
        // Create format description from SPS and PPS
        let status = parameterSetPointers.withUnsafeBufferPointer { parameterSetPointersPtr in
            return parameterSetSizes.withUnsafeBufferPointer { parameterSetSizesPtr in
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointersPtr.baseAddress!,
                    parameterSetSizes: parameterSetSizesPtr.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        
        guard status == noErr else {
            print("Failed to create format description: \(status)")
            return nil
        }
        
        return formatDescription
    }
    
    // MARK: - Buffer Management
    
    private var pixelBufferPool: CVPixelBufferPool?
    private let bufferQueue = DispatchQueue(label: "com.telegram.videodecoder.buffer")
    private let maxBufferCount = 3
    private var availableBuffers: [CVPixelBuffer] = []
    
    private func setupPixelBufferPool(width: Int, height: Int) {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: maxBufferCount
        ]
        
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        )
        
        if status == kCVReturnSuccess {
            pixelBufferPool = pool
            preallocateBuffers()
        }
    }
    
    private func preallocateBuffers() {
        guard let pool = pixelBufferPool else { return }
        
        bufferQueue.sync {
            for _ in 0..<maxBufferCount {
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                )
                
                if status == kCVReturnSuccess, let buffer = pixelBuffer {
                    availableBuffers.append(buffer)
                }
            }
        }
    }
    
    private func requestBuffer() -> CVPixelBuffer? {
        return bufferQueue.sync {
            return availableBuffers.isEmpty ? nil : availableBuffers.removeLast()
        }
    }
    
    private func recycleBuffer(_ buffer: CVPixelBuffer) {
        bufferQueue.async {
            if self.availableBuffers.count < self.maxBufferCount {
                self.availableBuffers.append(buffer)
            }
        }
    }
    
    // MARK: - Playback Rate Control
    
    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
    }
    
    // MARK: - Cleanup
    
    deinit {
        flush()
        pixelBufferPool = nil
        availableBuffers.removeAll()
    }// MARK: - AudioSample
struct AudioSample {
    let data: Data
    let presentationTime: CMTime
    let duration: CMTime
    let format: AudioStreamBasicDescription
}

class AudioDecoder {
    private var audioConverter: AudioConverterRef?
    private var outputFormat: AudioStreamBasicDescription?
    private var inputFormat: AudioStreamBasicDescription?
    
    var onSampleDecoded: ((AudioSample) -> Void)?
    private var playbackRate: Double = 1.0
    
    // Audio buffer management
    private let bufferSize = 2048
    private var pendingBuffers: [Data] = []
    private let bufferQueue = DispatchQueue(label: "com.telegram.audiodecoder.buffer")
    
    // Audio engine components
    private let audioQueue: AudioQueueRef? = nil
    private var currentPTS: CMTime = .zero
    
    init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    func setupDecoder(with streamInfo: AudioStreamBasicDescription) {
        // Store input format
        inputFormat = streamInfo
        
        // Setup output format for decoded PCM audio
        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: streamInfo.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: streamInfo.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        self.outputFormat = outputDesc
        
        // Create audio converter
        var inDesc = streamInfo
        var outDesc = outputDesc
        
        let status = AudioConverterNew(&inDesc, &outDesc, &audioConverter)
        guard status == noErr else {
            print("Failed to create audio converter: \(status)")
            return
        }
        
        // Setup audio queue for playback
        setupAudioQueue(with: outputDesc)
    }
    
    private func setupAudioQueue(with format: AudioStreamBasicDescription) {
        var callbackStruct = AudioQueueOutputCallback(
            userData: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            inputProc: { userData, queue, buffer in
                let decoder = Unmanaged<AudioDecoder>.fromOpaque(userData!).takeUnretainedValue()
                decoder.handleAudioQueueBuffer(queue, buffer: buffer)
            }
        )
        
        var status = AudioQueueNewOutput(
            &format,
            &callbackStruct.inputProc,
            callbackStruct.userData,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue,
            0,
            &audioQueue
        )
        
        guard status == noErr else {
            print("Failed to create audio queue: \(status)")
            return
        }
        
        // Allocate audio queue buffers
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(audioQueue!, UInt32(bufferSize), &buffer)
            if status == noErr, let buffer = buffer {
                handleAudioQueueBuffer(audioQueue!, buffer: buffer)
            }
        }
        
        AudioQueueStart(audioQueue!, nil)
    }
    
    func decode(data: Data, presentationTime: CMTime) {
        bufferQueue.async { [weak self] in
            self?.pendingBuffers.append(data)
            self?.processNextBuffer(presentationTime: presentationTime)
        }
    }
    
    private func processNextBuffer(presentationTime: CMTime) {
        guard let converter = audioConverter,
              let outputFormat = outputFormat,
              !pendingBuffers.isEmpty else { return }
        
        let inputData = pendingBuffers.removeFirst()
        var inputDataSize = UInt32(inputData.count)
        var outputBufferSize = UInt32(bufferSize)
        var outputBuffer = Data(count: bufferSize)
        
        // Setup converter callbacks
        var callbacks = AudioConverterCallbacks(
            userData: UnsafeMutableRawPointer(mutating: inputData.withUnsafeBytes { pointer in
                return pointer.baseAddress
            }),
            inputDataProc: { (converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                // Handle input data reading
                return noErr
            },
            inputDataProcUserData: nil
        )
        
        var outputPacketDescription = AudioStreamPacketDescription()
        var status = AudioConverterFillComplexBuffer(
            converter,
            callbacks.inputDataProc,
            &callbacks,
            &outputBufferSize,
            &outputBuffer,
            &outputPacketDescription
        )
        
        if status == noErr {
            let sample = AudioSample(
                data: outputBuffer,
                presentationTime: presentationTime,
                duration: CMTime(value: 1, timescale: Int32(outputFormat.mSampleRate)),
                format: outputFormat
            )
            
            DispatchQueue.main.async { [weak self] in
                self?.onSampleDecoded?(sample)
            }
        }
    }
    
    private func handleAudioQueueBuffer(_ queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        // Fill buffer with decoded audio data
        if let nextSample = getNextSample() {
            let bufferSize = min(Int(buffer.pointee.mAudioDataBytesCapacity), nextSample.data.count)
            nextSample.data.withUnsafeBytes { pointer in
                buffer.pointee.mAudioData.copyMemory(from: pointer.baseAddress!, byteCount: bufferSize)
            }
            buffer.pointee.mAudioDataByteSize = UInt32(bufferSize)
            
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }// MARK: - MediaSynchronizer
class MediaSynchronizer {
    private var videoTimestamp: CMTime = .zero
    private var audioTimestamp: CMTime = .zero
    private let maxDrift: Double = 0.1 // 100ms maximum drift
    
    private let syncQueue = DispatchQueue(label: "com.telegram.mediasync")
    private var isFirstFrame = true
    private var startTime: CMTime = .zero
    
    func synchronize(videoFrame: VideoFrame, completion: @escaping (VideoFrame) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.isFirstFrame {
                self.startTime = CMClockGetTime(CMClockGetHostTimeClock())
                self.isFirstFrame = false
            }
            
            self.videoTimestamp = videoFrame.presentationTime
            let delay = self.calculateDelay(for: self.videoTimestamp)
            
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            
            DispatchQueue.main.async {
                completion(videoFrame)
            }
        }
    }
    
    func synchronize(audioSample: AudioSample, completion: @escaping (AudioSample) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.audioTimestamp = audioSample.presentationTime
            let drift = CMTimeGetSeconds(self.videoTimestamp) - CMTimeGetSeconds(self.audioTimestamp)
            
            if abs(drift) > self.maxDrift {
                // Adjust audio timing if drift is too large
                let adjustedTime = CMTimeAdd(audioSample.presentationTime, CMTimeMakeWithSeconds(drift, preferredTimescale: 1000))
                let adjustedSample = AudioSample(
                    data: audioSample.data,
                    presentationTime: adjustedTime,
                    duration: audioSample.duration,
                    format: audioSample.format
                )
                
                DispatchQueue.main.async {
                    completion(adjustedSample)
                }
            } else {
                DispatchQueue.main.async {
                    completion(audioSample)
                }
            }
        }
    }
    
    private func calculateDelay(for timestamp: CMTime) -> Double {
        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())
        let elapsedTime = CMTimeGetSeconds(CMTimeSubtract(currentTime, startTime))
        let targetTime = CMTimeGetSeconds(timestamp)
        return max(0, targetTime - elapsedTime)
    }
}

// MARK: - HLSDemuxer
class HLSDemuxer {
    private let url: String
    private let preferredQuality: HLSStreamQuality
    private var playlist: HLSPlaylist?
    private var currentSegment: Int = 0
    private var isRunning = false
    
    private let downloadQueue = DispatchQueue(label: "com.telegram.hls.download")
    private let parseQueue = DispatchQueue(label: "com.telegram.hls.parse")
    
    var onVideoPacket: ((Data, CMTime) -> Void)?
    var onAudioPacket: ((Data, CMTime) -> Void)?
    
    struct HLSPlaylist {
        let segments: [HLSSegment]
        let targetDuration: Double
        let sequences: [HLSSequence]
    }
    
    struct HLSSegment {
        let url: String
        let duration: Double
        let sequence: Int
    }
    
    struct HLSSequence {
        let bandwidth: Int
        let resolution: String
        let playlistURL: String
    }
    
    init(url: String, preferredQuality: HLSStreamQuality = .auto) {
        self.url = url
        self.preferredQuality = preferredQuality
        loadPlaylist()
    }
    
    private func loadPlaylist() {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Download master playlist
            guard let masterData = self.downloadData(from: self.url) else {
                print("Failed to download master playlist")
                return
            }
            
            // Parse master playlist
            self.parseQueue.async {
                self.parseMasterPlaylist(data: masterData)
            }
        }
    }
    
    private func parseMasterPlaylist(data: Data) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        
        var sequences: [HLSSequence] = []
        var currentBandwidth: Int = 0
        var currentResolution: String = ""
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // Parse stream information
                let attributes = line.dropFirst(18).components(separatedBy: ",")
                for attribute in attributes {
                    let parts = attribute.components(separatedBy: "=")
                    if parts.count == 2 {
                        switch parts[0].trimmingCharacters(in: .whitespaces) {
                        case "BANDWIDTH":
                            currentBandwidth = Int(parts[1]) ?? 0
                        case "RESOLUTION":
                            currentResolution = parts[1]
                        default:
                            break
                        }
                    }
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                // This is a playlist URL
                let sequence = HLSSequence(
                    bandwidth: currentBandwidth,
                    resolution: currentResolution,
                    playlistURL: line
                )
                sequences.append(sequence)
            }
        }
        
        // Select appropriate quality level
        selectQualityLevel(sequences)
    }
    
    private func selectQualityLevel(_ sequences: [HLSSequence]) {
        guard !sequences.isEmpty else { return }
        
        let selectedSequence: HLSSequence
        
        switch preferredQuality {
        case .auto:
            // Choose based on available bandwidth
            selectedSequence = sequences.sorted { $0.bandwidth < $1.bandwidth }[sequences.count / 2]
        case .low:
            selectedSequence = sequences.min { $0.bandwidth < $1.bandwidth } ?? sequences[0]
        case .high:
            selectedSequence = sequences.max { $0.bandwidth < $1.bandwidth } ?? sequences[0]
        default:
            // Choose closest to requested quality
            let targetResolution = preferredQuality.resolution
            selectedSequence = sequences.min {
                let res1 = parseResolution($0.resolution)
                let res2 = parseResolution($1.resolution)
                return abs(res1.height - targetResolution.height) < abs(res2.height - targetResolution.height)
            } ?? sequences[0]
        }
        
        // Load selected playlist
        loadMediaPlaylist(url: selectedSequence.playlistURL)
    }// Continue in HLSDemuxer class...
    
    private func loadMediaPlaylist(url: String) {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard let playlistData = self.downloadData(from: url) else {
                print("Failed to download media playlist")
                return
            }
            
            self.parseQueue.async {
                self.parseMediaPlaylist(data: playlistData, baseURL: url)
            }
        }
    }
    
    private func parseMediaPlaylist(data: Data, baseURL: String) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        
        var segments: [HLSSegment] = []
        var targetDuration: Double = 0
        var currentDuration: Double = 0
        var sequence = 0
        
        let lines = content.components(separatedBy: .newlines)
        let baseURLPath = (baseURL as NSString).deletingLastPathComponent
        
        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let durationString = line.dropFirst(8).components(separatedBy: ",")[0]
                currentDuration = Double(durationString) ?? 0
            } else if !line.hasPrefix("#") && !line.isEmpty {
                // This is a segment URL
                let absoluteURL: String
                if line.hasPrefix("http") {
                    absoluteURL = line
                } else {
                    absoluteURL = (baseURLPath as NSString).appendingPathComponent(line)
                }
                
                let segment = HLSSegment(
                    url: absoluteURL,
                    duration: currentDuration,
                    sequence: sequence
                )
                segments.append(segment)
                sequence += 1
            }
        }
        
        playlist = HLSPlaylist(
            segments: segments,
            targetDuration: targetDuration,
            sequences: []
        )
        
        // Start downloading segments if running
        if isRunning {
            downloadNextSegment()
        }
    }
    
    private func downloadNextSegment() {
        guard let playlist = playlist,
              currentSegment < playlist.segments.count else {
            return
        }
        
        let segment = playlist.segments[currentSegment]
        
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let segmentData = self.downloadData(from: segment.url) {
                self.parseQueue.async {
                    self.processSegment(data: segmentData, timestamp: CMTime(seconds: Double(self.currentSegment) * segment.duration, preferredTimescale: 1000))
                }
            }
            
            self.currentSegment += 1
            
            // Continue downloading if still running
            if self.isRunning {
                self.downloadNextSegment()
            }
        }
    }
    
    private func processSegment(data: Data, timestamp: CMTime) {
        // MPEG-TS packet size is 188 bytes
        let packetSize = 188
        var offset = 0
        
        while offset + packetSize <= data.count {
            let packetData = data.subdata(in: offset..<offset + packetSize)
            processMPEGTSPacket(packetData, timestamp: timestamp)
            offset += packetSize
        }
    }
    
    private func processMPEGTSPacket(_ data: Data, timestamp: CMTime) {
        // Parse MPEG-TS packet header
        guard data.count >= 4 else { return }
        
        let syncByte = data[0]
        guard syncByte == 0x47 else { return } // Valid MPEG-TS packet starts with 0x47
        
        let pid = ((UInt16(data[1] & 0x1F) << 8) | UInt16(data[2]))
        let adaptationFieldControl = (data[3] & 0x30) >> 4
        let hasPayload = adaptationFieldControl & 0x1 != 0
        let hasAdaptationField = adaptationFieldControl & 0x2 != 0
        
        var dataOffset = 4
        
        if hasAdaptationField {
            let adaptationFieldLength = Int(data[4])
            dataOffset += 1 + adaptationFieldLength
        }
        
        if hasPayload && dataOffset < data.count {
            let payload = data.subdata(in: dataOffset..<data.count)
            
            switch pid {
            case 0x100: // Video PID (example value, actual value from PMT)
                onVideoPacket?(payload, timestamp)
            case 0x101: // Audio PID (example value, actual value from PMT)
                onAudioPacket?(payload, timestamp)
            default:
                break
            }
        }
    }
    
    // MARK: - Utilities
    
    private func downloadData(from url: String) -> Data? {
        guard let url = URL(string: url) else { return nil }
        
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            result = data
            semaphore.signal()
        }
        
        task.resume()
        semaphore.wait()
        
        return result
    }
    
    private func parseResolution(_ resolution: String) -> (width: Int, height: Int) {
        let components = resolution.components(separatedBy: "x")
        guard components.count == 2,
              let width = Int(components[0]),
              let height = Int(components[1]) else {
            return (0, 0)
        }
        return (width, height)
    }
    
    // MARK: - Public Methods
    
    func start() {
        isRunning = true
        currentSegment = 0
        downloadNextSegment()
    }
    
    func pause() {
        isRunning = false
    }
    
    func seek(to time: Double) {
        guard let playlist = playlist else { return }
        
        var accumulator = 0.0
        for (index, segment) in playlist.segments.enumerated() {
            accumulator += segment.duration
            if accumulator >= time {
                currentSegment = index
                break
            }
        }
        
        if isRunning {
            downloadNextSegment()
        }
    }

protocol FallbackHandlerDelegate: AnyObject {
    func fallbackHandler(_ handler: FallbackHandler, didActivateFallbackToVariant variant: HLSVariant)
    func fallbackHandler(_ handler: FallbackHandler, didRecover: Bool)
    func fallbackHandler(_ handler: FallbackHandler, didUpdateStatus status: FallbackStatus)
}

class FallbackHandler {
    weak var delegate: FallbackHandlerDelegate?
    
    // Dependencies
    private let queueManager: HLSQueueManager
    private let streamSwitcher: StreamSwitchingManager
    private let qualityAdapter: QualityAdaptationManager
    
    // Configuration
    private let minBufferThreshold = CMTime(seconds: 4, preferredTimescale: 600)
    private let criticalBufferThreshold = CMTime(seconds: 2, preferredTimescale: 600)
    private let recoveryTimeout: TimeInterval = 15.0
    private let maxConsecutiveFallbacks = 3
    
    // State tracking
    private var isInFallbackMode = false
    private var fallbackStartTime: Date?
    private var consecutiveFallbacks = 0
    private var originalVariant: HLSVariant?
    private var lastStableVariant: HLSVariant?
    private var emergencyVariants: [HLSVariant] = []
    
    struct FallbackStatus {
        let isActive: Bool
        let currentBufferDuration: CMTime
        let consecutiveFallbacks: Int
        let timeInFallback: TimeInterval?
    }
    
    enum FallbackError: Error {
        case noFallbackVariantsAvailable
        case maxConsecutiveFallbacksReached
        case recoveryTimeout
        case criticalBufferUnderrun
    }
    
    init(queueManager: HLSQueueManager,
         streamSwitcher: StreamSwitchingManager,
         qualityAdapter: QualityAdaptationManager) {
        self.queueManager = queueManager
        self.streamSwitcher = streamSwitcher
        self.qualityAdapter = qualityAdapter
        
        setupMonitoring()
    }
    
    private func setupMonitoring() {
        // Start periodic buffer monitoring
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkBufferHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    
    func updateAvailableVariants(_ variants: [HLSVariant]) {
        // Sort variants by bandwidth for fallback selection
        emergencyVariants = variants.sorted { $0.bandwidth < $1.bandwidth }
    }
    
    private func checkBufferHealth() {
        guard let status = queueManager.currentBufferStatus else { return }
        
        let currentBuffer = min(status.videoBufferDuration, status.audioBufferDuration)
        
        // Update delegate with current status
        let fallbackStatus = FallbackStatus(
            isActive: isInFallbackMode,
            currentBufferDuration: currentBuffer,
            consecutiveFallbacks: consecutiveFallbacks,
            timeInFallback: fallbackStartTime.map { -$0.timeIntervalSinceNow }
        )
        delegate?.fallbackHandler(self, didUpdateStatus: fallbackStatus)
        
        if isInFallbackMode {
            handleFallbackModeStatus(currentBuffer)
        } else {
            checkForFallbackTrigger(currentBuffer)
        }
    }
    
    private func checkForFallbackTrigger(_ bufferDuration: CMTime) {
        if bufferDuration <= criticalBufferThreshold {
            do {
                try activateEmergencyFallback()
            } catch {
                handleFallbackError(error)
            }
        }
    }
    
    private func handleFallbackModeStatus(_ bufferDuration: CMTime) {
        // Check if we can recover
        if bufferDuration >= minBufferThreshold {
            attemptRecovery()
        }
        
        // Check for timeout
        if let startTime = fallbackStartTime,
           -startTime.timeIntervalSinceNow >= recoveryTimeout {
            handleFallbackError(FallbackError.recoveryTimeout)
        }
    }
    
    private func activateEmergencyFallback() throws {
        guard consecutiveFallbacks < maxConsecutiveFallbacks else {
            throw FallbackError.maxConsecutiveFallbacksReached
        }
        
        // Save current variant for recovery
        if !isInFallbackMode {
            originalVariant = qualityAdapter.currentVariant
        }
        
        // Select emergency variant
        guard let fallbackVariant = selectFallbackVariant() else {
            throw FallbackError.noFallbackVariantsAvailable
        }
        
        isInFallbackMode = true
        fallbackStartTime = Date()
        consecutiveFallbacks += 1
        
        // Disable automatic quality adaptation
        qualityAdapter.setQualityMode(automatic: false)
        
        // Switch to fallback variant
        try streamSwitcher.switchToVariant(fallbackVariant, atPosition: nil)
        delegate?.fallbackHandler(self, didActivateFallbackToVariant: fallbackVariant)
    }
    
    private func selectFallbackVariant() -> HLSVariant? {
        // If we have a last stable variant, try that first
        if let lastStable = lastStableVariant,
           emergencyVariants.contains(lastStable) {
            return lastStable
        }
        
        // Otherwise, select lowest bandwidth variant
        return emergencyVariants.first
    }
    
    private func attemptRecovery() {
        guard let original = originalVariant else { return }
        
        do {
            try streamSwitcher.switchToVariant(original)
            
            // Re-enable automatic quality adaptation
            qualityAdapter.setQualityMode(automatic: true)
            
            // Update state
            isInFallbackMode = false
            fallbackStartTime = nil
            lastStableVariant = original
            
            delegate?.fallbackHandler(self, didRecover: true)
        } catch {
            handleFallbackError(error)
        }
    }
    
    private func handleFallbackError(_ error: Error) {
        // If we hit max fallbacks, try one last emergency measure
        if case FallbackError.maxConsecutiveFallbacksReached = error {
            forceLowestQualityEmergencyMode()
        }
        
        // Reset if timeout occurred
        if case FallbackError.recoveryTimeout = error {
            reset()
        }
    }
    
    private func forceLowestQualityEmergencyMode() {
        guard let lowestVariant = emergencyVariants.first else { return }
        
        // Clear buffers
        queueManager.clear()
        
        // Force switch to lowest quality
        try? streamSwitcher.switchToVariant(lowestVariant)
        
        // Reset counters but maintain emergency state
        consecutiveFallbacks = 0
        fallbackStartTime = Date()
    }
    
    func reset() {
        isInFallbackMode = false
        fallbackStartTime = nil
        consecutiveFallbacks = 0
        originalVariant = nil
        qualityAdapter.setQualityMode(automatic: true)
    }
}

// Extension to handle stream events
extension FallbackHandler: StreamSwitchingManagerDelegate {
    func switchingManager(_ manager: StreamSwitchingManager, 
                         didFailSwitchWithError error: Error) {
        if isInFallbackMode {
            handleFallbackError(error)
        }
    }
    
    func switchingManager(_ manager: StreamSwitchingManager, 
                         didCompleteSwitchTo variant: HLSVariant) {
        if !isInFallbackMode {
            lastStableVariant = variant
        }
    }
}

protocol StreamSwitchingManagerDelegate: AnyObject {
    func switchingManager(_ manager: StreamSwitchingManager, didStartSwitchTo variant: HLSVariant)
    func switchingManager(_ manager: StreamSwitchingManager, didCompleteSwitchTo variant: HLSVariant)
    func switchingManager(_ manager: StreamSwitchingManager, didFailSwitchWithError error: Error)
}

class StreamSwitchingManager {
    weak var delegate: StreamSwitchingManagerDelegate?
    private let queueManager: HLSQueueManager
    private let demuxer: HLSDemuxer
    
    // Switching state
    private var isSwitching = false
    private var targetVariant: HLSVariant?
    private var switchingSegmentIndex: Int64?
    private var discontinuitySequence: Int = 0
    
    // Configuration
    private let maxSwitchingAttempts = 3
    private var currentSwitchAttempt = 0
    
    // Keyframe alignment
    private var lastKeyframeTimestamp: CMTime = .zero
    private let keyframeAlignment = CMTime(seconds: 2, preferredTimescale: 600)
    
    enum SwitchingError: Error {
        case alreadySwitching
        case invalidVariant
        case maxAttemptsReached
        case discontinuityMismatch
        case noKeyframeFound
    }
    
    init(queueManager: HLSQueueManager, demuxer: HLSDemuxer) {
        self.queueManager = queueManager
        self.demuxer = demuxer
    }
    
    func switchToVariant(_ variant: HLSVariant, atPosition position: CMTime? = nil) throws {
        guard !isSwitching else {
            throw SwitchingError.alreadySwitching
        }
        
        isSwitching = true
        targetVariant = variant
        currentSwitchAttempt = 0
        
        // Notify delegate about switch initiation
        delegate?.switchingManager(self, didStartSwitchTo: variant)
        
        // Start the switching process
        try initiateSwitch(at: position)
    }
    
    private func initiateSwitch(at position: CMTime?) throws {
        guard let targetVariant = targetVariant else {
            throw SwitchingError.invalidVariant
        }
        
        currentSwitchAttempt += 1
        if currentSwitchAttempt > maxSwitchingAttempts {
            isSwitching = false
            throw SwitchingError.maxAttemptsReached
        }
        
        // Calculate ideal switching point
        let switchPosition = try calculateSwitchPosition(preferredPosition: position)
        
        // Prepare demuxer for new variant
        try prepareDemuxerForSwitch(to: targetVariant, at: switchPosition)
    }
    
    private func calculateSwitchPosition(preferredPosition: CMTime?) throws -> CMTime {
        // If position is specified, align to nearest keyframe
        if let position = preferredPosition {
            return alignToKeyframe(position)
        }
        
        // Otherwise, find next suitable keyframe
        guard let nextKeyframe = findNextKeyframe() else {
            throw SwitchingError.noKeyframeFound
        }
        
        return nextKeyframe
    }
    
    private func alignToKeyframe(_ position: CMTime) -> CMTime {
        // Find nearest keyframe before specified position
        var alignedPosition = position
        
        // Scan backward for keyframe
        while !isKeyframe(at: alignedPosition) && 
              alignedPosition > .zero {
            alignedPosition = CMTimeSubtract(alignedPosition, 
                                           CMTime(value: 1, timescale: 600))
        }
        
        return alignedPosition
    }
    
    private func findNextKeyframe() -> CMTime? {
        // Scan forward from current position for next keyframe
        var searchPosition = lastKeyframeTimestamp
        let maxSearchDuration = CMTime(seconds: 5, preferredTimescale: 600)
        
        while CMTimeCompare(searchPosition, 
                           CMTimeAdd(lastKeyframeTimestamp, maxSearchDuration)) < 0 {
            if isKeyframe(at: searchPosition) {
                return searchPosition
            }
            searchPosition = CMTimeAdd(searchPosition, 
                                     CMTime(value: 1, timescale: 600))
        }
        
        return nil
    }
    
    private func isKeyframe(at position: CMTime) -> Bool {
        // Check if the frame at given position is a keyframe
        guard let packet = queueManager.peekVideoPacket() else { return false }
        return packet.isKeyframe && CMTimeCompare(packet.pts, position) == 0
    }
    
    private func prepareDemuxerForSwitch(to variant: HLSVariant, at position: CMTime) throws {
        // Calculate segment index for switch position
        guard let segmentIndex = calculateSegmentIndex(for: position) else {
            throw SwitchingError.invalidVariant
        }
        
        switchingSegmentIndex = segmentIndex
        
        // Configure demuxer for new variant
        try demuxer.prepareVariantSwitch(to: variant, 
                                        atSegmentIndex: segmentIndex, 
                                        discontinuitySequence: discontinuitySequence)
    }
    
    private func calculateSegmentIndex(for position: CMTime) -> Int64? {
        // Convert time position to segment index based on segment duration
        let segmentDuration = demuxer.currentSegmentDuration
        guard segmentDuration > 0 else { return nil }
        
        let seconds = CMTimeGetSeconds(position)
        return Int64(seconds / segmentDuration)
    }
    
    // Called by HLSDemuxer when a segment is loaded
    func handleSegmentLoaded(_ segment: MediaSegment) {
        guard isSwitching,
              let switchingSegmentIndex = switchingSegmentIndex,
              segment.index >= switchingSegmentIndex else {
            return
        }
        
        // Verify discontinuity sequence
        guard segment.discontinuitySequence == discontinuitySequence else {
            handleSwitchingError(.discontinuityMismatch)
            return
        }
        
        // Complete the switch
        completeSwitching()
    }
    
    private func completeSwitching() {
        guard let targetVariant = targetVariant else { return }
        
        // Update state
        isSwitching = false
        switchingSegmentIndex = nil
        currentSwitchAttempt = 0
        
        // Notify delegate
        delegate?.switchingManager(self, didCompleteSwitchTo: targetVariant)
    }
    
    private func handleSwitchingError(_ error: SwitchingError) {
        // Try to recover if possible
        if currentSwitchAttempt < maxSwitchingAttempts {
            do {
                try initiateSwitch(at: nil)
            } catch {
                delegate?.switchingManager(self, didFailSwitchWithError: error)
            }
        } else {
            delegate?.switchingManager(self, didFailSwitchWithError: error)
        }
    }
    
    // Reset switching state
    func reset() {
        isSwitching = false
        targetVariant = nil
        switchingSegmentIndex = nil
        currentSwitchAttempt = 0
        lastKeyframeTimestamp = .zero
        discontinuitySequence = 0
    }
}

// Extension to handle stream events
extension StreamSwitchingManager: MediaStreamEventHandler {
    func handleStreamEvent(_ event: MediaStreamEvent) {
        switch event {
        case .keyframe(let timestamp):
            lastKeyframeTimestamp = timestamp
            
        case .discontinuity:
            discontinuitySequence += 1
            
        case .error(let error):
            if isSwitching {
                handleSwitchingError(.init(error: error))
            }
            
        default:
            break
        }
    }
}

protocol QualityAdaptationManagerDelegate: AnyObject {
    func adaptationManager(_ manager: QualityAdaptationManager, didSelectVariant variant: HLSVariant)
    func adaptationManager(_ manager: QualityAdaptationManager, didUpdateNetworkStatus status: NetworkStatus)
}

class QualityAdaptationManager {
    weak var delegate: QualityAdaptationManagerDelegate?
    
    // Configuration
    private let minEvaluationInterval: TimeInterval = 2.0
    private let maxBitrateMultiplier: Double = 0.8 // Target 80% of available bandwidth
    private let switchingThreshold: Double = 0.2 // 20% bandwidth change triggers switch
    
    // Network monitoring
    private let networkMonitor = NWPathMonitor()
    private var currentBandwidth: Double = 0
    private var bandwidthSamples: [Double] = []
    private let maxSampleCount = 5
    
    // State
    private var availableVariants: [HLSVariant] = []
    private var currentVariant: HLSVariant?
    private var lastEvaluationTime: Date = Date()
    private var isAutomatic: Bool = true
    
    struct NetworkStatus {
        let bandwidth: Double // bits per second
        let isConstrained: Bool
        let connectionType: ConnectionType
    }
    
    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case unknown
    }
    
    init() {
        setupNetworkMonitoring()
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let connectionType: ConnectionType = {
                if path.usesInterfaceType(.wifi) { return .wifi }
                if path.usesInterfaceType(.cellular) { return .cellular }
                if path.usesInterfaceType(.wired) { return .wired }
                return .unknown
            }()
            
            let status = NetworkStatus(
                bandwidth: self.currentBandwidth,
                isConstrained: path.isConstrained,
                connectionType: connectionType
            )
            
            self.delegate?.adaptationManager(self, didUpdateNetworkStatus: status)
        }
        
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    func updateAvailableVariants(_ variants: [HLSVariant]) {
        self.availableVariants = variants.sorted { $0.bandwidth < $1.bandwidth }
        if currentVariant == nil {
            // Initial variant selection
            selectInitialVariant()
        }
    }
    
    func updateBandwidthSample(_ bytesTransferred: Int64, duration: TimeInterval) {
        guard duration > 0 else { return }
        
        let bps = Double(bytesTransferred * 8) / duration
        bandwidthSamples.append(bps)
        
        if bandwidthSamples.count > maxSampleCount {
            bandwidthSamples.removeFirst()
        }
        
        // Update current bandwidth using moving average
        currentBandwidth = bandwidthSamples.reduce(0.0, +) / Double(bandwidthSamples.count)
        
        evaluateQualitySwitch()
    }
    
    private func evaluateQualitySwitch() {
        guard isAutomatic else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastEvaluationTime) >= minEvaluationInterval else {
            return
        }
        lastEvaluationTime = now
        
        let targetBitrate = currentBandwidth * maxBitrateMultiplier
        
        // Find the highest quality variant that's below our target bitrate
        let optimalVariant = availableVariants
            .filter { $0.bandwidth <= targetBitrate }
            .last
        
        if let optimalVariant = optimalVariant,
           optimalVariant != currentVariant {
            // Only switch if the bandwidth difference exceeds our threshold
            let bandwidthDiff = abs(optimalVariant.bandwidth - (currentVariant?.bandwidth ?? 0))
            let relativeDiff = bandwidthDiff / (currentVariant?.bandwidth ?? 1)
            
            if relativeDiff > switchingThreshold {
                currentVariant = optimalVariant
                delegate?.adaptationManager(self, didSelectVariant: optimalVariant)
            }
        }
    }
    
    private func selectInitialVariant() {
        // Start with a lower quality variant to minimize initial buffering
        if let initialVariant = availableVariants.first {
            currentVariant = initialVariant
            delegate?.adaptationManager(self, didSelectVariant: initialVariant)
        }
    }
    
    // Manual quality selection
    func setQualityMode(automatic: Bool) {
        isAutomatic = automatic
        if automatic {
            evaluateQualitySwitch()
        }
    }
    
    func selectVariant(_ variant: HLSVariant) {
        guard availableVariants.contains(variant) else { return }
        currentVariant = variant
        delegate?.adaptationManager(self, didSelectVariant: variant)
    }
    
    deinit {
        networkMonitor.cancel()
    }
}

// Supporting Types
struct HLSVariant {
    let bandwidth: Double // bits per second
    let resolution: CGSize?
    let codecs: String
    let url: URL
    
    var description: String {
        if let resolution = resolution {
            return String(format: "%.0fp", resolution.height)
        } else {
            return String(format: "%.2f Mbps", bandwidth / 1_000_000)
        }
    }
}

