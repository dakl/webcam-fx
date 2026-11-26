// swift-tools-version:5.10
import Foundation
import PackageDescription

/// ONNX Runtime from Microsoft's NuGet package, put here by fetch-onnxruntime.sh.
let onnxLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/onnxruntime/lib").path

let package = Package(
    name: "HandFX",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HandTracking", targets: ["HandTracking"])],
    targets: [
        // ONNX Runtime's C API. Run ./fetch-onnxruntime.sh first.
        .systemLibrary(name: "COnnxRuntime"),
        .target(name: "HandTracking", dependencies: ["COnnxRuntime"],
                resources: [.copy("Models")],
                // HandFX.app carries the library in Contents/Frameworks; `swift run` uses Vendor/ directly.
                linkerSettings: [.unsafeFlags(["-L", onnxLib, "-Xlinker", "-rpath", "-Xlinker", onnxLib])]),
        .executableTarget(name: "HandFX", dependencies: ["HandTracking"]),
        .testTarget(name: "HandTrackingTests", dependencies: ["HandTracking"]),
    ]
)
