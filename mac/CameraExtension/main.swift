import CoreMediaIO
import Foundation

// The HandFX camera: what meeting apps see. It does no processing: the HandFX app sends its
// finished frames into the sink stream, and the camera passes them on to its source stream.
let source = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()
