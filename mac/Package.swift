// swift-tools-version:5.10
import Foundation
import PackageDescription

/// ONNX Runtime from Microsoft's NuGet package, put here by fetch-onnxruntime.sh.
let onnxLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/onnxruntime/lib").path

let package = Package(
    name: "HandFX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HandTracking", targets: ["HandTracking"]),
        .library(name: "PixelGrid", targets: ["PixelGrid"]),
    ],
    targets: [
        // ONNX Runtime's C API. Run ./fetch-onnxruntime.sh first.
        .systemLibrary(name: "COnnxRuntime"),
        .target(
            name: "HandTracking", dependencies: ["COnnxRuntime"],
            resources: [.copy("Models")],
            // HandFX.app carries the library in Contents/Frameworks; `swift run` uses Vendor/ directly.
            linkerSettings: [.unsafeFlags(["-L", onnxLib, "-Xlinker", "-rpath", "-Xlinker", onnxLib])]),
        .target(name: "PixelGrid"),
        .executableTarget(name: "HandFX", dependencies: ["HandTracking", "PixelGrid"]),
        .testTarget(name: "HandTrackingTests", dependencies: ["HandTracking"]),
        .testTarget(name: "PixelGridTests", dependencies: ["PixelGrid"]),
    ]
)
