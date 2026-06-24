import Foundation
import CKalam

public enum KalamError: Error, LocalizedError {
    case deviceNotConnected
    case transferFailed(String)
    case operationFailed(String)
    case invalidResponse
    case serializationError
    case operationInProgress
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "No MTP device connected, or device is busy."
        case .transferFailed(let msg):
            return "File transfer failed: \(msg)"
        case .operationFailed(let msg):
            return "MTP operation failed: \(msg)"
        case .invalidResponse:
            return "Received an invalid or malformed response from the MTP subsystem."
        case .serializationError:
            return "Failed to serialize input arguments for the MTP subsystem."
        case .operationInProgress:
            return "Another MTP operation is currently in progress."
        case .timedOut(let msg):
            return "MTP operation timed out: \(msg)"
        }
    }
}

// MARK: - Continuation Registry for C Callbacks

private final class KalamRegistry: @unchecked Sendable {
    static let shared = KalamRegistry()
    private let lock = NSLock()

    // Continuations for synchronous-like operations
    private var doneContinuation: CheckedContinuation<String, Error>?
    
    // Callbacks for transfers
    private var preprocessCallback: ((String) -> Void)?
    private var progressCallback: ((String) -> Void)?
    private var transferDoneCallback: ((String) -> Void)?

    private init() {}

    func setDoneContinuation(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if doneContinuation != nil {
            lock.unlock()
            continuation.resume(throwing: KalamError.operationInProgress)
            return
        }
        doneContinuation = continuation
        lock.unlock()
    }

    func resolveDone(with json: String) {
        lock.lock()
        let continuation = doneContinuation
        doneContinuation = nil
        lock.unlock()
        continuation?.resume(returning: json)
    }

    func rejectDone(with error: Error) {
        lock.lock()
        let continuation = doneContinuation
        doneContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func setTransferCallbacks(
        preprocess: @escaping (String) -> Void,
        progress: @escaping (String) -> Void,
        done: @escaping (String) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.preprocessCallback = preprocess
        self.progressCallback = progress
        self.transferDoneCallback = done
    }

    func clearTransferCallbacks() {
        lock.lock()
        defer { lock.unlock() }
        self.preprocessCallback = nil
        self.progressCallback = nil
        self.transferDoneCallback = nil
    }

    func triggerPreprocess(_ json: String) {
        let cb: ((String) -> Void)?
        lock.lock()
        cb = preprocessCallback
        lock.unlock()
        cb?(json)
    }

    func triggerProgress(_ json: String) {
        let cb: ((String) -> Void)?
        lock.lock()
        cb = progressCallback
        lock.unlock()
        cb?(json)
    }

    func triggerTransferDone(_ json: String) {
        let cb: ((String) -> Void)?
        lock.lock()
        cb = transferDoneCallback
        lock.unlock()
        cb?(json)
    }
}

// MARK: - Global C-convention callbacks

// Go's send_cb_result stores the on_cb_result_t* and later calls send_cb_result(ptr, json)
// which does: cb = (on_cb_result_t) ptr; cb(json). Resuming a Swift continuation from
// inside that CGo callback triggers SIGURG preemption at the Swift Concurrency boundary.
// We bounce to a GCD queue first to avoid that.

private let bounceQueue = DispatchQueue(label: "com.macmtp.callback-bounce", qos: .userInitiated)

private func cDoneCallback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.resolveDone(with: json)
    }
}

private func cPreprocessCallback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.triggerPreprocess(json)
    }
}

private func cProgressCallback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.triggerProgress(json)
    }
}

private func cTransferDoneCallback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.triggerTransferDone(json)
    }
}

// Stable callback pointers — Go stores these and dereferences them asynchronously
// after the calling closure has returned. Must be nonisolated(unsafe) since they
// cross the actor boundary from a C callback context.
nonisolated(unsafe) private var globalDoneCb: on_cb_result_t? = cDoneCallback
nonisolated(unsafe) private var globalPreprocessCb: on_cb_result_t? = cPreprocessCallback
nonisolated(unsafe) private var globalProgressCb: on_cb_result_t? = cProgressCallback
nonisolated(unsafe) private var globalTransferDoneCb: on_cb_result_t? = cTransferDoneCallback

// MARK: - KalamBridge Actor

public actor KalamBridge {
    public static let shared = KalamBridge()

    private let jsonDecoder: JSONDecoder

    /// macOS 15+ Swift Concurrency cooperative threads interfere with Go's signal handling,
    private let mtpQueue: DispatchQueue

    private init() {
        self.jsonDecoder = JSONDecoder()
        self.mtpQueue = DispatchQueue(label: "com.macmtp.kalam", qos: .userInitiated)
    }

    // MARK: - Helper execution wrappers

    internal func executeMTP<T: Decodable>(_ operation: @escaping @Sendable (UnsafeMutablePointer<on_cb_result_t?>?) -> Void) async throws -> T {
        let jsonString = try await withCheckedThrowingContinuation { continuation in
            KalamRegistry.shared.setDoneContinuation(continuation)
            mtpQueue.async {
                operation(&globalDoneCb)
            }
        }

        return try decodeResponse(jsonString)
    }

    internal func executeMTPWithInput<T: Decodable, I: Encodable>(
        _ input: I,
        _ operation: @escaping @Sendable (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<on_cb_result_t?>?) -> Void
    ) async throws -> T {
        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        let jsonString = try await withCheckedThrowingContinuation { continuation in
            KalamRegistry.shared.setDoneContinuation(continuation)
            mtpQueue.async {
                var cInput = inputJson.utf8CString
                cInput.withUnsafeMutableBufferPointer { buffer in
                    operation(buffer.baseAddress, &globalDoneCb)
                }
            }
        }

        return try decodeResponse(jsonString)
    }

    private func decodeResponse<T: Decodable>(_ json: String) throws -> T {
        // First check for error response
        if let errResp = try? jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
           let errMsg = errResp.error, !errMsg.isEmpty {
            throw KalamError.operationFailed(errMsg)
        }

        do {
            return try jsonDecoder.decode(T.self, from: json.data(using: .utf8) ?? Data())
        } catch {
            print("Failed to decode MTP response: \(json). Error: \(error)")
            throw KalamError.invalidResponse
        }
    }

    // MARK: - Public APIs

    public func initialize() async throws -> GoDeviceInfoData {
        let result: GoDeviceInfoResult = try await executeMTP { doneCb in
            Initialize(doneCb)
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to initialize device")
        }
        return data
    }

    public func fetchStorages() async throws -> [GoStorageData] {
        let result: GoStoragesResult = try await executeMTP { doneCb in
            FetchStorages(doneCb)
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to fetch storages")
        }
        return data
    }

    public func listDirectory(storageId: UInt32, path: String, recursive: Bool = false) async throws -> [GoFileInfo] {
        struct WalkInput: Encodable {
            let storageId: UInt32
            let fullPath: String
            let recursive: Bool
            let skipDisallowedFiles: Bool
            let skipHiddenFiles: Bool
        }

        let input = WalkInput(
            storageId: storageId,
            fullPath: path,
            recursive: recursive,
            skipDisallowedFiles: true,
            skipHiddenFiles: false
        )

        let result: GoWalkResult = try await executeMTPWithInput(input) { inputJson, doneCb in
            Walk(inputJson, doneCb)
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to walk directory")
        }
        return data
    }

    public func makeDirectory(storageId: UInt32, path: String) async throws {
        struct MakeDirectoryInput: Encodable {
            let storageId: UInt32
            let fullPath: String
        }

        let input = MakeDirectoryInput(storageId: storageId, fullPath: path)
        let result: GoSimpleResult = try await executeMTPWithInput(input) { inputJson, doneCb in
            MakeDirectory(inputJson, doneCb)
        }
        if let err = result.error, !err.isEmpty {
            throw KalamError.operationFailed(err)
        }
    }

    public func deleteFiles(storageId: UInt32, paths: [String]) async throws {
        struct DeleteFileInput: Encodable {
            let storageId: UInt32
            let Files: [String]
        }

        let input = DeleteFileInput(storageId: storageId, Files: paths)
        let result: GoSimpleResult = try await executeMTPWithInput(input) { inputJson, doneCb in
            DeleteFile(inputJson, doneCb)
        }
        if let err = result.error, !err.isEmpty {
            throw KalamError.operationFailed(err)
        }
    }

    public func renameFile(storageId: UInt32, path: String, newName: String) async throws {
        struct RenameFileInput: Encodable {
            let storageId: UInt32
            let fullPath: String
            let newFileName: String
        }

        let input = RenameFileInput(storageId: storageId, fullPath: path, newFileName: newName)
        let result: GoSimpleResult = try await executeMTPWithInput(input) { inputJson, doneCb in
            RenameFile(inputJson, doneCb)
        }
        if let err = result.error, !err.isEmpty {
            throw KalamError.operationFailed(err)
        }
    }

    public func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool] {
        struct FileExistsInput: Encodable {
            let storageId: UInt32
            let Files: [String]
        }

        let input = FileExistsInput(storageId: storageId, Files: paths)
        let result: GoFileExistsResult = try await executeMTPWithInput(input) { inputJson, doneCb in
            FileExists(inputJson, doneCb)
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to check file existence")
        }

        // Map them back to the input order
        var resultMap = [String: Bool]()
        for entry in data {
            resultMap[entry.fullpath] = entry.exists
        }
        return paths.map { resultMap[$0] ?? false }
    }

    public func uploadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws {
        struct UploadFilesInput: Encodable {
            let storageId: UInt32
            let sources: [String]
            let destination: String
            let preprocessFiles: Bool
        }

        let input = UploadFilesInput(
            storageId: storageId,
            sources: sources,
            destination: destination,
            preprocessFiles: true
        )

        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            KalamRegistry.shared.setTransferCallbacks(
                preprocess: { json in
                    if let result = try? self.jsonDecoder.decode(GoPreprocessResult.self, from: json.data(using: .utf8) ?? Data()),
                       let data = result.data {
                        onPreprocess(data)
                    }
                },
                progress: { json in
                    if let result = try? self.jsonDecoder.decode(GoProgressResult.self, from: json.data(using: .utf8) ?? Data()),
                       let data = result.data {
                        onProgress(data)
                    }
                },
                done: { json in
                    KalamRegistry.shared.clearTransferCallbacks()
                    if let errResp = try? self.jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
                       let errMsg = errResp.error, !errMsg.isEmpty {
                        continuation.resume(throwing: KalamError.transferFailed(errMsg))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )

            mtpQueue.async {
                var cInput = inputJson.utf8CString
                cInput.withUnsafeMutableBufferPointer { buffer in
                    UploadFiles(buffer.baseAddress, &globalPreprocessCb, &globalProgressCb, &globalTransferDoneCb)
                }
            }
        }
    }

    public func downloadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws {
        struct DownloadFilesInput: Encodable {
            let storageId: UInt32
            let sources: [String]
            let destination: String
            let preprocessFiles: Bool
        }

        let input = DownloadFilesInput(
            storageId: storageId,
            sources: sources,
            destination: destination,
            preprocessFiles: true
        )

        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            KalamRegistry.shared.setTransferCallbacks(
                preprocess: { json in
                    if let result = try? self.jsonDecoder.decode(GoPreprocessResult.self, from: json.data(using: .utf8) ?? Data()),
                       let data = result.data {
                        onPreprocess(data)
                    }
                },
                progress: { json in
                    if let result = try? self.jsonDecoder.decode(GoProgressResult.self, from: json.data(using: .utf8) ?? Data()),
                       let data = result.data {
                        onProgress(data)
                    }
                },
                done: { json in
                    KalamRegistry.shared.clearTransferCallbacks()
                    if let errResp = try? self.jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
                       let errMsg = errResp.error, !errMsg.isEmpty {
                        continuation.resume(throwing: KalamError.transferFailed(errMsg))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )

            mtpQueue.async {
                var cInput = inputJson.utf8CString
                cInput.withUnsafeMutableBufferPointer { buffer in
                    DownloadFiles(buffer.baseAddress, &globalPreprocessCb, &globalProgressCb, &globalTransferDoneCb)
                }
            }
        }
    }

    func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo] {
        return try await listDirectory(storageId: storageId, path: path, recursive: recursive)
    }

    public func dispose() async throws {
        let _: GoSimpleResult = try await executeMTP { doneCb in
            Dispose(doneCb)
        }
    }
}
