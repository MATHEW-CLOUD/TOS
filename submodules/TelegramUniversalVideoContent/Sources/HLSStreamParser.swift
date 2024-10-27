import Foundation
import AVFoundation

/// Represents a quality variant in HLS stream
struct StreamVariant {
    let bandwidth: Int
    let resolution: CGSize?
    let uri: URL
    let codecs: String?
}

/// Represents a media segment in the stream
struct MediaSegment {
    let duration: TimeInterval
    let uri: URL
    let byteRange: Range<Int>?
    let sequence: Int
}

enum HLSError: Error {
    case invalidPlaylistData
    case invalidVariantData
    case parsingError
}

class HLSStreamParser {
    private var masterPlaylistURL: URL
    private var variants: [StreamVariant] = []
    private var currentVariant: StreamVariant?
    private var mediaSegments: [MediaSegment] = []
    private var targetDuration: TimeInterval = 0
    private var mediaSequence: Int = 0
    
    init(masterPlaylistURL: URL) {
        self.masterPlaylistURL = masterPlaylistURL
    }
    
    /// Parse master playlist to extract available stream variants
    func parseMasterPlaylist() async throws -> [StreamVariant] {
        let data = try await URLSession.shared.data(from: masterPlaylistURL).0
        guard let content = String(data: data, encoding: .utf8) else {
            throw HLSError.invalidPlaylistData
        }
        
        variants = try parseMasterPlaylistContent(content)
        return variants
    }
    
    /// Parse variant playlist to extract media segments
    func parseVariantPlaylist(for variant: StreamVariant) async throws -> [MediaSegment] {
        let data = try await URLSession.shared.data(from: variant.uri).0
        guard let content = String(data: data, encoding: .utf8) else {
            throw HLSError.invalidPlaylistData
        }
        
        mediaSegments = try parseVariantPlaylistContent(content)
        currentVariant = variant
        return mediaSegments
    }
}  
private func parseMasterPlaylistContent(_ content: String) throws -> [StreamVariant] {
    var variants: [StreamVariant] = []
    let lines = content.components(separatedBy: .newlines)
    
    var currentBandwidth: Int?
    var currentResolution: CGSize?
    var currentCodecs: String?
    
    for line in lines {
        if line.hasPrefix("#EXT-X-STREAM-INF:") {
            // Parse stream information
            let attributes = parseAttributes(from: line)
            currentBandwidth = Int(attributes["BANDWIDTH"] ?? "0")
            currentCodecs = attributes["CODECS"]?.trimmingCharacters(in: .quotes)
            
            if let resolution = attributes["RESOLUTION"] {
                currentResolution = parseResolution(resolution)
            }
        } else if !line.hasPrefix("#") && !line.isEmpty {
            // This is a URI line
            guard let bandwidth = currentBandwidth,
                  let url = URL(string: line, relativeTo: masterPlaylistURL) else {
                continue
            }
            
            let variant = StreamVariant(
                bandwidth: bandwidth,
                resolution: currentResolution,
                uri: url,
                codecs: currentCodecs
            )
            variants.append(variant)
            
            // Reset current values
            currentBandwidth = nil
            currentResolution = nil
            currentCodecs = nil
        }
    }
    
    return variants
}

private func parseVariantPlaylistContent(_ content: String) throws -> [MediaSegment] {
    var segments: [MediaSegment] = []
    let lines = content.components(separatedBy: .newlines)
    
    var currentDuration: TimeInterval?
    var currentSequence = mediaSequence
    var currentByteRange: Range<Int>?
    
    for line in lines {
        if line.hasPrefix("#EXT-X-TARGETDURATION:") {
            targetDuration = TimeInterval(line.split(separator: ":")[1]) ?? 0
        } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
            mediaSequence = Int(line.split(separator: ":")[1]) ?? 0
            currentSequence = mediaSequence
        } else if line.hasPrefix("#EXTINF:") {
            let durationString = line.split(separator: ":")[1]
                .split(separator: ",")[0]
            currentDuration = TimeInterval(durationString)
        } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
            currentByteRange = parseByteRange(from: line)
        } else if !line.hasPrefix("#") && !line.isEmpty {
            guard let duration = currentDuration,
                  let url = URL(string: line, relativeTo: currentVariant?.uri) else {
                continue
            }
            
            let segment = MediaSegment(
                duration: duration,
                uri: url,
                byteRange: currentByteRange,
                sequence: currentSequence
            )
            segments.append(segment)
            
            currentSequence += 1
            currentDuration = nil
            currentByteRange = nil
        }
    }
    
    return segments
}

// Helper methods for parsing specific attributes
private func parseAttributes(from line: String) -> [String: String] {
    var attributes: [String: String] = [:]
    
    guard let attributesString = line.split(separator: ":").last else {
        return attributes
    }
    
    let pairs = attributesString.components(separatedBy: ",")
    for pair in pairs {
        let keyValue = pair.components(separatedBy: "=")
        guard keyValue.count == 2 else { continue }
        attributes[keyValue[0].trimmingCharacters(in: .whitespaces)] = keyValue[1]
    }
    
    return attributes
}

private func parseResolution(_ resolution: String) -> CGSize? {
    let dimensions = resolution.split(separator: "x")
    guard dimensions.count == 2,
          let width = Float(dimensions[0]),
          let height = Float(dimensions[1]) else {
        return nil
    }
    return CGSize(width: CGFloat(width), height: CGFloat(height))
}

private func parseByteRange(from line: String) -> Range<Int>? {
    guard let rangeString = line.split(separator: ":").last else {
        return nil
    }
    
    let components = rangeString.split(separator: "@")
    guard components.count == 2,
          let length = Int(components[0]),
          let offset = Int(components[1]) else {
        return nil
    }
    
    return offset..<(offset + length)
} // Add these properties to the HLSStreamParser class first:
private var isLiveStream: Bool = false
private var playlistRefreshTimer: Timer?
private var lastLoadedSegmentSequence: Int = 0
private var endList: Bool = false
private let refreshInterval: TimeInterval = 3.0 // Default refresh interval for live streams

// Add this protocol for delegate callbacks
protocol HLSStreamParserDelegate: AnyObject {
    func streamParser(_ parser: HLSStreamParser, didUpdateSegments segments: [MediaSegment])
    func streamParser(_ parser: HLSStreamParser, didFailWithError error: Error)
}

// Add these new methods and properties to the HLSStreamParser class:

weak var delegate: HLSStreamParserDelegate?

/// Start monitoring playlist for updates (important for live streams)
func startPlaylistRefresh() {
    guard isLiveStream && playlistRefreshTimer == nil else { return }
    
    playlistRefreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
        Task {
            await self?.refreshCurrentPlaylist()
        }
    }
}

/// Stop monitoring playlist for updates
func stopPlaylistRefresh() {
    playlistRefreshTimer?.invalidate()
    playlistRefreshTimer = nil
}

/// Refresh the current variant playlist
private func refreshCurrentPlaylist() async {
    guard let currentVariant = currentVariant else { return }
    
    do {
        let newSegments = try await parseVariantPlaylist(for: currentVariant)
        processNewSegments(newSegments)
    } catch {
        delegate?.streamParser(self, didFailWithError: error)
    }
}

/// Process new segments and determine which ones are new
private func processNewSegments(_ newSegments: [MediaSegment]) {
    // Filter out segments we've already processed
    let newUnprocessedSegments = newSegments.filter { segment in
        segment.sequence > lastLoadedSegmentSequence
    }
    
    if !newUnprocessedSegments.isEmpty {
        lastLoadedSegmentSequence = newUnprocessedSegments.last?.sequence ?? lastLoadedSegmentSequence
        delegate?.streamParser(self, didUpdateSegments: newUnprocessedSegments)
    }
    
    // Update endList status
    if endList {
        stopPlaylistRefresh()
    }
}

/// Get segments starting from a specific sequence number
func getSegments(fromSequence sequence: Int, maxCount: Int? = nil) -> [MediaSegment] {
    let filteredSegments = mediaSegments.filter { $0.sequence >= sequence }
    if let maxCount = maxCount {
        return Array(filteredSegments.prefix(maxCount))
    }
    return filteredSegments
}

/// Enhanced variant playlist parsing with live stream detection
private func parseVariantPlaylistContent(_ content: String) throws -> [MediaSegment] {
    var segments: [MediaSegment] = []
    let lines = content.components(separatedBy: .newlines)
    
    var currentDuration: TimeInterval?
    var currentSequence = mediaSequence
    var currentByteRange: Range<Int>?
    
    endList = false
    
    for line in lines {
        if line.hasPrefix("#EXT-X-TARGETDURATION:") {
            targetDuration = TimeInterval(line.split(separator: ":")[1]) ?? 0
        } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
            mediaSequence = Int(line.split(separator: ":")[1]) ?? 0
            currentSequence = mediaSequence
        } else if line.hasPrefix("#EXTINF:") {
            let durationString = line.split(separator: ":")[1]
                .split(separator: ",")[0]
            currentDuration = TimeInterval(durationString)
        } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
            currentByteRange = parseByteRange(from: line)
        } else if line.hasPrefix("#EXT-X-ENDLIST") {
            endList = true
            isLiveStream = false
        } else if !line.hasPrefix("#") && !line.isEmpty {
            guard let duration = currentDuration,
                  let url = URL(string: line, relativeTo: currentVariant?.uri) else {
                continue
            }
            
            let segment = MediaSegment(
                duration: duration,
                uri: url,
                byteRange: currentByteRange,
                sequence: currentSequence
            )
            segments.append(segment)
            
            currentSequence += 1
            currentDuration = nil
            currentByteRange = nil
        }
    }
    
    // If no ENDLIST tag was found and we have segments, it's likely a live stream
    if !endList && !segments.isEmpty {
        isLiveStream = true
    }
    
    return segments
}

/// Get estimated duration of all segments
var estimatedDuration: TimeInterval {
    mediaSegments.reduce(0) { $0 + $1.duration }
}

/// Check if stream is live
var isLive: Bool {
    isLiveStream && !endList
}

/// Get available quality levels sorted by bandwidth
var availableQualities: [StreamVariant] {
    variants.sorted { $0.bandwidth < $1.bandwidth }
}

/// Find the best matching variant for given bandwidth
func getBestVariant(forBandwidth bandwidth: Int) -> StreamVariant? {
    // Find the highest quality stream that's below our bandwidth
    let targetBandwidth = Double(bandwidth) * 0.8 // Use 80% of available bandwidth
    return variants
        .filter { Double($0.bandwidth) <= targetBandwidth }
        .max { $0.bandwidth < $1.bandwidth }
}

deinit {
    stopPlaylistRefresh()
} // First, let's add these new structures for segment management
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
}
