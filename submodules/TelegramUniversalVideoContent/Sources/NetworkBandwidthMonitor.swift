import Foundation

protocol BandwidthMonitorDelegate: AnyObject {
    func bandwidthMonitor(_ monitor: NetworkBandwidthMonitor, didUpdateBandwidth bandwidth: Double)
    func bandwidthMonitor(_ monitor: NetworkBandwidthMonitor, didEncounterError error: Error)
}

enum BandwidthMonitorError: Error {
    case invalidMeasurement
    case insufficientSamples
    case networkError(Error)
}

class NetworkBandwidthMonitor {
    weak var delegate: BandwidthMonitorDelegate?
    
    private var measurements: [(timestamp: TimeInterval, bytes: Int64)] = []
    private let maxMeasurements = 30 // Rolling window of measurements
    private let measurementInterval: TimeInterval = 1.0 // 1 second interval
    private var lastMeasurementTime: TimeInterval = 0
    
    // Minimum bandwidth threshold for HD quality (2 Mbps)
    private let hdBandwidthThreshold: Double = 2_000_000
    // Minimum bandwidth threshold for SD quality (800 Kbps)
    private let sdBandwidthThreshold: Double = 800_000
    
    private var currentBandwidth: Double = 0 {
        didSet {
            delegate?.bandwidthMonitor(self, didUpdateBandwidth: currentBandwidth)
        }
    }
    
    func addMeasurement(bytes: Int64) {
        let now = Date().timeIntervalSince1970
        
        // Only add measurement if enough time has passed
        guard now - lastMeasurementTime >= measurementInterval else {
            return
        }
        
        measurements.append((timestamp: now, bytes: bytes))
        
        // Remove old measurements
        while measurements.count > maxMeasurements {
            measurements.removeFirst()
        }
        
        updateBandwidth()
        lastMeasurementTime = now
    }
    
    private func updateBandwidth() {
        guard measurements.count >= 2 else {
            return
        }
        
        do {
            let bandwidth = try calculateBandwidth()
            currentBandwidth = bandwidth
        } catch {
            delegate?.bandwidthMonitor(self, didEncounterError: error)
        }
    }
    
    private func calculateBandwidth() throws -> Double {
        guard measurements.count >= 2 else {
            throw BandwidthMonitorError.insufficientSamples
        }
        
        // Calculate total bytes and time
        var totalBytes: Int64 = 0
        let startTime = measurements.first!.timestamp
        let endTime = measurements.last!.timestamp
        
        for measurement in measurements {
            totalBytes += measurement.bytes
        }
        
        let duration = endTime - startTime
        guard duration > 0 else {
            throw BandwidthMonitorError.invalidMeasurement
        }
        
        // Calculate bandwidth in bits per second
        return Double(totalBytes * 8) / duration
    }
    
    func recommendedQuality() -> VideoQuality {
        if currentBandwidth >= hdBandwidthThreshold {
            return .hd
        } else if currentBandwidth >= sdBandwidthThreshold {
            return .sd
        } else {
            return .low
        }
    }
    
    func reset() {
        measurements.removeAll()
        currentBandwidth = 0
        lastMeasurementTime = 0
    }
}

enum VideoQuality: String {
    case low = "240p"
    case sd = "480p"
    case hd = "720p"
}
