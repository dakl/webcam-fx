import CoreMediaIO
import CoreVideo
import Foundation

let frameWidth: Int32 = 1280
let frameHeight: Int32 = 720
let frameDuration = CMTime(value: 1, timescale: 30)

func hostNanoseconds() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var device: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        device = DeviceSource(localizedName: "HandFX")
        do {
            try provider.addDevice(device.device)
        } catch {
            fatalError("Cannot add the HandFX camera: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "HandFX" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// One camera with a source stream (what meeting apps read) and a sink stream (what HandFX writes).
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: StreamSource!
    private var sink: StreamSource!
    private let queue = DispatchQueue(label: "se.dakl.handfx.camera")
    private let format: CMFormatDescription
    private let pool: CVPixelBufferPool
    private var timer: DispatchSourceTimer?
    private var sourceRunning = false
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame: UInt64 = 0

    init(localizedName: String) {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: frameWidth, height: frameHeight, extensions: nil, formatDescriptionOut: &format)
        self.format = format!
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: frameWidth, kCVPixelBufferHeightKey: frameHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        self.pool = pool!
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: UUID(uuidString: "6E1C0F3A-2B8D-4C51-9A7E-48D2F0B1C3A5")!,
                                     legacyDeviceID: nil, source: self)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: self.format, maxFrameDuration: frameDuration,
                                                     minFrameDuration: frameDuration, validFrameDurations: nil)
        source = StreamSource(name: "HandFX.Video", id: UUID(uuidString: "9B4E7D21-5C3F-4A86-B0D1-2E7F6A9C8B34")!,
                              direction: .source, format: streamFormat, device: self)
        sink = StreamSource(name: "HandFX.Sink", id: UUID(uuidString: "1F8A3C6E-7D25-4B9F-8E40-C5A1B2D3E4F6")!,
                            direction: .sink, format: streamFormat, device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Cannot add the HandFX streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = 0x7669_7274 }  // 'virt'
        if properties.contains(.deviceModel) { p.model = "HandFX" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source: frames from HandFX, or grey while it is not sending

    func startSource() {
        queue.async { [self] in
            sourceRunning = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: frameDuration.seconds)
            t.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            t.resume()
            timer = t
        }
    }

    func stopSource() {
        queue.async { [self] in
            sourceRunning = false
            timer?.cancel()
            timer = nil
        }
    }

    private func sendPlaceholderIfIdle() {
        let now = hostNanoseconds()
        guard sourceRunning, now - lastSinkFrame > 500_000_000 else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x40, CVPixelBufferGetDataSize(buffer))  // dark grey
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample { source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now) }
    }

    // MARK: Sink: take each frame HandFX sends and pass it on

    func authorizeSink(_ client: CMIOExtensionClient) {
        queue.async { [self] in sinkClient = client }
    }

    func startSink() {
        queue.async { [self] in consumeNext() }
    }

    func stopSink() {
        queue.async { [self] in sinkClient = nil }
    }

    private func consumeNext() {
        guard let client = sinkClient else { return }
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, _ in
            guard let self else { return }
            self.queue.async {
                guard let sample else {
                    self.queue.asyncAfter(deadline: .now() + frameDuration.seconds / 2) { self.consumeNext() }
                    return
                }
                let now = hostNanoseconds()
                self.lastSinkFrame = now
                if self.sourceRunning {
                    self.source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
                self.consumeNext()
            }
        }
    }
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private unowned let device: DeviceSource

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat,
         device: DeviceSource) {
        self.format = format
        self.direction = direction
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        direction == .source ? [.streamActiveFormatIndex, .streamFrameDuration]
            : [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
               .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if direction == .sink { device.authorizeSink(client) }
        return true
    }

    func startStream() throws {
        direction == .source ? device.startSource() : device.startSink()
    }

    func stopStream() throws {
        direction == .source ? device.stopSource() : device.stopSink()
    }
}
