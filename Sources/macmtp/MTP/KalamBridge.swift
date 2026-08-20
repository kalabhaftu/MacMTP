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
    case itemAlreadyExists(String)
    case operationNotReconciled(String)
    case nativeOperationFailed(operation: String, errorType: String?, message: String)

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
        case .itemAlreadyExists(let name):
            return "A file or folder named \"\(name)\" already exists in this directory."
        case .operationNotReconciled(let operation):
            return "The MTP device accepted \(operation), but the directory did not confirm the change. Refresh and try again."
        case .nativeOperationFailed(let operation, let errorType, let message):
            let detail = message.isEmpty ? "The MTP subsystem returned no error details." : message
            if let errorType, !errorType.isEmpty {
                return "MTP \(operation) failed (\(errorType)): \(detail)"
            }
            return "MTP \(operation) failed: \(detail)"
        }
    }
}

func isMTPTransportFailure(_ error: Error) -> Bool {
    guard let kalamError = error as? KalamError else { return false }

    switch kalamError {
    case .deviceNotConnected, .timedOut:
        return true
    case .transferFailed(let message), .operationFailed(let message):
        let normalized = message.lowercased()
        return normalized.contains("transaction id mismatch")
            || normalized.contains("libusb")
            || normalized.contains("device is not open")
            || normalized.contains("no mtp device")
            || normalized.contains("errormtpdetectfailed")
            || normalized.contains("timed out")
            || normalized.contains("broken pipe")
            || normalized.contains("device disconnected")
    case .nativeOperationFailed(_, let errorType, let message):
        let normalized = "\(errorType ?? "") \(message)".lowercased()
        return normalized.contains("transaction id mismatch")
            || normalized.contains("libusb")
            || normalized.contains("device is not open")
            || normalized.contains("no mtp device")
            || normalized.contains("errormtpdetectfailed")
            || normalized.contains("timed out")
            || normalized.contains("broken pipe")
            || normalized.contains("device disconnected")
    default:
        return false
    }
}

func shouldReportMTPTransportFailure(_ error: Error, connectionIsActive: Bool) -> Bool {
    if isMTPTransferCancellation(error) {
        return false
    }
    return !isMTPTransportFailure(error) || connectionIsActive
}

func isMTPTransferCancellation(_ error: Error) -> Bool {
    guard case .nativeOperationFailed(_, let errorType, let message) = error as? KalamError else {
        return false
    }
    let normalized = "\(errorType ?? "") \(message)".lowercased()
    return normalized.contains("errortransfercancelled") || normalized.contains("transfer cancelled")
}

func shouldRetryMTPDirectory(_ error: Error) -> Bool {
    guard let kalamError = error as? KalamError else { return false }

    switch kalamError {
    case .nativeOperationFailed(_, let errorType, let message):
        let normalized = "\(errorType ?? "") \(message)".lowercased()
        return normalized.contains("errorlistdirectory")
            || normalized.contains("device is not open")
            || normalized.contains("busy")
            || normalized.contains("lock")
    case .operationFailed(let message):
        let normalized = message.lowercased()
        return normalized.contains("list directory")
            || normalized.contains("device is not open")
            || normalized.contains("busy")
            || normalized.contains("lock")
    default:
        return false
    }
}

private func nativeOperationError(
    operation: String,
    errorType: String?,
    message: String?,
    fallback: String
) -> KalamError {
    let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return .nativeOperationFailed(
        operation: operation,
        errorType: errorType?.trimmingCharacters(in: .whitespacesAndNewlines),
        message: detail.isEmpty ? fallback : detail
    )
}

func nativeErrorType(for error: Error) -> String {
    guard let kalamError = error as? KalamError else {
        return String(describing: type(of: error))
    }

    switch kalamError {
    case .nativeOperationFailed(_, let errorType, _):
        if let errorType, !errorType.isEmpty { return errorType }
        return "unknown"
    case .deviceNotConnected: return "device_not_connected"
    case .transferFailed: return "transfer_failed"
    case .operationFailed: return "operation_failed"
    case .invalidResponse: return "invalid_response"
    case .serializationError: return "serialization_error"
    case .operationInProgress: return "operation_in_progress"
    case .timedOut: return "timed_out"
    case .invalidPath: return "invalid_path"
    case .itemAlreadyExists: return "item_already_exists"
    case .operationNotReconciled: return "operation_not_reconciled"
    }
}

func validateSimpleMTPResult(
    _ result: GoSimpleResult,
    operation: String,
    fallback: String
) throws {
    let errorMessage = result.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorType = result.errorType?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard errorMessage.isEmpty, errorType?.isEmpty != false else {
        throw nativeOperationError(
            operation: operation,
            errorType: errorType,
            message: errorMessage,
            fallback: fallback
        )
    }
    guard result.data == true else {
        throw nativeOperationError(
            operation: operation,
            errorType: errorType,
            message: nil,
            fallback: fallback
        )
    }
}

func normalizedMTPChildName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed != ".",
          trimmed != "..",
          !trimmed.contains("/"),
          !trimmed.contains("\\") else {
        throw KalamError.invalidPath("A file or folder name must not be empty or contain path separators.")
    }
    return trimmed
}

func decodeMTPTransferCompletion(_ json: String) -> Result<Void, Error> {
    guard let data = json.data(using: .utf8),
          let response = try? JSONDecoder().decode(GoTransferCompletionResponse.self, from: data) else {
        return .failure(KalamError.invalidResponse)
    }
    if let message = response.error, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .failure(nativeOperationError(
            operation: "transfer",
            errorType: response.errorType,
            message: message,
            fallback: "The transfer failed."
        ))
    }
    if response.errorType?.isEmpty == false || response.data != true {
        return .failure(nativeOperationError(
            operation: "transfer",
            errorType: response.errorType,
            message: response.error,
            fallback: "The transfer returned an incomplete completion response."
        ))
    }
    return .success(())
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
        let transferCallback = continuation == nil ? transferDoneCallback : nil
        lock.unlock()
        if let continuation {
            continuation.resume(returning: json)
        } else {
            // Existing Kalam builds report transfer failures through the command
            // callback. Route that payload to the active transfer instead of
            // dropping it and leaving the transfer continuation wedged.
            transferCallback?(json)
        }
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

final class FIFOOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if occupied {
                waiters.append(continuation)
                lock.unlock()
            } else {
                occupied = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func leave() {
        lock.lock()
        guard !waiters.isEmpty else {
            occupied = false
            lock.unlock()
            return
        }
        let continuation = waiters.removeFirst()
        lock.unlock()
        continuation.resume()
    }
}

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
    private let operationGate = FIFOOperationGate()

    private init() {
        self.jsonDecoder = JSONDecoder()
        self.mtpQueue = DispatchQueue(label: "com.macmtp.kalam", qos: .userInitiated)
    }

    private func beginOperation() async {
        await operationGate.enter()
    }

    private func endOperation() {
        operationGate.leave()
    }

    nonisolated func beginTransfer() {
        BeginTransfer()
    }

    nonisolated func cancelTransfer() {
        CancelTransfer()
    }

    private func waitForDone(startOperation: @escaping @Sendable () -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            KalamRegistry.shared.setDoneContinuation(continuation)
            startOperation()
        }
    }


    internal func executeMTP<T: Decodable>(
        operationName: String,
        _ operation: @escaping @Sendable () -> Void
    ) async throws -> T {
        await beginOperation()
        defer { endOperation() }

        let jsonString = try await waitForDone {
            self.mtpQueue.async { operation() }
        }
        return try decodeResponse(jsonString, operation: operationName)
    }

    internal func executeMTPWithInput<T: Decodable, I: Encodable>(
        operationName: String,
        _ input: I,
        _ operation: @escaping @Sendable (UnsafeMutablePointer<CChar>?) -> Void
    ) async throws -> T {
        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        await beginOperation()
        defer { endOperation() }

        let jsonString = try await waitForDone {
            self.mtpQueue.async {
                var cInput = inputJson.utf8CString
                cInput.withUnsafeMutableBufferPointer { buffer in
                    operation(buffer.baseAddress)
                }
            }
        }
        return try decodeResponse(jsonString, operation: operationName)
    }

    private func decodeResponse<T: Decodable>(_ json: String, operation: String) throws -> T {
        if let errResp = try? jsonDecoder.decode(GoErrorResponse.self, from: json.data(using: .utf8) ?? Data()),
           (errResp.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || errResp.errorType?.isEmpty == false) {
            throw nativeOperationError(
                operation: operation,
                errorType: errResp.errorType,
                message: errResp.error,
                fallback: "The MTP subsystem returned an error without details."
            )
        }

        do {
            return try jsonDecoder.decode(T.self, from: json.data(using: .utf8) ?? Data())
        } catch {
            throw nativeOperationError(
                operation: operation,
                errorType: nil,
                message: nil,
                fallback: "The MTP subsystem returned an invalid response."
            )
        }
    }


    public func initialize() async throws -> GoDeviceInfoData {
        let result: GoDeviceInfoResult = try await executeMTP(operationName: "initialize") {
            Initialize()
        }
        guard let data = result.data else {
            throw nativeOperationError(
                operation: "initialize",
                errorType: result.errorType,
                message: result.error,
                fallback: "The initialize response did not include device data."
            )
        }
        return data
    }

    public func fetchStorages() async throws -> [GoStorageData] {
        let result: GoStoragesResult = try await executeMTP(operationName: "fetch_storages") {
            FetchStorages()
        }
        return result.data
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

        let result: GoWalkResult = try await executeMTPWithInput(operationName: "list_directory", input) { inputJson in
            Walk(inputJson)
        }
        return result.data
    }

    public func makeDirectory(storageId: UInt32, path: String) async throws -> UInt32? {
        struct MakeDirectoryInput: Encodable {
            let storageId: UInt32
            let fullPath: String
        }

        let input = MakeDirectoryInput(storageId: storageId, fullPath: path)
        let result: GoSimpleResult = try await executeMTPWithInput(operationName: "make_directory", input) { inputJson in
            MakeDirectory(inputJson)
        }
        try validateSimpleMTPResult(
            result,
            operation: "make_directory",
            fallback: "The MTP subsystem did not confirm directory creation."
        )
        return result.objectId
    }

    public func deleteFiles(storageId: UInt32, paths: [String]) async throws {
        struct DeleteFileInput: Encodable {
            let storageId: UInt32
            let Files: [String]
        }

        let input = DeleteFileInput(storageId: storageId, Files: paths)
        let result: GoSimpleResult = try await executeMTPWithInput(operationName: "delete_files", input) { inputJson in
            DeleteFile(inputJson)
        }
        try validateSimpleMTPResult(
            result,
            operation: "delete_files",
            fallback: "The MTP subsystem did not confirm deletion."
        )
    }

    public func renameFile(storageId: UInt32, path: String, newName: String) async throws -> UInt32? {
        struct RenameFileInput: Encodable {
            let storageId: UInt32
            let fullPath: String
            let newFileName: String
        }

        let input = RenameFileInput(storageId: storageId, fullPath: path, newFileName: newName)
        let result: GoSimpleResult = try await executeMTPWithInput(operationName: "rename_file", input) { inputJson in
            RenameFile(inputJson)
        }
        try validateSimpleMTPResult(
            result,
            operation: "rename_file",
            fallback: "The MTP subsystem did not confirm renaming."
        )
        return result.objectId
    }

    public func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool] {
        struct FileExistsInput: Encodable {
            let storageId: UInt32
            let Files: [String]
        }

        let input = FileExistsInput(storageId: storageId, Files: paths)
        let result: GoFileExistsResult = try await executeMTPWithInput(operationName: "check_files_exist", input) { inputJson in
            FileExists(inputJson)
        }
        guard result.data.count == paths.count else {
            throw nativeOperationError(
                operation: "check_files_exist",
                errorType: nil,
                message: "Expected \(paths.count) results but received \(result.data.count).",
                fallback: "The file-existence response was incomplete."
            )
        }

        var resultMap = [String: Bool]()
        for entry in result.data {
            resultMap[entry.fullpath] = entry.exists
        }
        return try paths.map { path in
            guard let exists = resultMap[path] else {
                throw KalamError.invalidResponse
            }
            return exists
        }
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
            preprocessFiles: false
        )

        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        await beginOperation()
        defer { endOperation() }

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
                    KalamRegistry.shared.finishTransfer(with: decodeMTPTransferCompletion(json))
                }
            )

            beginTransfer()

            mtpQueue.async {
                var cInput = inputJson.utf8CString
                cInput.withUnsafeMutableBufferPointer { buffer in
                    UploadFiles(buffer.baseAddress)
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
            preprocessFiles: false
        )

        let inputData = try JSONEncoder().encode(input)
        guard let inputJson = String(data: inputData, encoding: .utf8) else {
            throw KalamError.serializationError
        }

        await beginOperation()
        defer { endOperation() }

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
                    KalamRegistry.shared.finishTransfer(with: decodeMTPTransferCompletion(json))
                }
            )

            beginTransfer()

            mtpQueue.async {
                var cInput = inputJson.utf8CString
                cInput.withUnsafeMutableBufferPointer { buffer in
                    DownloadFiles(buffer.baseAddress)
                }
            }
        }
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
        let _: GoSimpleResult = try await executeMTP(operationName: "dispose") {
            Dispose()
        }
    }

}
