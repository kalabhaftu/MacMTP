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
    case invalidPath(String)

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
        case .invalidPath(let msg):
            return "Invalid path: \(msg)"
        }
    }
}


private final class KalamRegistry: @unchecked Sendable {
    static let shared = KalamRegistry()
    private let lock = NSLock()

    private var doneContinuation: CheckedContinuation<String, Error>?
    private var transferContinuation: CheckedContinuation<Void, Error>?
    
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

    func setTransferCallbacks(
        continuation: CheckedContinuation<Void, Error>,
        preprocess: @escaping (String) -> Void,
        progress: @escaping (String) -> Void,
        done: @escaping (String) -> Void
    ) {
        lock.lock()
        guard doneContinuation == nil, transferContinuation == nil else {
            lock.unlock()
            continuation.resume(throwing: KalamError.operationInProgress)
            return
        }
        transferContinuation = continuation
        preprocessCallback = preprocess
        progressCallback = progress
        transferDoneCallback = done
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

    func finishTransfer(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = transferContinuation
        transferContinuation = nil
        preprocessCallback = nil
        progressCallback = nil
        transferDoneCallback = nil
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume(returning: ())
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
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


private let bounceQueue = DispatchQueue(label: "com.macmtp.callback-bounce", qos: .userInitiated)

@_cdecl("macMTP_done_callback")
public func macMTP_done_callback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.resolveDone(with: json)
    }
}

@_cdecl("macMTP_preprocess_callback")
public func macMTP_preprocess_callback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.triggerPreprocess(json)
    }
}

@_cdecl("macMTP_progress_callback")
public func macMTP_progress_callback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.triggerProgress(json)
    }
}

@_cdecl("macMTP_transfer_done_callback")
public func macMTP_transfer_done_callback(jsonPtr: UnsafeMutablePointer<CChar>?) {
    guard let jsonPtr = jsonPtr else { return }
    let json = String(cString: jsonPtr)
    free(jsonPtr)
    bounceQueue.async {
        KalamRegistry.shared.triggerTransferDone(json)
    }
}


public actor KalamBridge {
    public static let shared = KalamBridge()

    private let jsonDecoder: JSONDecoder
    private let mtpQueue: DispatchQueue
    private var operationInFlight = false

    private let commandTimeoutNanoseconds: UInt64 = 30_000_000_000
    private let transferTimeoutNanoseconds: UInt64 = 86_400_000_000_000

    private init() {
        self.jsonDecoder = JSONDecoder()
        self.mtpQueue = DispatchQueue(label: "com.macmtp.kalam", qos: .userInitiated)
    }

    private func beginOperation() throws {
        guard !operationInFlight else {
            throw KalamError.operationInProgress
        }
        operationInFlight = true
    }

    private func endOperation() {
        operationInFlight = false
    }

    private func waitForDone(
        timeoutNanoseconds: UInt64,
        timeoutMessage: String,
        startOperation: @escaping @Sendable () -> Void
    ) async throws -> String {
        let waiter = Task<String, Error> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        KalamRegistry.shared.setDoneContinuation(continuation)
                        startOperation()
                    }
                }
            } onCancel: {
                KalamRegistry.shared.rejectDone(with: CancellationError())
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            KalamRegistry.shared.rejectDone(with: KalamError.timedOut(timeoutMessage))
        }

        defer {
            timeoutTask.cancel()
            waiter.cancel()
        }

        return try await waiter.value
    }


    internal func executeMTP<T: Decodable>(_ operation: @escaping @Sendable () -> Void) async throws -> T {
        try beginOperation()
        defer { endOperation() }

        let jsonString = try await waitForDone(
            timeoutNanoseconds: commandTimeoutNanoseconds,
            timeoutMessage: "The MTP command did not respond.",
            startOperation: { self.mtpQueue.async { operation() } }
        )
        return try decodeResponse(jsonString)
    }

    internal func executeMTPWithInput<T: Decodable, I: Encodable>(
        _ input: I,
        _ operation: @escaping @Sendable (UnsafeMutablePointer<CChar>?) -> Void
    ) async throws -> T {
        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        try beginOperation()
        defer { endOperation() }

        let jsonString = try await waitForDone(
            timeoutNanoseconds: commandTimeoutNanoseconds,
            timeoutMessage: "The MTP command did not respond.",
            startOperation: {
                self.mtpQueue.async {
                    var cInput = inputJson.utf8CString
                    cInput.withUnsafeMutableBufferPointer { buffer in
                        operation(buffer.baseAddress)
                    }
                }
            }
        )
        return try decodeResponse(jsonString)
    }

    private func decodeResponse<T: Decodable>(_ json: String) throws -> T {
        if let errResp = try? jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
           let errMsg = errResp.error, !errMsg.isEmpty {
            throw KalamError.operationFailed(errMsg)
        }

        do {
            return try jsonDecoder.decode(T.self, from: json.data(using: .utf8) ?? Data())
        } catch {
            throw KalamError.invalidResponse
        }
    }


    public func initialize() async throws -> GoDeviceInfoData {
        let result: GoDeviceInfoResult = try await executeMTP {
            Initialize()
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to initialize device")
        }
        return data
    }

    public func fetchStorages() async throws -> [GoStorageData] {
        let result: GoStoragesResult = try await executeMTP {
            FetchStorages()
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to fetch storages")
        }
        return data
    }

    public func listDirectory(
        storageId: UInt32,
        path: String,
        recursive: Bool = false,
        skipHidden: Bool = false
    ) async throws -> [GoFileInfo] {
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
            skipHiddenFiles: skipHidden
        )

        let result: GoWalkResult = try await executeMTPWithInput(input) { inputJson in
            Walk(inputJson)
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
        let result: GoSimpleResult = try await executeMTPWithInput(input) { inputJson in
            MakeDirectory(inputJson)
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
        let result: GoSimpleResult = try await executeMTPWithInput(input) { inputJson in
            DeleteFile(inputJson)
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
        let result: GoSimpleResult = try await executeMTPWithInput(input) { inputJson in
            RenameFile(inputJson)
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
        let result: GoFileExistsResult = try await executeMTPWithInput(input) { inputJson in
            FileExists(inputJson)
        }
        guard let data = result.data else {
            throw KalamError.operationFailed(result.error ?? "Failed to check file existence")
        }

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

        try beginOperation()
        defer { endOperation() }

        let waiter = Task<Void, Error> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    KalamRegistry.shared.setTransferCallbacks(
                        continuation: continuation,
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
                    if let errResp = try? self.jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
                       let errMsg = errResp.error, !errMsg.isEmpty {
                        KalamRegistry.shared.finishTransfer(with: .failure(KalamError.transferFailed(errMsg)))
                    } else {
                        KalamRegistry.shared.finishTransfer(with: .success(()))
                    }
                })

                    mtpQueue.async {
                        var cInput = inputJson.utf8CString
                        cInput.withUnsafeMutableBufferPointer { buffer in
                            UploadFiles(buffer.baseAddress)
                        }
                    }
                }
            } onCancel: {
                KalamRegistry.shared.finishTransfer(with: .failure(CancellationError()))
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: transferTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            KalamRegistry.shared.finishTransfer(with: .failure(KalamError.timedOut("The upload did not finish.")))
        }
        defer {
            timeoutTask.cancel()
            waiter.cancel()
        }
        try await waiter.value
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

        try beginOperation()
        defer { endOperation() }

        let waiter = Task<Void, Error> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    KalamRegistry.shared.setTransferCallbacks(
                        continuation: continuation,
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
                    if let errResp = try? self.jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
                       let errMsg = errResp.error, !errMsg.isEmpty {
                        KalamRegistry.shared.finishTransfer(with: .failure(KalamError.transferFailed(errMsg)))
                    } else {
                        KalamRegistry.shared.finishTransfer(with: .success(()))
                    }
                })

                    mtpQueue.async {
                        var cInput = inputJson.utf8CString
                        cInput.withUnsafeMutableBufferPointer { buffer in
                            DownloadFiles(buffer.baseAddress)
                        }
                    }
                }
            } onCancel: {
                KalamRegistry.shared.finishTransfer(with: .failure(CancellationError()))
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: transferTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            KalamRegistry.shared.finishTransfer(with: .failure(KalamError.timedOut("The download did not finish.")))
        }
        defer {
            timeoutTask.cancel()
            waiter.cancel()
        }
        try await waiter.value
    }

    func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo] {
        return try await listDirectory(
            storageId: storageId,
            path: path,
            recursive: recursive,
            skipHidden: skipHidden
        )
    }

    public func dispose() async throws {
        let _: GoSimpleResult = try await executeMTP {
            Dispose()
        }
    }
}
