// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HandFX",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HandTracking", targets: ["HandTracking"])],
    targets: [
        // ONNX Runtime's C API, from Homebrew: `brew install onnxruntime` (built with Core ML).
        .systemLibrary(name: "COnnxRuntime", pkgConfig: "libonnxruntime",
                       providers: [.brew(["onnxruntime"])]),
        .target(name: "HandTracking", dependencies: ["COnnxRuntime"],
                resources: [.copy("Models")]),
        .executableTarget(name: "HandFX", dependencies: ["HandTracking"]),
        .testTarget(name: "HandTrackingTests", dependencies: ["HandTracking"]),
    ]
)
