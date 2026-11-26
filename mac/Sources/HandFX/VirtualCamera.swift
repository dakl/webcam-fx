import CoreImage
import CoreMediaIO
import QuartzCore
import SystemExtensions

/// The HandFX camera that meeting apps see: installs its system extension and sends it frames.
///
/// The extension ships inside HandFX.app, so this only works when HandFX runs as the app from
/// /Applications, not through `swift run`.
final class VirtualCamera: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionID = "se.dakl.handfx.camera"
    static let cameraName = "HandFX"
    static let size = CGSize(width: 1280, height: 720)

    private var device: CMIOObjectID = 0
    private var stream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var lastLookup = -Double.infinity
    private var pool: CVPixelBufferPool?
    private var format: CMFormatDescription?

    /// Shown in the window's status line. Set on the main thread, read on the camera queue.
    private(set) var status: String {
        get { lock.withLock { statusText } }
        set { lock.withLock { statusText = newValue } }
    }
    private var statusText = "off"
    private let lock = NSLock()

    var isInApp: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// Ask macOS to install or update the camera extension. The first time, it needs your approval.
    func install() {
        guard isInApp else {
            status = "only in HandFX.app"
            return print("Not running as HandFX.app: no HandFX camera")
        }
        status = "installing"

        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "allow it in System Settings"
        print("Allow the HandFX camera: System Settings > General > Login Items & Extensions > Camera Extensions")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if queue == nil { status = result == .completed ? "installed" : "restart to finish" }  // keep "sending"
        print(result == .completed ? "HandFX camera installed" : "HandFX camera installs after a restart")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "failed: \(error.localizedDescription)"
        print("HandFX camera not installed: \(error.localizedDescription)")
    }

    // MARK: Frames

    /// Send one frame to the HandFX camera, if it is installed. Call from one queue only.
    func send(_ image: CIImage, context: CIContext) {
        guard isInApp, let queue = connectedQueue() else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue), let buffer = pixelBuffer() else { return }
        let fill = max(Self.size.width / image.extent.width, Self.size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
            .concatenating(CGAffineTransform(scaleX: fill, y: fill)))
        context.render(scaled, to: buffer, bounds: CGRect(origin: .zero, size: Self.size),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                         formatDescriptionOut: &format)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format!,
                                           sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample {
            CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
        }
    }

    private func pixelBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: Int(Self.size.width), kCVPixelBufferHeightKey: Int(Self.size.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) }
        return buffer
    }

    /// The sink stream's queue; looks for the HandFX camera at most once a second until it appears.
    private func connectedQueue() -> CMSimpleQueue? {
        if let queue { return queue }
        let now = CACurrentMediaTime()
        guard now - lastLookup > 1 else { return nil }
        lastLookup = now
        guard let device = devices().first(where: { name(of: $0) == Self.cameraName }),
              let sink = streams(of: device).first(where: { direction(of: $0) == 0 }) else { return nil }  // 0: into the device; 1 is what cameras output
        var unmanaged: Unmanaged<CMSimpleQueue>?
        let copied = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged)
        guard copied == 0, let q = unmanaged?.takeRetainedValue() else {
            print("HandFX camera found, but its input would not open (\(copied))")
            return nil
        }
        CMIODeviceStartStream(device, sink)
        (self.device, stream, queue) = (device, sink, q)
        status = "sending"
        print("Sending to the HandFX camera")
        return q
    }

    // MARK: CoreMediaIO lookups

    private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func ids(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &out) == 0 else { return [] }
        return out
    }

    private func devices() -> [CMIOObjectID] { ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) }
    private func streams(of device: CMIOObjectID) -> [CMIOStreamID] { ids(device, kCMIODevicePropertyStreams) }

    private func name(of object: CMIOObjectID) -> String? {
        var addr = address(kCMIOObjectPropertyName)
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &name) {
            CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
        }
        guard status == 0, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private func direction(of stream: CMIOStreamID) -> UInt32 {
        var addr = address(kCMIOStreamPropertyDirection)
        var value: UInt32 = 0
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return value
    }
}
