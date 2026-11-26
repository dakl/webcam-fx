import COnnxRuntime
import Foundation

public struct OrtError: Error, CustomStringConvertible {
    public let description: String
}

private let api: OrtApi = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee

private func check(_ status: OpaquePointer?) throws {
    guard let status else { return }
    let message = String(cString: api.GetErrorMessage(status)!)
    api.ReleaseStatus(status)
    throw OrtError(description: message)
}

// ONNX Runtime documents its environment as safe to share between threads.
nonisolated(unsafe) private let environment: OpaquePointer = {
    var env: OpaquePointer?
    try! check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "handfx", &env))
    return env!
}()

/// One ONNX model with a single float input. Not thread-safe: call `run` from one queue.
final class OrtModel {
    private let session: OpaquePointer
    private let memory: OpaquePointer
    private let inputNames: [UnsafePointer<CChar>?]
    private let outputNames: [UnsafePointer<CChar>?]

    /// `coreML` runs the model through Core ML in the MLProgram format, which keeps 32-bit floats.
    init(url: URL, input: String, outputs: [String], coreML: Bool) throws {
        var options: OpaquePointer?
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        if coreML {
            let keys = cStrings(["ModelFormat", "MLComputeUnits"])
            let values = cStrings(["MLProgram", "ALL"])
            defer { for s in keys + values { free(UnsafeMutablePointer(mutating: s)) } }
            try check(api.SessionOptionsAppendExecutionProvider(options, "CoreML", keys, values, keys.count))
        }
        var session: OpaquePointer?
        try check(api.CreateSession(environment, url.path, options, &session))
        var memory: OpaquePointer?
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        self.session = session!
        self.memory = memory!
        inputNames = cStrings([input])
        outputNames = cStrings(outputs)
    }

    deinit {
        for s in inputNames + outputNames { free(UnsafeMutablePointer(mutating: s)) }
        api.ReleaseMemoryInfo(memory)
        api.ReleaseSession(session)
    }

    /// Run on `input` (shape `shape`); return each output, flattened, in the order given at init.
    func run(_ input: inout [Float], shape: [Int64]) throws -> [[Float]] {
        try input.withUnsafeMutableBytes { bytes in
            var value: OpaquePointer?
            try check(
                api.CreateTensorWithDataAsOrtValue(
                    memory, bytes.baseAddress, bytes.count, shape, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &value))
            defer { api.ReleaseValue(value) }
            var outputs = [OpaquePointer?](repeating: nil, count: outputNames.count)
            let inputs: [OpaquePointer?] = [value]
            try check(api.Run(session, nil, inputNames, inputs, 1, outputNames, outputNames.count, &outputs))
            defer { for value in outputs { api.ReleaseValue(value) } }
            return try outputs.map { try Self.floats($0) }
        }
    }

    private static func floats(_ value: OpaquePointer?) throws -> [Float] {
        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(value, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var count = 0
        try check(api.GetTensorShapeElementCount(info, &count))
        var data: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(value, &data))
        return Array(UnsafeBufferPointer(start: data!.assumingMemoryBound(to: Float.self), count: count))
    }
}

/// C copies of `strings`; free each with `free`.
private func cStrings(_ strings: [String]) -> [UnsafePointer<CChar>?] {
    strings.map { UnsafePointer(strdup($0)!) }
}
