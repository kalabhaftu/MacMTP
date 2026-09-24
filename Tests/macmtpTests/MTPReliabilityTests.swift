import Foundation
import Testing
@testable import macmtp

private actor TestEventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor RecordingMTPBridge: MTPBridge {
    private(set) var files: [GoFileInfo]
    private(set) var existenceChecks = 0
    private(set) var makeDirectoryCalls = 0
    private(set) var listDirectoryCalls = 0
    private(set) var initializeCalls: [MTPDeviceSelector] = []
    private(set) var disposeCalls = 0
    private let failListingAfterMutation: Bool
    private let initializeDelay: UInt64
    private let cancelInitialize: Bool
    private let cancelListing: Bool

    init(
        files: [GoFileInfo] = [],
        failListingAfterMutation: Bool = false,
        initializeDelay: UInt64 = 0,
        cancelInitialize: Bool = false,
        cancelListing: Bool = false
    ) {
        self.files = files
        self.failListingAfterMutation = failListingAfterMutation
        self.initializeDelay = initializeDelay
        self.cancelInitialize = cancelInitialize
        self.cancelListing = cancelListing
    }

    func initialize(selector: MTPDeviceSelector) async throws -> GoDeviceInfoData {
        initializeCalls.append(selector)
        if cancelInitialize {
            throw CancellationError()
        }
        if initializeDelay > 0 {
            try await Task.sleep(nanoseconds: initializeDelay)
        }
        return GoDeviceInfoData(
            mtpDeviceInfo: GoMtpDeviceInfo(
                Manufacturer: "Test",
                Model: "Test MTP",
                DeviceVersion: "1.0",
                SerialNumber: "test",
                StandardVersion: nil,
                MTPVendorExtensionID: nil,
                MTPVersion: nil,
                MTPExtension: nil,
                FunctionalMode: nil
            ),
            usbDeviceInfo: nil
        )
    }

    func discoverMTPDevices() async throws -> [MTPDeviceSelector] {
        [MTPDeviceSelector(vendorId: 0x1234, productId: 0x5678, serialNumber: "")]
    }

    func fetchStorages() async throws -> [GoStorageData] {
        [GoStorageData(
            Sid: 1,
            Info: GoStorageInfo(
                StorageType: 0,
                FilesystemType: 0,
                AccessCapability: 0,
                MaxCapability: 1_000,
                FreeSpaceInBytes: 500,
                FreeSpaceInImages: 0,
                StorageDescription: "Internal",
                VolumeLabel: ""
            )
        )]
    }

    func dispose() async throws {
        disposeCalls += 1
    }

    func listDirectory(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo] {
        listDirectoryCalls += 1
        if cancelListing {
            throw KalamError.nativeOperationFailed(
                operation: "list_directory",
                errorType: "ErrorTransferCancelled",
                message: "transfer cancelled"
            )
        }
        if failListingAfterMutation && makeDirectoryCalls > 0 {
            throw KalamError.timedOut("directory walk after mutation")
        }
        return files
    }

    func makeDirectory(storageId: UInt32, path: String) async throws -> UInt32? {
        makeDirectoryCalls += 1
        let name = (path as NSString).lastPathComponent
        files.append(GoFileInfo(
            size: 0,
            isFolder: true,
            dateAdded: "",
            name: name,
            path: path,
            parentPath: "/",
            extension: "",
            parentId: 0,
            objectId: 42
        ))
        return 42
    }

    func deleteFiles(storageId: UInt32, paths: [String]) async throws {
        files.removeAll { paths.contains($0.path) }
    }

    func renameFile(storageId: UInt32, path: String, newName: String) async throws -> UInt32? {
        nil
    }

    func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool] {
        existenceChecks += 1
        return paths.map { path in files.contains { $0.path == path } }
    }
}

@Test
func fifoOperationGatePreservesWaitingOrder() async {
    let gate = FIFOOperationGate()
    let log = TestEventLog()

    await gate.enter()
    let first = Task {
        await gate.enter()
        await log.append("first")
        gate.leave()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    let second = Task {
        await gate.enter()
        await log.append("second")
        gate.leave()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    gate.leave()

    await first.value
    await second.value
    let values = await log.values
    #expect(values == ["first", "second"])
}

@Test
func simpleMTPResponsesRequireTrueDataAndPreserveNativeErrorType() {
    do {
        try validateSimpleMTPResult(
            GoSimpleResult(error: nil, errorType: nil, data: false),
            operation: "make_directory",
            fallback: "Directory creation was not confirmed."
        )
        Issue.record("An incomplete response should fail validation")
    } catch let error as KalamError {
        #expect(error.localizedDescription.contains("Directory creation was not confirmed."))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        try validateSimpleMTPResult(
            GoSimpleResult(error: "Already exists", errorType: "ErrorDuplicate", data: false),
            operation: "make_directory",
            fallback: "Directory creation was not confirmed."
        )
        Issue.record("A native error response should fail validation")
    } catch let error as KalamError {
        guard case .nativeOperationFailed(_, let errorType, let message) = error else {
            Issue.record("Native response was normalized to the wrong error")
            return
        }
        #expect(errorType == "ErrorDuplicate")
        #expect(message == "Already exists")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func emptyDirectoryResponsesDecodeAsAnEmptyCollection() throws {
    let payload = #"{"error":"","errorType":"","data":[]}"#.data(using: .utf8)!
    let result = try JSONDecoder().decode(GoWalkResult.self, from: payload)

    #expect(result.data.isEmpty)
}

@Test
func mtpSelectorPreservesSerialNumber() throws {
    let payload = #"{"error":"","errorType":"","data":[{"vendorId":3725,"productId":8192,"serialNumber":"device-serial"}]}"#.data(using: .utf8)!
    let result = try JSONDecoder().decode(GoMTPDevicesResult.self, from: payload)

    #expect(result.data.count == 1)
    #expect(result.data[0].serialNumber == "device-serial")
}

@Test
func mtpSelectorPreservesDisplayMetadata() throws {
    let payload = #"{"error":"","errorType":"","data":[{"vendorId":1256,"productId":26720,"serialNumber":"samsung","manufacturer":"samsung","model":"SM-M055F"}]}"#.data(using: .utf8)!
    let result = try JSONDecoder().decode(GoMTPDevicesResult.self, from: payload)
    let selector = MTPDeviceSelector(
        vendorId: result.data[0].vendorId,
        productId: result.data[0].productId,
        serialNumber: result.data[0].serialNumber,
        manufacturer: result.data[0].manufacturer ?? "",
        model: result.data[0].model ?? ""
    )

    #expect(selector.displayName == "samsung SM-M055F")
}

@Test
func mtpSelectorIdentityIgnoresDisplayMetadataChanges() {
    let old = MTPDeviceSelector(
        vendorId: 0x04e8,
        productId: 0x6860,
        serialNumber: "samsung",
        manufacturer: "Samsung",
        model: "SM-M055F"
    )
    let refreshed = MTPDeviceSelector(
        vendorId: 0x04e8,
        productId: 0x6860,
        serialNumber: "samsung",
        manufacturer: "SAMSUNG",
        model: "Galaxy M05"
    )

    #expect(old == refreshed)
    #expect(Set([old, refreshed]).count == 1)
}

@Test
func usbRegistryNamesFillOnlyMissingSelectorNames() {
    let unnamed = MTPDeviceSelector(vendorId: 0x04e8, productId: 0x6860, serialNumber: "samsung")
    let nativeNamed = MTPDeviceSelector(
        vendorId: 0x0e8d,
        productId: 0x2008,
        serialNumber: "tecno",
        manufacturer: "TECNO",
        model: "KI7"
    )
    let usbNames = [
        USBDeviceNames(vendorID: 0x04e8, productID: 0x6860, manufacturer: "SAMSUNG", product: "SAMSUNG_Android"),
        USBDeviceNames(vendorID: 0x0e8d, productID: 0x2008, manufacturer: "USB TECNO", product: "USB KI7")
    ]

    let named = fillMissingMTPSelectorNames([unnamed, nativeNamed], from: usbNames)
    let samsung = named.first { $0.vendorId == 0x04e8 && $0.productId == 0x6860 }
    let tecno = named.first { $0.vendorId == 0x0e8d && $0.productId == 0x2008 }
    #expect(samsung?.manufacturer == "SAMSUNG")
    #expect(samsung?.model == "SAMSUNG_Android")
    #expect(tecno?.manufacturer == "TECNO")
    #expect(tecno?.model == "KI7")
    #expect(MTPDeviceSelector(vendorId: 1, productId: 2, serialNumber: "").displayName == "MTP 0x0001:0x0002")
}

@Test
func usbNameMetadataDoesNotChangeUSBDeviceIdentity() {
    let previous = USBDeviceIdentity(vendorID: 0x04e8, productID: 0x6860, locationID: 1, serialNumber: "samsung")
    let refreshed = USBDeviceIdentity(vendorID: 0x04e8, productID: 0x6860, locationID: 1, serialNumber: "samsung")
    let oldNames = USBDeviceNames(vendorID: 0x04e8, productID: 0x6860, manufacturer: "SAMSUNG", product: "SAMSUNG_Android")
    let newNames = USBDeviceNames(vendorID: 0x04e8, productID: 0x6860, manufacturer: "Samsung", product: "SM-M055F")

    #expect(oldNames != newNames)
    #expect(previous == refreshed)
    #expect(!usbInventoryChanged(previous: [previous], current: [refreshed]))
}

@Test
func activeMTPModelReplacesGenericUSBProductName() {
    let samsung = MTPDeviceSelector(
        vendorId: 0x04e8,
        productId: 0x6860,
        serialNumber: "samsung",
        manufacturer: "SAMSUNG",
        model: "SAMSUNG_Android"
    )
    let deviceInfo = MTPDeviceInfo(
        manufacturer: "Samsung",
        model: "SM-M055F",
        serialNumber: "samsung",
        deviceVersion: "1.0",
        storages: []
    )
    let active = fillMissingMTPSelectorNames(
        [samsung],
        from: [],
        activeSelector: samsung,
        activeDeviceInfo: deviceInfo
    ).first

    #expect(active?.displayName == "Samsung SM-M055F")
}

@Test
func failedMTPSelectorsStayListedWithoutReplacingTheActiveDevice() {
    let samsung = MTPDeviceSelector(vendorId: 0x04e8, productId: 0x6860, serialNumber: "samsung", model: "Samsung")
    let tecno = MTPDeviceSelector(vendorId: 0x0e8d, productId: 0x2008, serialNumber: "tecno", model: "TECNO")
    let inventory: Set<USBDeviceIdentity> = [
        USBDeviceIdentity(vendorID: samsung.vendorId, productID: samsung.productId, locationID: 1, serialNumber: samsung.serialNumber),
        USBDeviceIdentity(vendorID: tecno.vendorId, productID: tecno.productId, locationID: 2, serialNumber: tecno.serialNumber)
    ]

    let merged = mergeMTPSelectors(
        discovered: [tecno],
        active: samsung,
        activeConnected: true,
        failed: [samsung],
        inventory: inventory
    )

    #expect(merged == Set([samsung, tecno]))
}

@Test
func failedMTPSelectorsAreRetriedAfterHealthyCandidates() {
    let failed = MTPDeviceSelector(vendorId: 0x04e8, productId: 0x6860, serialNumber: "samsung", model: "Samsung")
    let healthy = MTPDeviceSelector(vendorId: 0x0e8d, productId: 0x2008, serialNumber: "tecno", model: "TECNO")

    #expect(orderedMTPConnectionCandidates([failed, healthy], failed: [failed]) == [healthy, failed])
}

@Test
func matchedSelectorOpenTimeoutRemainsRetryable() {
    let timeout = KalamError.nativeOperationFailed(
        operation: "initialize",
        errorType: "ErrorMtpDetectFailed",
        message: "opening MTP device vendor=0x04e8 product=0x6860: LIBUSB_ERROR_TIMEOUT"
    )
    let absent = KalamError.nativeOperationFailed(
        operation: "initialize",
        errorType: "ErrorMtpDetectFailed",
        message: "no MTP device matched vendor=0x04e8 product=0x6860"
    )

    #expect(!isMTPDeviceUnavailable(timeout))
    #expect(isMTPDeviceUnavailable(absent))
}

@Test
func mtpRecoveryRetriesUseQuietBoundedBackoff() {
    #expect(mtpRecoveryDelayNanoseconds(attempt: 1) == 2_000_000_000)
    #expect(mtpRecoveryDelayNanoseconds(attempt: 2) == 4_000_000_000)
}

@Test @MainActor
func switchingDevicesDisposesTheOldSessionBeforeInitializingTheNewOne() async {
    let bridge = RecordingMTPBridge()
    let manager = MTPDeviceManager(bridge: bridge)
    let first = MTPDeviceSelector(vendorId: 0x1234, productId: 0x5678, serialNumber: "first", model: "First")
    let second = MTPDeviceSelector(vendorId: 0x04e8, productId: 0x6860, serialNumber: "second", model: "Second")

    #expect(await manager.connectDevice(selector: first))
    #expect(await manager.switchDevice(to: second))
    #expect(manager.activeSelector == second)
    #expect(await bridge.disposeCalls == 1)
    #expect(await bridge.initializeCalls == [first, second])
}

@Test @MainActor
func cancelledDirectoryRefreshPreservesConnectionAndErrorState() async {
    let manager = MTPDeviceManager(bridge: RecordingMTPBridge(cancelListing: true))
    _ = await manager.connectDevice(selector: MTPDeviceSelector(vendorId: 0x1234, productId: 0x5678, serialNumber: ""))

    manager.errorMessage = nil
    await manager.refreshFiles()

    #expect(manager.isConnected)
    #expect(manager.errorMessage == nil)
}

@Test
func mutationResponsesPreserveNativeObjectIdentifiers() throws {
    let payload = #"{"error":"","errorType":"","data":true,"objectId":42}"#.data(using: .utf8)!
    let result = try JSONDecoder().decode(GoSimpleResult.self, from: payload)

    #expect(result.data == true)
    #expect(result.objectId == 42)
}

@Test
func mtpFolderNamesAreTrimmedAndInvalidNamesRejected() {
    do {
        #expect(try normalizedMTPChildName("  New Folder  ") == "New Folder")
        _ = try normalizedMTPChildName("folder/name")
        Issue.record("Path separators should be rejected")
    } catch let error as KalamError {
        #expect(error.localizedDescription.contains("path separators"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func invalidLocalFilenamesAreRejectedWithoutRenaming() {
    #expect(PathValidation.isValidLocalFilename("photo.jpg"))
    #expect(!PathValidation.isValidLocalFilename("folder/name"))
    #expect(!PathValidation.isValidLocalFilename("photo:"))
    #expect(!PathValidation.isValidLocalFilename("photo."))
}

@Test
func connectionStatesExposeActionableStatus() {
    #expect(MTPConnectionState.usbAbsent.title == "USB device not connected")
    #expect(MTPConnectionState.deviceFound.detail.contains("Select File Transfer (MTP)"))
    #expect(MTPConnectionState.connecting(attempt: 2).title == "Connecting, attempt 2 of 2")
    #expect(MTPConnectionState.connected.detail == "Connected via USB")
}

@Test
func duplicateMTPFolderErrorsAreExplicit() {
    let error = KalamError.itemAlreadyExists("New Folder")
    #expect(error.localizedDescription == "A file or folder named \"New Folder\" already exists in this directory.")
    #expect(ErrorLogger.shouldReport(error) == false)
}

@Test
func refreshRequestsOnlyShareWhenStoragePathAndVisibilityMatch() {
    let request = MTPDirectoryRefreshKey(storageId: 1, path: "/", showHidden: false)
    #expect(MTPRefreshRules.sharesRequest(active: request, requested: request))
    #expect(!MTPRefreshRules.sharesRequest(
        active: request,
        requested: MTPDirectoryRefreshKey(storageId: 1, path: "/DCIM", showHidden: false)
    ))
    #expect(!MTPRefreshRules.sharesRequest(
        active: request,
        requested: MTPDirectoryRefreshKey(storageId: 1, path: "/", showHidden: true)
    ))
}

@Test
@MainActor
func directoryCoordinatorCoalescesSameRefreshAndKeepsSnapshotsKeyed() async {
    let coordinator = MTPDirectoryCoordinator()
    let request = MTPDirectoryRefreshKey(storageId: 7, path: "/DCIM", showHidden: false)

    #expect(coordinator.beginRefresh(for: request))
    #expect(!coordinator.beginRefresh(for: request))

    let waiter = Task { @MainActor in
        await coordinator.waitForActiveRefresh()
    }
    try? await Task.sleep(nanoseconds: 10_000_000)
    #expect(coordinator.activeRefreshWaiterCount == 1)

    let node = FileNode(name: "photo.jpg", path: "/DCIM/photo.jpg", parentPath: "/DCIM")
    coordinator.recordSuccessfulListing([node], for: request)
    coordinator.finishRefresh(for: request)
    await waiter.value

    #expect(coordinator.snapshot?.key == request)
    #expect(coordinator.snapshot?.files.map(\.path) == ["/DCIM/photo.jpg"])
    #expect(coordinator.refreshSucceeded(for: request))

    #expect(coordinator.beginRefresh(for: request))
    coordinator.recordFailedRefresh(for: request)
    coordinator.finishRefresh(for: request)
    #expect(!coordinator.refreshSucceeded(for: request))
}

@Test
func mutationReconciliationUsesCanonicalPaths() {
    let original = FileNode(name: "old", path: "/old", parentPath: "/")
    let renamed = MTPDirectoryMutation.rename(oldPath: "/old", newPath: "/new")
    let renamedFiles = MTPDirectoryReconciliation.applying(renamed, to: [original])

    #expect(MTPDirectoryReconciliation.isSatisfied(renamed, by: renamedFiles))
    #expect(renamedFiles.first?.path == "/new")

    let deleted = MTPDirectoryMutation.delete(paths: ["/new"])
    #expect(MTPDirectoryReconciliation.isSatisfied(
        deleted,
        by: MTPDirectoryReconciliation.applying(deleted, to: renamedFiles)
    ))
}

@Test
func listingFirstPreflightDetectsDuplicatesWithoutASecondNativeProbe() {
    let existing = FileNode(name: "New Folder", path: "/New Folder", parentPath: "/", isDirectory: true)
    let request = MTPDirectoryRefreshKey(storageId: 1, path: "/", showHidden: false)
    let snapshot = MTPDirectorySnapshot(key: request, files: [existing])

    #expect(MTPDirectoryPreflight.destinationExists(in: snapshot, path: existing.path))
    #expect(!MTPDirectoryPreflight.destinationExists(in: snapshot, path: "/Other"))
    #expect(!MTPDirectoryPreflight.destinationExists(in: snapshot, path: existing.path, excluding: existing.path))
}

@Test
@MainActor
func managerUsesCurrentListingForDuplicatesAndPublishesCreates() async throws {
    let existing = GoFileInfo(
        size: 0,
        isFolder: true,
        dateAdded: "",
        name: "Existing",
        path: "/Existing",
        parentPath: "/",
        extension: "",
        parentId: 0,
        objectId: 9
    )
    let bridge = RecordingMTPBridge(files: [existing])
    let manager = MTPDeviceManager(bridge: bridge)
    await manager.connectDevice()

    do {
        try await manager.createFolder(name: " Existing ", in: "/")
        Issue.record("The current listing should reject a duplicate folder")
    } catch let error as KalamError {
        guard case .itemAlreadyExists("Existing") = error else {
            Issue.record("Duplicate listing was normalized to the wrong error")
            return
        }
    }
    #expect(await bridge.existenceChecks == 0)
    #expect(await bridge.makeDirectoryCalls == 0)

    try await manager.createFolder(name: "  New Folder  ", in: "/")
    #expect(await bridge.makeDirectoryCalls == 1)
    #expect(manager.mtpFiles.contains { $0.path == "/New Folder" })
}

@Test
@MainActor
func confirmedCreateDoesNotPerformASecondWalkAfterNativeSuccess() async throws {
    let bridge = RecordingMTPBridge(failListingAfterMutation: true)
    let manager = MTPDeviceManager(bridge: bridge)
    await manager.connectDevice()

    try await manager.createFolder(name: "New Folder", in: "/")

    #expect(await bridge.listDirectoryCalls == 1)
    #expect(manager.isConnected)
    #expect(manager.mtpFiles.contains { $0.path == "/New Folder" })
    #expect(!manager.isPerformingMutation)
}

@Test
func usbLifecycleRejectsStaleConnectionCompletions() {
    var lifecycle = USBConnectionLifecycle()
    let first = lifecycle.attachScheduled()
    _ = lifecycle.detached()
    let second = lifecycle.attachScheduled()

    #expect(!lifecycle.accepts(first))
    #expect(lifecycle.accepts(second))
}

@Test
func usbLifecycleInvalidatesRapidReplugAndDetachTokens() {
    var lifecycle = USBConnectionLifecycle()
    let first = lifecycle.attachScheduled()
    let second = lifecycle.attachScheduled()
    #expect(!lifecycle.accepts(first))
    #expect(lifecycle.accepts(second))

    _ = lifecycle.detached()
    #expect(!lifecycle.accepts(second))
    let third = lifecycle.attachScheduled()
    #expect(lifecycle.accepts(third))
}

@Test @MainActor
func staleConnectionCompletionCannotLeaveTheManagerLoading() async {
    let bridge = RecordingMTPBridge(initializeDelay: 100_000_000)
    let manager = MTPDeviceManager(bridge: bridge)
    let connection = Task { await manager.connectDevice() }

    while !manager.isLoading {
        await Task.yield()
    }
    manager.invalidateConnection(message: "Disconnected during connection")
    _ = await connection.value

    #expect(!manager.isLoading)
}

@Test @MainActor
func cancelledConnectionDoesNotPublishAnError() async {
    let manager = MTPDeviceManager(bridge: RecordingMTPBridge(cancelInitialize: true))
    let connected = await manager.connectDevice()

    #expect(!connected)
    #expect(!manager.isLoading)
    #expect(manager.errorMessage == nil)
}

@Test
func duplicateUSBNotificationsDoNotScheduleAnotherDevice() {
    let identity = USBDeviceIdentity(vendorID: 0x1234, productID: 0x5678, locationID: 1, serialNumber: "test")
    let otherIdentity = USBDeviceIdentity(vendorID: 0x1234, productID: 0x5679, locationID: 2, serialNumber: "other")

    #expect(newlyAttachedUSBIdentities([identity, identity], known: []) == [identity])
    #expect(newlyAttachedUSBIdentities([identity, otherIdentity], known: [identity]) == [otherIdentity])
}

@Test
func failedConnectionRetriesWhenThePhoneIsReattached() {
    let phone = USBDeviceIdentity(vendorID: 0x0e8d, productID: 0x2008, locationID: 1, serialNumber: "phone")
    let accessory = USBDeviceIdentity(vendorID: 0x1234, productID: 0x5678, locationID: 2, serialNumber: "accessory")

    #expect(newlyAttachedUSBIdentities([accessory], known: [phone, accessory]).isEmpty)
    #expect(newlyAttachedUSBIdentities([phone, accessory], known: [accessory]) == [phone])
}

@Test
func cancellationRecoveryFailureTriggersAutomaticReconnect() {
    let recoveryFailure = KalamError.nativeOperationFailed(
        operation: "transfer",
        errorType: "ErrorFileTransfer",
        message: "MTP cancellation recovery failed transaction=0x17: verify MTP session after cancellation: got stale response container; transport closed for quiet reopen"
    )
    let legacyRecoveryFailure = KalamError.nativeOperationFailed(
        operation: "transfer",
        errorType: "ErrorFileTransfer",
        message: "MTP cancellation requires reconnect transaction=0x17 reset=<nil>"
    )
    let expectedCancellation = KalamError.nativeOperationFailed(
        operation: "transfer",
        errorType: "ErrorTransferCancelled",
        message: "transfer cancelled"
    )

    #expect(isMTPCancellationRecoveryFailure(recoveryFailure))
    #expect(isMTPTransportFailure(recoveryFailure))
    #expect(isMTPCancellationRecoveryFailure(legacyRecoveryFailure))
    #expect(!isMTPCancellationRecoveryFailure(expectedCancellation))
    #expect(shouldPresentAsCancelledAfterRecoveryFailure(recoveryFailure, cancelRequested: true))
    #expect(!shouldPresentAsCancelledAfterRecoveryFailure(recoveryFailure, cancelRequested: false))
    #expect(!shouldPresentAsCancelledAfterRecoveryFailure(expectedCancellation, cancelRequested: true))
}

@Test
func transportTimeoutTriggersAutomaticReconnect() {
    let timeout = KalamError.nativeOperationFailed(
        operation: "SendObject",
        errorType: "ErrorFileTransfer",
        message: "LIBUSB_ERROR_TIMEOUT"
    )
    let cancellation = KalamError.nativeOperationFailed(
        operation: "SendObject",
        errorType: "ErrorTransferCancelled",
        message: "transfer cancelled"
    )
    let staleHandle = KalamError.nativeOperationFailed(
        operation: "GetObjectHandles",
        errorType: "ErrorDeviceLocked",
        message: "device is not open"
    )

    #expect(shouldAutomaticallyReconnectMTP(timeout))
    #expect(shouldAutomaticallyReconnectMTP(staleHandle))
    #expect(!shouldAutomaticallyReconnectMTP(cancellation))
}

@Test
func unchangedUSBInventoryDoesNotNeedAnotherConnectionGeneration() {
    let identity = USBDeviceIdentity(vendorID: 0x0e8d, productID: 0x2008, locationID: 1, serialNumber: "phone")
    #expect(!usbInventoryChanged(previous: [identity], current: [identity]))
    #expect(usbInventoryChanged(previous: [identity], current: []))
}

@Test
func nativeMTPIdentityDoesNotMatchAnUnrelatedUSBDevice() {
    let phone = USBDeviceIdentity(vendorID: 0x1234, productID: 0x5678, locationID: 1, serialNumber: "phone")
    let accessory = USBDeviceIdentity(vendorID: 0x1234, productID: 0x5679, locationID: 2, serialNumber: "accessory")

    #expect(phone.matches(vendorID: 0x1234, productID: 0x5678, serialNumber: "phone"))
    #expect(!accessory.matches(vendorID: 0x1234, productID: 0x5678, serialNumber: "phone"))
}

@Test
func missingUSBSerialFallsBackToVendorAndProduct() {
    let device = USBDeviceIdentity(vendorID: 0x1234, productID: 0x5678, locationID: 1, serialNumber: nil)

    #expect(device.matches(vendorID: 0x1234, productID: 0x5678, serialNumber: "phone"))
}

@Test
func duplicateMTPStoragesWithIdenticalCapacityAndFreeSpaceAreDeduplicated() {
    let raw = [
        MTPStorageInfo(
            storageId: 0x00010001,
            description: "Internal shared storage",
            totalCapacity: 255_848_574_976,
            freeSpace: 181_467_475_968,
            storageType: .internal
        ),
        MTPStorageInfo(
            storageId: 0x00020001,
            description: "Internal shared storage",
            totalCapacity: 255_848_574_976,
            freeSpace: 181_467_475_968,
            storageType: .internal
        ),
    ]

    let processed = MTPStorageInfo.processRawStorages(raw)
    #expect(processed.count == 1)
    #expect(processed.first?.storageId == 0x00010001)
    #expect(processed.first?.description == "Internal shared storage")
}

@Test
func distinctStoragesWithDifferentTypesOrCapacitiesArePreserved() {
    let raw = [
        MTPStorageInfo(
            storageId: 0x00010001,
            description: "Internal shared storage",
            totalCapacity: 255_848_574_976,
            freeSpace: 181_467_475_968,
            storageType: .internal
        ),
        MTPStorageInfo(
            storageId: 0x00020001,
            description: "SD Card",
            totalCapacity: 64_000_000_000,
            freeSpace: 32_000_000_000,
            storageType: .sdCard
        ),
    ]

    let processed = MTPStorageInfo.processRawStorages(raw)
    #expect(processed.count == 2)
    #expect(processed[0].storageId == 0x00010001)
    #expect(processed[1].storageId == 0x00020001)
    #expect(processed[1].storageType == .sdCard)
}

@Test
func nonDuplicateStoragesSharingSameDescriptionAreDisambiguated() {
    let raw = [
        MTPStorageInfo(
            storageId: 0x00010001,
            description: "Internal Storage",
            totalCapacity: 128_000_000_000,
            freeSpace: 80_000_000_000,
            storageType: .internal
        ),
        MTPStorageInfo(
            storageId: 0x00020001,
            description: "Internal Storage",
            totalCapacity: 128_000_000_000,
            freeSpace: 20_000_000_000,
            storageType: .internal
        ),
    ]

    let processed = MTPStorageInfo.processRawStorages(raw)
    #expect(processed.count == 2)
    #expect(processed[0].description == "Internal Storage (1)")
    #expect(processed[1].description == "Internal Storage (2)")
}
