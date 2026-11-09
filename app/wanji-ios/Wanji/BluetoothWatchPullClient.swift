import Foundation
import CoreBluetooth
import CryptoKit

private struct WatchPullQueueItem: Decodable {
    let id: String?
    let externalID: String?
    let createdAt: Double?
    let durationMs: Double?
    let size: Int?
    let attempts: Int?
    let sha256: String?
    let mtu: Int?
    let notifyPayload: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case shortID = "i"
        case fullID = "f"
        case externalID
        case createdAt
        case durationMs
        case size
        case compactSize = "s"
        case attempts
        case sha256
        case mtu
        case notifyPayload
    }

    init(id: String,
         externalID: String? = nil,
         createdAt: Double? = nil,
         durationMs: Double? = nil,
         size: Int,
         attempts: Int? = nil,
         sha256: String? = nil,
         mtu: Int? = nil,
         notifyPayload: Int? = nil) {
        self.id = id
        self.externalID = externalID ?? id
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.size = size
        self.attempts = attempts
        self.sha256 = sha256
        self.mtu = mtu
        self.notifyPayload = notifyPayload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fullID = try container.decodeIfPresent(String.self, forKey: .fullID)
            ?? container.decodeIfPresent(String.self, forKey: .externalID)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .shortID)
        externalID = fullID ?? id
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
            ?? container.decodeIfPresent(Int.self, forKey: .compactSize)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        mtu = try container.decodeIfPresent(Int.self, forKey: .mtu)
        notifyPayload = try container.decodeIfPresent(Int.self, forKey: .notifyPayload)
    }
}

final class BluetoothWatchPullClient: NSObject, ObservableObject {
    private enum AdvertisementMatch: String {
        case none
        case wanjiMarker
        case watchNameFallback
    }

    @Published private(set) var status = "等待同步"
    @Published private(set) var lastEvent = ReceiverEvent(message: "手机会主动连接手表同步录音",
                                                          severity: .info,
                                                          occurredAt: Date())
    @Published private(set) var syncing = false

    var onAudioReceived: ((Data, String, Date?, Int64?, String?) async throws -> String)?

    private let serviceUUID = CBUUID(string: AppSettings.watchPullServiceUUID)
    private let discoveryUUID = CBUUID(string: AppSettings.watchSyncServiceUUID)
    private let queueUUID = CBUUID(string: AppSettings.watchPullQueueCharacteristicUUID)
    private let controlUUID = CBUUID(string: AppSettings.watchPullControlCharacteristicUUID)
    private let dataUUID = CBUUID(string: AppSettings.watchPullDataCharacteristicUUID)
    private let ackUUID = CBUUID(string: AppSettings.watchPullAckCharacteristicUUID)
    private let maxAudioBytes = 30 * 1024 * 1024
    private let maxResumeAttempts = 6
    private let notifyQuietTimeout: TimeInterval = 12.0
    private let notifyFirstChunkTimeout: TimeInterval = 25.0
    private let readQuietTimeout: TimeInterval = 8.0
    private let notificationEnableFallbackDelay: TimeInterval = 1.0
    private let notifyChunkHeaderBytes = 8
    private let minEfficientNotifyPayloadBytes = 64
    private let notifyCreditWindowBytes = 24576
    private let narrowScanFallbackDelay: TimeInterval = 0.35
    private let broadScanTimeout: TimeInterval = 4.5
    private let queueReadSettleDelay: TimeInterval = 0.12
    private let ackContinueQueueReadDelay: TimeInterval = 0.06
    private let ackWriteTimeout: TimeInterval = 2.0
    private let pendingAckDefaultsKey = "wanji.watchPull.pendingAckID"
    private let rememberedPeripheralDefaultsKey = "wanji.watchPull.rememberedPeripheralIDs"
    private let seededWatchPeripheralIDStrings: [String] = []
    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var queueCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var ackCharacteristic: CBCharacteristic?
    private var currentItem: WatchPullQueueItem?
    private var currentData = Data()
    private var currentOffset = 0
    private var lastReportedPercent = -1
    private var lastLoggedChunkOffset = 0
    private var transferStartedAt: Date?
    private var lastThroughputLogAt: Date?
    private var lastThroughputLogOffset = 0
    private var completedItemsThisSync = 0
    private var resumeAttempts = 0
    private var scanStopWorkItem: DispatchWorkItem?
    private var scanRetryWorkItem: DispatchWorkItem?
    private var pendingSync = false
    private var scanGeneration = 0
    private var broadScanActive = false
    private var ignoredBroadDiscoveries = 0
    private var activeScanRetryAttempt = 0
    private var dataNotifyReady = false
    private var awaitingAckID: String?
    private var continueAfterAck = false
    private var nextSyncWorkItem: DispatchWorkItem?
    private var chunkWatchdogWorkItem: DispatchWorkItem?
    private var queueReadWatchdogWorkItem: DispatchWorkItem?
    private var queueReadDelayWorkItem: DispatchWorkItem?
    private var notificationFallbackWorkItem: DispatchWorkItem?
    private var ackWatchdogWorkItem: DispatchWorkItem?
    private var transferRequestInFlight = false
    private var waitingForDataRead = false
    private var readOnlyTransfer = false
    private var dataReadRetries = 0
    private var notifyCreditEndOffset = 0
    private var pacedChunkDelay: TimeInterval = 0
    private var lastTimeoutOffset = -1
    private var sameOffsetTimeouts = 0
    private var queueReadRetries = 0
    private var controlFailureQueueRetries = 0
    private var controlFailureItemID: String?
    private var characteristicDiscoveryRetries = 0
    private var characteristicDiscoveryReconnects = 0
    private let maxQueueReadRetries = 4
    private let maxDataReadRetries = 2
    private let maxScanRetryAttempts = 2
    private let maxControlFailureQueueRetries = 1
    private let maxChecksumRetries = 1
    private let maxCharacteristicDiscoveryRetries = 2
    private let maxCharacteristicDiscoveryReconnects = 2
    private var checksumRetryAttempts = 0
    private var targetMatchedByNameFallback = false
    private var retrievedConnectAttemptedIDs = Set<String>()

    func start() {
        debugLog("pull start centralExists=\(central != nil)")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        debugLog("pull stop")
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        scanRetryWorkItem?.cancel()
        scanRetryWorkItem = nil
        nextSyncWorkItem?.cancel()
        nextSyncWorkItem = nil
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        pendingSync = false
        awaitingAckID = nil
        continueAfterAck = false
        activeScanRetryAttempt = 0
        if let target {
            central?.cancelPeripheralConnection(target)
        }
        central?.stopScan()
        resetSession()
        syncing = false
    }

    func syncNow(reason: String = "manual") {
        let bound = UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey)
        debugLog("pull sync requested reason=\(reason) bound=\(bound) tokenConfigured=\(tokenConfigured) syncing=\(syncing) centralExists=\(central != nil)")
        guard bound else {
            debugLog("pull sync skipped bound=false")
            setStatus("等待绑定手表", severity: .warning)
            return
        }
        if syncing {
            debugLog("pull sync ignored already syncing target=\(target != nil)")
            return
        }
        completedItemsThisSync = 0
        characteristicDiscoveryRetries = 0
        characteristicDiscoveryReconnects = 0
        retrievedConnectAttemptedIDs.removeAll()
        pendingSync = true
        syncing = true
        start()
        guard let central else {
            debugLog("pull sync pending central=nil")
            return
        }
        guard central.state == .poweredOn else {
            debugLog("pull sync deferred bluetooth state=\(central.state.rawValue)")
            if central.state == .unknown || central.state == .resetting {
                setStatus("手机蓝牙准备中", severity: .processing)
            } else {
                pendingSync = false
                syncing = false
                setStatus("手机蓝牙未就绪", severity: .warning)
            }
            return
        }
        scan(preservingTransfer: false)
    }

    private func scan(preservingTransfer: Bool,
                      preserveQueueRetries: Bool = false,
                      retryAttempt: Int = 0) {
        guard let central else { return }
        scanRetryWorkItem?.cancel()
        scanRetryWorkItem = nil
        activeScanRetryAttempt = retryAttempt
        resetSession(preserveTransfer: preservingTransfer,
                     preserveQueueRetries: preserveQueueRetries)
        scanGeneration += 1
        broadScanActive = false
        ignoredBroadDiscoveries = 0
        let suffix = scanAttemptSuffix(retryAttempt)
        if connectRememberedPeripheralIfAvailable(preservingTransfer: preservingTransfer,
                                                  preserveQueueRetries: preserveQueueRetries,
                                                  retryAttempt: retryAttempt,
                                                  suffix: suffix) {
            return
        }
        setStatus(preservingTransfer ? "重新连接手表录音\(suffix)" : "查找手表录音\(suffix)",
                  severity: .info)
        central.stopScan()
        central.scanForPeripherals(withServices: [discoveryUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        debugLog("pull scan narrow discoveryService=\(discoveryUUID.uuidString) generation=\(scanGeneration) retry=\(retryAttempt)")
        let generation = scanGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.scanGeneration == generation, self.target == nil else { return }
            self.broadScanActive = true
            self.ignoredBroadDiscoveries = 0
            self.central?.stopScan()
            self.setStatus("扩大查找手表录音\(suffix)", severity: .info)
            self.debugLog("pull scan broad generation=\(generation)")
            self.central?.scanForPeripherals(withServices: nil,
                                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            let finalItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == generation, self.target == nil else { return }
                self.central?.stopScan()
                self.broadScanActive = false
                self.debugLog("pull scan timeout generation=\(generation) ignoredBroad=\(self.ignoredBroadDiscoveries)")
                if self.scheduleScanRetryIfNeeded(after: retryAttempt,
                                                   preservingTransfer: preservingTransfer,
                                                   preserveQueueRetries: preserveQueueRetries,
                                                   reason: "timeout") {
                    return
                }
                self.pendingSync = false
                self.syncing = false
                let message = self.ignoredBroadDiscoveries > 0
                    ? "未发现腕记蓝牙服务"
                    : "未发现手表录音服务"
                self.setStatus(message, severity: .warning)
                self.resetSession()
            }
            self.scanStopWorkItem = finalItem
            DispatchQueue.main.asyncAfter(deadline: .now() + broadScanTimeout, execute: finalItem)
        }
        scanStopWorkItem?.cancel()
        scanStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + narrowScanFallbackDelay, execute: item)
    }

    private func scanAttemptSuffix(_ retryAttempt: Int) -> String {
        retryAttempt <= 0 ? "" : " · 第 \(retryAttempt + 1) 次"
    }

    @discardableResult
    private func scheduleScanRetryIfNeeded(after retryAttempt: Int,
                                           preservingTransfer: Bool,
                                           preserveQueueRetries: Bool,
                                           reason: String) -> Bool {
        guard pendingSync,
              syncing,
              retryAttempt < maxScanRetryAttempts else {
            return false
        }
        let nextAttempt = retryAttempt + 1
        let delay = min(2.0 + Double(retryAttempt), 4.0)
        scanRetryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingSync, self.syncing, self.target == nil else { return }
            self.debugLog("pull scan auto retry firing attempt=\(nextAttempt) reason=\(reason)")
            self.scan(preservingTransfer: preservingTransfer,
                      preserveQueueRetries: preserveQueueRetries,
                      retryAttempt: nextAttempt)
        }
        scanRetryWorkItem = item
        setStatus("继续查找手表录音", severity: .info)
        debugLog("pull scan auto retry scheduled attempt=\(nextAttempt) delay=\(String(format: "%.1f", delay)) reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return true
    }

    @discardableResult
    private func connectRememberedPeripheralIfAvailable(preservingTransfer: Bool,
                                                        preserveQueueRetries: Bool,
                                                        retryAttempt: Int,
                                                        suffix: String) -> Bool {
        guard let central else { return false }
        let ids = rememberedPeripheralIDs()
            .filter { !retrievedConnectAttemptedIDs.contains($0.uuidString) }
        guard !ids.isEmpty else { return false }
        let peripherals = central.retrievePeripherals(withIdentifiers: ids)
        guard let peripheral = peripherals.first(where: { !retrievedConnectAttemptedIDs.contains($0.identifier.uuidString) }) else {
            debugLog("pull retrieve remembered peripherals none ids=\(ids.map { $0.uuidString }.joined(separator: ","))")
            return false
        }
        retrievedConnectAttemptedIDs.insert(peripheral.identifier.uuidString)
        scanStopWorkItem?.cancel()
        central.stopScan()
        broadScanActive = false
        target = peripheral
        targetMatchedByNameFallback = false
        peripheral.delegate = self
        setStatus(preservingTransfer ? "重新连接已记录手表\(suffix)" : "连接已记录手表录音\(suffix)",
                  severity: .processing)
        debugLog("pull retrieve remembered peripheral id=\(peripheral.identifier.uuidString) generation=\(scanGeneration) retry=\(retryAttempt)")
        central.connect(peripheral)

        let generation = scanGeneration
        let item = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.scanGeneration == generation, self.target === peripheral else { return }
            self.debugLog("pull retrieve remembered connect timeout id=\(peripheral.identifier.uuidString) generation=\(generation)")
            self.central?.cancelPeripheralConnection(peripheral)
            self.target = nil
            self.scan(preservingTransfer: preservingTransfer,
                      preserveQueueRetries: preserveQueueRetries,
                      retryAttempt: retryAttempt)
        }
        scanStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
        return true
    }

    private func rememberedPeripheralIDs() -> [UUID] {
        let stored = UserDefaults.standard.stringArray(forKey: rememberedPeripheralDefaultsKey) ?? []
        var seen = Set<String>()
        return (stored + seededWatchPeripheralIDStrings).compactMap { value in
            guard let uuid = UUID(uuidString: value) else { return nil }
            guard seen.insert(uuid.uuidString).inserted else { return nil }
            return uuid
        }
    }

    private func rememberWatchPeripheral(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        var ids = UserDefaults.standard.stringArray(forKey: rememberedPeripheralDefaultsKey) ?? []
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > 8 {
            ids = Array(ids.prefix(8))
        }
        UserDefaults.standard.set(ids, forKey: rememberedPeripheralDefaultsKey)
    }

    private func forgetWatchPeripheral(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        var ids = UserDefaults.standard.stringArray(forKey: rememberedPeripheralDefaultsKey) ?? []
        let oldCount = ids.count
        ids.removeAll { $0 == id }
        if ids.count != oldCount {
            UserDefaults.standard.set(ids, forKey: rememberedPeripheralDefaultsKey)
            debugLog("pull forgot incomplete peripheral id=\(id)")
        }
    }

    private func resetSession(preserveTransfer: Bool = false,
                              preserveQueueRetries: Bool = false) {
        target = nil
        targetMatchedByNameFallback = false
        queueCharacteristic = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        ackCharacteristic = nil
        dataNotifyReady = false
        awaitingAckID = nil
        continueAfterAck = false
        transferRequestInFlight = false
        waitingForDataRead = false
        readOnlyTransfer = false
        dataReadRetries = 0
        notifyCreditEndOffset = 0
        controlFailureQueueRetries = 0
        controlFailureItemID = nil
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        if preserveTransfer {
            return
        }
        currentItem = nil
        currentData = Data()
        currentOffset = 0
        lastReportedPercent = -1
        lastLoggedChunkOffset = 0
        transferStartedAt = nil
        lastThroughputLogAt = nil
        lastThroughputLogOffset = 0
        resumeAttempts = 0
        checksumRetryAttempts = 0
        pacedChunkDelay = 0
        lastTimeoutOffset = -1
        sameOffsetTimeouts = 0
        characteristicDiscoveryRetries = 0
        if !preserveQueueRetries {
            queueReadRetries = 0
        }
    }

    private func handleQueue(_ data: Data?) {
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        guard let data, !data.isEmpty else {
            retryQueueRead()
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json.isEmpty {
            completeNoItem()
            return
        }
        guard let item = decodeQueueItem(data) else {
            let preview = String(data: data.prefix(48), encoding: .utf8) ?? data.prefix(24).map { String(format: "%02X", $0) }.joined()
            debugLog("pull queue decode failed bytes=\(data.count) preview=\(preview)")
            retryQueueRead()
            return
        }
        guard let id = item.id, !id.isEmpty,
              let size = item.size, size > 2_000, size <= maxAudioBytes else {
            fail("手表录音信息不可用")
            return
        }
        queueReadRetries = 0
        if controlFailureItemID != id {
            controlFailureQueueRetries = 0
            controlFailureItemID = nil
        }
        currentItem = item
        currentData = Data(capacity: size)
        currentOffset = 0
        resumeAttempts = 0
        checksumRetryAttempts = 0
        lastReportedPercent = -1
        lastLoggedChunkOffset = 0
        transferStartedAt = Date()
        lastThroughputLogAt = transferStartedAt
        lastThroughputLogOffset = 0
        transferRequestInFlight = false
        waitingForDataRead = false
        readOnlyTransfer = false
        dataReadRetries = 0
        if let notifyPayload = item.notifyPayload,
           notifyPayload > 0,
           notifyPayload < minEfficientNotifyPayloadBytes {
            readOnlyTransfer = true
            debugLog("pull notify payload too small payload=\(notifyPayload) mtu=\(item.mtu.map(String.init) ?? "nil"); using read mode")
        }
        debugLog("pull transfer start id=\(id) expected=\(size) mtu=\(item.mtu.map(String.init) ?? "nil") notifyPayload=\(item.notifyPayload.map(String.init) ?? "nil") readOnly=\(readOnlyTransfer)")
        setStatus("开始接收手表录音", severity: .receiving, progress: 0)
        requestChunk()
    }

    private func decodeQueueItem(_ data: Data) -> WatchPullQueueItem? {
        if let item = try? JSONDecoder().decode(WatchPullQueueItem.self, from: data) {
            return item
        }
        guard let text = String(data: data, encoding: .utf8),
              text.hasPrefix("q:") else {
            return nil
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "q",
              !parts[1].isEmpty,
              let size = Int(parts[2]),
              size > 0 else {
            return nil
        }
        return WatchPullQueueItem(id: String(parts[1]), size: size)
    }

    private func retryQueueRead() {
        queueReadRetries += 1
        debugLog("pull queue unavailable retry=\(queueReadRetries)")
        guard queueReadRetries <= maxQueueReadRetries else {
            fail("手表录音队列暂时不可用")
            return
        }
        pendingSync = true
        syncing = true
        setStatus("手表队列无响应，重新连接", severity: .warning)
        if let target {
            central?.cancelPeripheralConnection(target)
        }
        resetSession(preserveTransfer: false, preserveQueueRetries: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.pendingSync else { return }
            self.scan(preservingTransfer: false, preserveQueueRetries: true)
        }
    }

    @discardableResult
    private func retryQueueAfterControlFailure() -> Bool {
        let failedID = currentItem?.id
        if controlFailureItemID != failedID {
            controlFailureItemID = failedID
            controlFailureQueueRetries = 0
        }
        guard controlFailureQueueRetries < maxControlFailureQueueRetries,
              let target,
              queueCharacteristic != nil else {
            return false
        }
        controlFailureQueueRetries += 1
        debugLog("pull control failure queue retry attempt=\(controlFailureQueueRetries)")
        resetTransferStateForNextQueue()
        setStatus("跳过不可用录音，继续查找", severity: .processing)
        scheduleQueueRead(from: target, after: 0.25, reason: "control-failure-skip")
        return true
    }

    private func readQueue(from peripheral: CBPeripheral) {
        guard let queueCharacteristic else {
            fail("手表录音队列不可用")
            return
        }
        debugLog("pull queue read request retry=\(queueReadRetries) peripheral=\(peripheral.identifier.uuidString)")
        peripheral.readValue(for: queueCharacteristic)
        scheduleQueueReadWatchdog()
    }

    private func scheduleQueueRead(from peripheral: CBPeripheral, after delay: TimeInterval, reason: String) {
        queueReadDelayWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.syncing,
                  self.currentItem == nil,
                  self.target === peripheral else { return }
            self.debugLog("pull queue read firing reason=\(reason) delay=\(String(format: "%.2f", delay))")
            self.readQueue(from: peripheral)
        }
        queueReadDelayWorkItem = item
        debugLog("pull queue read scheduled reason=\(reason) delay=\(String(format: "%.2f", delay)) retry=\(queueReadRetries)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleQueueReadWatchdog() {
        queueReadWatchdogWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.syncing, self.currentItem == nil else { return }
            self.debugLog("pull queue read timeout retry=\(self.queueReadRetries + 1)")
            self.retryQueueRead()
        }
        queueReadWatchdogWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func canResumeTransfer() -> Bool {
        guard let expected = currentItem?.size else { return false }
        return currentOffset >= 0
            && currentOffset < expected
            && (currentOffset == 0 || !currentData.isEmpty)
            && resumeAttempts < maxResumeAttempts
    }

    private func resumeTransfer(after delay: TimeInterval, reason: String) {
        guard canResumeTransfer(), let expected = currentItem?.size else {
            fail("手表连接已断开")
            return
        }
        resumeAttempts += 1
        pendingSync = true
        syncing = true
        let progress = min(1, Double(currentOffset) / Double(max(1, expected)))
        let percent = Int((progress * 100).rounded(.down))
        debugLog("pull resume attempt=\(resumeAttempts) offset=\(currentOffset) expected=\(expected) reason=\(reason)")
        resetSession(preserveTransfer: true)
        setStatus("连接中断，继续接收 \(percent)%", severity: .receiving, progress: progress)
        if resumeAttempts >= 2 {
            debugLog("pull central rebuild for recovery attempt=\(resumeAttempts)")
            central?.stopScan()
            central?.delegate = nil
            central = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.syncing, self.pendingSync else { return }
                self.start()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.syncing, self.pendingSync else { return }
            self.scan(preservingTransfer: true)
        }
    }

    private func requestChunk() {
        guard let target, let controlCharacteristic, let item = currentItem,
              let id = item.id else {
            fail("同步状态异常")
            return
        }
        let token = AppSettings.normalizedWatchToken(
            UserDefaults.standard.string(forKey: AppSettings.watchTokenKey) ?? ""
        )
        guard !token.isEmpty else {
            fail("绑定凭证不可用")
            return
        }
        let useNotifyStream = shouldUseNotifyStream
        guard let data = makeControlPayload(token: token,
                                            id: id,
                                            offset: currentOffset,
                                            notify: useNotifyStream,
                                            creditBytes: useNotifyStream ? notifyCreditWindowBytes : 0) else {
            fail("同步请求格式错误")
            return
        }
        guard controlCharacteristic.properties.contains(.write) else {
            fail("手表端版本需要更新")
            return
        }
        let canWriteWithoutResponse = !useNotifyStream && controlCharacteristic.properties.contains(.writeWithoutResponse)
        let withoutResponseMaxWrite = target.maximumWriteValueLength(for: .withoutResponse)
        let type: CBCharacteristicWriteType = canWriteWithoutResponse && data.count <= withoutResponseMaxWrite
            ? .withoutResponse
            : .withResponse
        let maxWriteLength = target.maximumWriteValueLength(for: type)
        debugLog("pull control write request offset=\(currentOffset) notify=\(dataNotifyReady) readOnly=\(readOnlyTransfer) mode=\(useNotifyStream ? "notify" : "read") type=\(type == .withoutResponse ? "withoutResponse" : "withResponse") bytes=\(data.count) maxWrite=\(maxWriteLength)")
        if useNotifyStream {
            notifyCreditEndOffset = min(item.size ?? currentOffset + notifyCreditWindowBytes,
                                        currentOffset + notifyCreditWindowBytes)
            debugLog("pull notify credit request offset=\(currentOffset) creditEnd=\(notifyCreditEndOffset) bytes=\(notifyCreditWindowBytes)")
        }
        target.writeValue(data, for: controlCharacteristic, type: type)
        transferRequestInFlight = true
        waitingForDataRead = false
        dataReadRetries = 0
        if type == .withoutResponse, !useNotifyStream {
            scheduleDataRead(after: 0.18)
        }
        scheduleChunkWatchdog()
    }

    private func makeControlPayload(token: String,
                                    id: String,
                                    offset: Int,
                                    notify: Bool,
                                    creditBytes: Int = 0) -> Data? {
        guard let tokenData = token.data(using: .utf8),
              let idData = id.data(using: .utf8),
              tokenData.count <= UInt8.max,
              idData.count <= UInt8.max,
              offset >= 0,
              offset <= Int(UInt32.max) else {
            return nil
        }
        var data = Data()
        data.append(notify ? UInt8(ascii: "n") : UInt8(ascii: "r"))
        appendUInt32BE(UInt32(offset), to: &data)
        data.append(UInt8(idData.count))
        data.append(UInt8(tokenData.count))
        data.append(idData)
        data.append(tokenData)
        if notify {
            appendUInt32BE(UInt32(max(0, creditBytes)), to: &data)
        }
        return data
    }

    private func scheduleDataRead(after delay: TimeInterval = 0) {
        let read = { [weak self] in
            guard let self, self.syncing,
                  let target = self.target,
                  let dataCharacteristic = self.dataCharacteristic else { return }
            self.waitingForDataRead = true
            self.dataReadRetries += 1
            self.debugLog("pull data read request offset=\(self.currentOffset) attempt=\(self.dataReadRetries)")
            target.readValue(for: dataCharacteristic)
        }
        if delay <= 0 {
            read()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: read)
        }
    }

    private func handleChunk(_ data: Data?) {
        guard let item = currentItem, let expected = item.size else {
            fail("同步状态异常")
            return
        }
        let rawChunk = data ?? Data()
        guard !rawChunk.isEmpty || currentOffset >= expected else {
            fail("手表返回空音频片段")
            return
        }
        guard let chunk = decodedChunk(rawChunk, expected: expected) else {
            return
        }
        transferRequestInFlight = false
        waitingForDataRead = false
        dataReadRetries = 0
        currentData.append(chunk)
        currentOffset = currentData.count
        if currentOffset > lastTimeoutOffset, pacedChunkDelay > 0 {
            pacedChunkDelay = max(0, pacedChunkDelay - 0.005)
            if pacedChunkDelay == 0 {
                sameOffsetTimeouts = 0
                lastTimeoutOffset = -1
            }
        }
        scheduleChunkWatchdog()
        let progress = min(1, Double(currentOffset) / Double(max(1, expected)))
        let percent = Int((progress * 100).rounded(.down))
        let now = Date()
        let rate = transferRateBytesPerSecond(at: now)
        if percent != lastReportedPercent || currentOffset >= expected {
            lastReportedPercent = percent
            setStatus("正在接收手表录音 \(percent)% · \(formatTransferRate(rate))",
                      severity: .receiving,
                      progress: progress)
        }
        logThroughputIfNeeded(now: now, expected: expected, rate: rate)
        if lastLoggedChunkOffset == 0
            || currentOffset >= expected
            || currentOffset - lastLoggedChunkOffset >= 64 * 1024 {
            lastLoggedChunkOffset = currentOffset
            debugLog("pull chunk offset=\(currentOffset) expected=\(expected) bytes=\(chunk.count)")
        }
        if currentOffset >= expected {
            chunkWatchdogWorkItem?.cancel()
            chunkWatchdogWorkItem = nil
            finishItem()
        } else if shouldUseNotifyStream, currentOffset >= notifyCreditEndOffset {
            debugLog("pull notify credit exhausted offset=\(currentOffset) creditEnd=\(notifyCreditEndOffset)")
            requestChunk()
        } else if !shouldUseNotifyStream {
            scheduleNextChunk()
        }
    }

    private func decodedChunk(_ raw: Data, expected: Int) -> Data? {
        guard shouldUseNotifyStream else { return raw }
        guard raw.count >= notifyChunkHeaderBytes else {
            recoverFromNotifyFrameMismatch(reason: "short_header",
                                           receivedOffset: nil,
                                           receivedLength: raw.count)
            return nil
        }
        let offset = readUInt32BE(raw, at: 0)
        let length = readUInt32BE(raw, at: 4)
        let payloadCount = raw.count - notifyChunkHeaderBytes
        guard offset == currentOffset,
              length == payloadCount,
              offset + length <= expected else {
            recoverFromNotifyFrameMismatch(reason: "offset_or_length",
                                           receivedOffset: offset,
                                           receivedLength: length)
            return nil
        }
        return raw.dropFirst(notifyChunkHeaderBytes)
    }

    private func readUInt32BE(_ data: Data, at index: Int) -> Int {
        guard index + 3 < data.count else { return -1 }
        let value = (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
        return Int(value)
    }

    private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func recoverFromNotifyFrameMismatch(reason: String,
                                                receivedOffset: Int?,
                                                receivedLength: Int) {
        debugLog("pull notify frame mismatch reason=\(reason) expectedOffset=\(currentOffset) receivedOffset=\(receivedOffset.map(String.init) ?? "nil") receivedLength=\(receivedLength)")
        dataNotifyReady = false
        readOnlyTransfer = true
        transferRequestInFlight = false
        waitingForDataRead = false
        dataReadRetries = 0
        setStatus("校正手表录音位置", severity: .receiving, progress: currentProgress)
        requestChunk()
    }

    private func scheduleNextChunk() {
        if pacedChunkDelay <= 0 {
            requestChunk()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + pacedChunkDelay) { [weak self] in
                guard let self, self.syncing else { return }
                self.requestChunk()
            }
        }
    }

    private func scheduleChunkWatchdog() {
        guard syncing, currentItem != nil else { return }
        chunkWatchdogWorkItem?.cancel()
        let expectedOffset = currentOffset
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.syncing,
                  self.currentItem != nil,
                  self.currentOffset <= expectedOffset,
                  self.canResumeTransfer() else { return }
            if self.currentOffset == self.lastTimeoutOffset {
                self.sameOffsetTimeouts += 1
            } else {
                self.lastTimeoutOffset = self.currentOffset
                self.sameOffsetTimeouts = 1
            }
            if self.sameOffsetTimeouts >= 1 {
                self.pacedChunkDelay = min(0.08, 0.02 * Double(self.sameOffsetTimeouts))
            }
            self.debugLog("pull chunk timeout offset=\(self.currentOffset) sameOffsetTimeouts=\(self.sameOffsetTimeouts) waitingRead=\(self.waitingForDataRead) requestInFlight=\(self.transferRequestInFlight) pacing=\(String(format: "%.3f", self.pacedChunkDelay))")
            if self.shouldUseNotifyStream {
                if self.currentOffset > 0 {
                    self.debugLog("pull notify silent reconnect offset=\(self.currentOffset)")
                    self.transferRequestInFlight = false
                    self.waitingForDataRead = false
                    if let target = self.target {
                        self.central?.cancelPeripheralConnection(target)
                    }
                    self.resumeTransfer(after: 0.8, reason: "notify_silent")
                    return
                }
                self.debugLog("pull notify silent fallback to read offset=\(self.currentOffset)")
                self.dataNotifyReady = false
                self.readOnlyTransfer = true
                self.transferRequestInFlight = false
                self.waitingForDataRead = false
                self.setStatus("手表录音流降级接收", severity: .receiving, progress: self.currentProgress)
                self.requestChunk()
                return
            }
            if !self.dataNotifyReady, self.waitingForDataRead, self.dataReadRetries <= self.maxDataReadRetries {
                self.scheduleDataRead(after: 0.15)
                self.scheduleChunkWatchdog()
                return
            }
            if let target = self.target {
                self.central?.cancelPeripheralConnection(target)
            }
            self.resumeTransfer(after: 0.8, reason: "chunk_timeout")
        }
        chunkWatchdogWorkItem = item
        let timeout = shouldUseNotifyStream
            ? (currentOffset == 0 ? notifyFirstChunkTimeout : notifyQuietTimeout)
            : readQuietTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private var currentProgress: Double? {
        guard let expected = currentItem?.size, expected > 0 else { return nil }
        return min(1, Double(currentOffset) / Double(expected))
    }

    private var shouldUseNotifyStream: Bool {
        dataNotifyReady && !readOnlyTransfer
    }

    private func finishItem() {
        guard let item = currentItem, let id = item.id else {
            fail("同步状态异常")
            return
        }
        if let startedAt = transferStartedAt {
            let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
            let rate = Double(currentOffset) / elapsed
            debugLog("pull transfer complete id=\(id) bytes=\(currentOffset) seconds=\(String(format: "%.2f", elapsed)) rate=\(formatTransferRate(rate))")
        }
        let recordedAt = item.createdAt.map { value -> Date in
            let seconds = value > 10_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        let durationMs = item.durationMs.map { Int64($0.rounded()) }
        setStatus("录音已接收，正在保存", severity: .processing)
        let body = currentData
        let externalID = storageExternalID(for: item, body: body)
        let filename = "wristnote-\(externalID).m4a"
        if !verifyChecksum(for: body, expectedHex: item.sha256) {
            if retryChecksumMismatch(id: id) {
                return
            }
            fail("手表录音校验失败")
            return
        }
        Task {
            do {
                let receipt = try await onAudioReceived?(body, filename, recordedAt, durationMs, externalID)
                    ?? "已接收手表录音"
                await MainActor.run {
                    self.completedItemsThisSync += 1
                    self.setStatus(receipt, severity: .success)
                    self.rememberPendingAck(id: id)
                    self.ackItem(id: id, continueSyncing: true)
                }
            } catch {
                await MainActor.run {
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.fail(reason.isEmpty ? "保存手表录音失败" : reason)
                }
            }
        }
    }

    private func storageExternalID(for item: WatchPullQueueItem, body: Data) -> String {
        let size = item.size ?? body.count
        if let expected = normalizedSHA256Prefix(item.sha256) {
            return "watch-\(size)-\(expected)"
        }
        let digest = SHA256.hash(data: body)
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "watch-\(size)-\(prefix)"
    }

    private func normalizedSHA256Prefix(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return String(normalized.prefix(16))
    }

    private func ackItem(id: String, continueSyncing: Bool) {
        guard let target, let ackCharacteristic else {
            debugLog("pull ack unavailable id=\(id) continue=\(continueSyncing)")
            retryPendingAckAfterReconnect(id: id,
                                          continueSyncing: continueSyncing,
                                          reason: "ack_unavailable")
            return
        }
        let token = AppSettings.normalizedWatchToken(
            UserDefaults.standard.string(forKey: AppSettings.watchTokenKey) ?? ""
        )
        if let data = makeAckPayload(token: token, id: id) {
            awaitingAckID = id
            continueAfterAck = continueSyncing
            scheduleAckWatchdog(id: id, continueSyncing: continueSyncing)
            debugLog("pull ack write id=\(id) continue=\(continueSyncing) bytes=\(data.count)")
            target.writeValue(data, for: ackCharacteristic, type: .withResponse)
        } else {
            retryPendingAckAfterReconnect(id: id,
                                          continueSyncing: continueSyncing,
                                          reason: "ack_payload_failed")
        }
    }

    private func makeAckPayload(token: String, id: String) -> Data? {
        guard let tokenData = token.data(using: .utf8),
              let idData = id.data(using: .utf8),
              tokenData.count <= UInt8.max,
              idData.count <= UInt8.max else {
            return nil
        }
        var data = Data()
        data.append(UInt8(ascii: "a"))
        data.append(UInt8(idData.count))
        data.append(UInt8(tokenData.count))
        data.append(idData)
        data.append(tokenData)
        return data
    }

    private func verifyChecksum(for data: Data, expectedHex: String?) -> Bool {
        guard let expectedHex else { return true }
        let expected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.count == 64,
              expected.allSatisfy({ $0.isHexDigit }) else {
            debugLog("pull checksum skipped invalid expected=\(expectedHex)")
            return true
        }
        let digest = SHA256.hash(data: data)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        let ok = actual == expected
        if !ok {
            debugLog("pull checksum mismatch expected=\(expected) actual=\(actual)")
        }
        return ok
    }

    @discardableResult
    private func retryChecksumMismatch(id: String) -> Bool {
        guard checksumRetryAttempts < maxChecksumRetries,
              target != nil,
              controlCharacteristic != nil else {
            return false
        }
        checksumRetryAttempts += 1
        currentData = Data(capacity: currentItem?.size ?? 0)
        currentOffset = 0
        lastReportedPercent = -1
        lastLoggedChunkOffset = 0
        transferStartedAt = Date()
        lastThroughputLogAt = transferStartedAt
        lastThroughputLogOffset = 0
        transferRequestInFlight = false
        waitingForDataRead = false
        readOnlyTransfer = true
        dataReadRetries = 0
        pacedChunkDelay = 0
        lastTimeoutOffset = -1
        sameOffsetTimeouts = 0
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        setStatus("录音校验未通过，重新接收", severity: .receiving, progress: 0)
        debugLog("pull checksum retry id=\(id) attempt=\(checksumRetryAttempts)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.syncing, self.currentItem?.id == id else { return }
            self.requestChunk()
        }
        return true
    }

    private func scheduleAckWatchdog(id: String, continueSyncing: Bool) {
        ackWatchdogWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.syncing,
                  self.awaitingAckID == id else {
                return
            }
            self.debugLog("pull ack write timeout id=\(id) continue=\(continueSyncing)")
            self.retryPendingAckAfterReconnect(id: id,
                                               continueSyncing: continueSyncing,
                                               reason: "ack_timeout")
        }
        ackWatchdogWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ackWriteTimeout, execute: item)
    }

    private var pendingAckID: String? {
        let value = UserDefaults.standard.string(forKey: pendingAckDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func rememberPendingAck(id: String) {
        UserDefaults.standard.set(id, forKey: pendingAckDefaultsKey)
        debugLog("pull pending ack remember id=\(id)")
    }

    private func clearPendingAck(id: String?) {
        if let id, pendingAckID != id {
            debugLog("pull pending ack clear skipped id=\(id) stored=\(pendingAckID ?? "nil")")
            return
        }
        UserDefaults.standard.removeObject(forKey: pendingAckDefaultsKey)
        debugLog("pull pending ack cleared id=\(id ?? "any")")
    }

    private func retryPendingAckAfterReconnect(id: String,
                                               continueSyncing: Bool,
                                               reason: String) {
        rememberPendingAck(id: id)
        pendingSync = true
        syncing = true
        awaitingAckID = nil
        continueAfterAck = false
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        setStatus("确认上一条手表录音", severity: .processing)
        debugLog("pull pending ack reconnect id=\(id) continue=\(continueSyncing) reason=\(reason)")
        if let target {
            central?.cancelPeripheralConnection(target)
        }
        resetSession()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSync, self.syncing else { return }
            self.start()
            guard let central = self.central, central.state == .poweredOn else {
                self.debugLog("pull pending ack reconnect waiting central reason=\(reason)")
                return
            }
            self.scan(preservingTransfer: false)
        }
        nextSyncWorkItem?.cancel()
        nextSyncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func finishAckFlow(continueSyncing: Bool) {
        let shouldContinue = continueSyncing
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        resumeAttempts = 0
        awaitingAckID = nil
        continueAfterAck = false
        if shouldContinue,
           let target,
           queueCharacteristic != nil {
            pendingSync = true
            syncing = true
            queueReadRetries = 0
            resetTransferStateForNextQueue()
            setStatus("检查下一条手表录音", severity: .processing)
            debugLog("pull ack continue on existing connection")
            scheduleQueueRead(from: target, after: ackContinueQueueReadDelay, reason: "ack-continue")
            return
        }
        pendingSync = false
        syncing = false
        let connectedTarget = target
        if let connectedTarget {
            central?.cancelPeripheralConnection(connectedTarget)
        }
        resetSession()
        guard shouldContinue else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.debugLog("pull auto continue reconnect fallback")
            self?.syncNow(reason: "ack_reconnect_fallback")
        }
        nextSyncWorkItem?.cancel()
        nextSyncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func resetTransferStateForNextQueue() {
        currentItem = nil
        currentData = Data()
        currentOffset = 0
        lastReportedPercent = -1
        lastLoggedChunkOffset = 0
        transferStartedAt = nil
        lastThroughputLogAt = nil
        lastThroughputLogOffset = 0
        checksumRetryAttempts = 0
        transferRequestInFlight = false
        waitingForDataRead = false
        readOnlyTransfer = false
        dataReadRetries = 0
        pacedChunkDelay = 0
        lastTimeoutOffset = -1
        sameOffsetTimeouts = 0
    }

    private func completeNoItem() {
        pendingSync = false
        syncing = false
        resumeAttempts = 0
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        nextSyncWorkItem?.cancel()
        nextSyncWorkItem = nil
        let message = completedItemsThisSync > 0
            ? "已同步 \(completedItemsThisSync) 条手表录音"
            : "手表没有待同步录音"
        setStatus(message, severity: .success)
        if let target {
            central?.cancelPeripheralConnection(target)
        }
    }

    private func completeEntryRefreshUnavailable(for peripheral: CBPeripheral) {
        pendingSync = false
        syncing = false
        resumeAttempts = 0
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        nextSyncWorkItem?.cancel()
        nextSyncWorkItem = nil
        forgetWatchPeripheral(peripheral)
        setStatus("手表录音入口刷新中", severity: .info)
        if target === peripheral {
            target = nil
        }
        central?.cancelPeripheralConnection(peripheral)
    }

    private func transferRateBytesPerSecond(at now: Date) -> Double {
        guard let startedAt = transferStartedAt else { return 0 }
        let elapsed = max(0.001, now.timeIntervalSince(startedAt))
        return Double(currentOffset) / elapsed
    }

    private func logThroughputIfNeeded(now: Date, expected: Int, rate: Double) {
        let elapsedSinceLog = lastThroughputLogAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let bytesSinceLog = currentOffset - lastThroughputLogOffset
        guard currentOffset >= expected || bytesSinceLog >= 128 * 1024 || elapsedSinceLog >= 5 else {
            return
        }
        lastThroughputLogAt = now
        lastThroughputLogOffset = currentOffset
        debugLog("pull transfer rate offset=\(currentOffset) expected=\(expected) rate=\(formatTransferRate(rate))")
    }

    private func formatTransferRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "测速中" }
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    private func fail(_ message: String) {
        pendingSync = false
        syncing = false
        resumeAttempts = 0
        chunkWatchdogWorkItem?.cancel()
        chunkWatchdogWorkItem = nil
        queueReadWatchdogWorkItem?.cancel()
        queueReadWatchdogWorkItem = nil
        queueReadDelayWorkItem?.cancel()
        queueReadDelayWorkItem = nil
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        ackWatchdogWorkItem?.cancel()
        ackWatchdogWorkItem = nil
        nextSyncWorkItem?.cancel()
        nextSyncWorkItem = nil
        setStatus(message, severity: .error)
        if let target {
            central?.cancelPeripheralConnection(target)
        }
    }

    private func setStatus(_ status: String,
                           severity: ReceiverEventSeverity,
                           progress: Double? = nil) {
        debugLog("pull status=\(status) severity=\(severity)")
        DispatchQueue.main.async {
            self.status = status
            self.lastEvent = ReceiverEvent(message: status,
                                           severity: severity,
                                           progress: progress,
                                           occurredAt: Date())
        }
    }

    private func debugLog(_ message: String) {
        let line = "[WanjiBLE] \(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        print(line, terminator: "")
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("wanji-ble.log") else {
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private var tokenConfigured: Bool {
        !AppSettings.normalizedWatchToken(
            UserDefaults.standard.string(forKey: AppSettings.watchTokenKey) ?? ""
        ).isEmpty
    }
}

extension BluetoothWatchPullClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugLog("pull central state=\(central.state.rawValue) pending=\(pendingSync) bound=\(UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey)) tokenConfigured=\(tokenConfigured)")
        if central.state == .poweredOn, pendingSync {
            scan(preservingTransfer: canResumeTransfer())
        } else if central.state == .unknown || central.state == .resetting {
            if pendingSync {
                syncing = true
                setStatus("手机蓝牙准备中", severity: .processing)
            }
        } else if central.state != .poweredOn {
            pendingSync = false
            syncing = false
            setStatus("手机蓝牙未就绪", severity: .warning)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let match = watchAdvertisementMatch(peripheral: peripheral,
                                            advertisementData: advertisementData,
                                            rssi: RSSI)
        if broadScanActive, match == .none {
            ignoredBroadDiscoveries += 1
            if ignoredBroadDiscoveries <= 3 || ignoredBroadDiscoveries % 250 == 0 {
                debugLog("pull ignored broad discovery count=\(ignoredBroadDiscoveries) name=\(peripheral.name ?? "nil") rssi=\(RSSI) adv=\(advertisementSummary(advertisementData))")
            }
            return
        }
        debugLog("pull didDiscover name=\(peripheral.name ?? "nil") rssi=\(RSSI) broad=\(broadScanActive) match=\(match.rawValue) adv=\(advertisementSummary(advertisementData))")
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        scanGeneration += 1
        broadScanActive = false
        central.stopScan()
        target = peripheral
        targetMatchedByNameFallback = match == .watchNameFallback
        peripheral.delegate = self
        setStatus("连接手表录音服务", severity: .processing)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debugLog("pull didConnect peripheral=\(peripheral.identifier.uuidString)")
        if target === peripheral {
            scanStopWorkItem?.cancel()
            scanStopWorkItem = nil
        }
        setStatus("读取手表录音服务", severity: .processing)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        debugLog("pull didFailToConnect error=\(error?.localizedDescription ?? "unknown")")
        guard target === peripheral else {
            debugLog("pull didFailToConnect ignored stale peripheral=\(peripheral.identifier.uuidString)")
            return
        }
        target = nil
        if canResumeTransfer() {
            resumeTransfer(after: 1.5, reason: "connect_failed")
            return
        }
        if scheduleScanRetryIfNeeded(after: activeScanRetryAttempt,
                                     preservingTransfer: false,
                                     preserveQueueRetries: false,
                                     reason: "connect_failed") {
            return
        }
        fail("手表录音服务连接失败")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        debugLog("pull didDisconnect error=\(error?.localizedDescription ?? "nil")")
        if target === peripheral {
            if syncing, let pendingAckID {
                retryPendingAckAfterReconnect(id: pendingAckID,
                                              continueSyncing: true,
                                              reason: "disconnect_before_ack")
                return
            }
            if syncing, canResumeTransfer() {
                resumeTransfer(after: 1.0, reason: "disconnect")
                return
            }
            if syncing {
                pendingSync = false
                syncing = false
                setStatus("手表连接已断开", severity: .error)
            }
            resetSession()
        }
    }

    private func watchAdvertisementMatch(peripheral: CBPeripheral,
                                         advertisementData: [String: Any],
                                         rssi RSSI: NSNumber) -> AdvertisementMatch {
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           serviceUUIDs.contains(discoveryUUID) || serviceUUIDs.contains(serviceUUID) {
            return .wanjiMarker
        }
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 7,
           manufacturerData[0] == 0xFF,
           manufacturerData[1] == 0xFF,
           manufacturerData.suffix(5) == Data("WANJI".utf8) {
            return .wanjiMarker
        }
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let normalizedName = localName.lowercased()
        if normalizedName.contains("wanji")
            || normalizedName.contains("wristnote")
            || normalizedName.contains("腕记") {
            return .wanjiMarker
        }
        if broadScanActive,
           UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey),
           RSSI.intValue >= -82,
           normalizedName.contains("huawei watch") {
            return .watchNameFallback
        }
        return .none
    }

    private func advertisementSummary(_ advertisementData: [String: Any]) -> String {
        var parts: [String] = []
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            parts.append("services=\(serviceUUIDs.map { $0.uuidString }.joined(separator: ","))")
        }
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            parts.append("name=\(localName)")
        }
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            parts.append("mfg=\(manufacturerData.map { String(format: "%02X", $0) }.joined())")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}

extension BluetoothWatchPullClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        debugLog("pull didDiscoverServices error=\(error?.localizedDescription ?? "nil") services=\(peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "nil")")
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            if targetMatchedByNameFallback {
                targetMatchedByNameFallback = false
                setStatus("继续查找腕记录音服务", severity: .info)
                debugLog("pull name fallback missing service; resume scan")
                if target === peripheral {
                    target = nil
                }
                central?.cancelPeripheralConnection(peripheral)
                if scheduleScanRetryIfNeeded(after: activeScanRetryAttempt,
                                             preservingTransfer: canResumeTransfer(),
                                             preserveQueueRetries: false,
                                             reason: "fallback_service_missing") {
                    return
                }
            }
            fail("手表录音服务不可用")
            return
        }
        targetMatchedByNameFallback = false
        peripheral.discoverCharacteristics([queueUUID, controlUUID, dataUUID, ackUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        debugLog("pull didDiscoverCharacteristics error=\(error?.localizedDescription ?? "nil") characteristics=\(service.characteristics?.map { "\($0.uuid.uuidString):\($0.properties.rawValue)" }.joined(separator: ",") ?? "nil")")
        guard error == nil, let characteristics = service.characteristics else {
            fail("手表录音入口不可用")
            return
        }
        queueCharacteristic = characteristics.first(where: { $0.uuid == queueUUID })
        controlCharacteristic = characteristics.first(where: { $0.uuid == controlUUID })
        dataCharacteristic = characteristics.first(where: { $0.uuid == dataUUID })
        ackCharacteristic = characteristics.first(where: { $0.uuid == ackUUID })
        guard queueCharacteristic != nil, controlCharacteristic != nil,
              dataCharacteristic != nil, ackCharacteristic != nil else {
            characteristicDiscoveryRetries += 1
            debugLog("pull characteristic discovery incomplete retry=\(characteristicDiscoveryRetries) count=\(characteristics.count)")
            if characteristicDiscoveryRetries <= maxCharacteristicDiscoveryRetries {
                setStatus("刷新手表录音入口", severity: .processing)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak peripheral, weak service] in
                    guard let self, let peripheral, let service, self.target === peripheral else { return }
                    let uuids: [CBUUID]? = self.characteristicDiscoveryRetries == 1
                        ? nil
                        : [self.queueUUID, self.controlUUID, self.dataUUID, self.ackUUID]
                    peripheral.discoverCharacteristics(uuids, for: service)
                }
                return
            }
            if characteristicDiscoveryReconnects < maxCharacteristicDiscoveryReconnects {
                characteristicDiscoveryReconnects += 1
                characteristicDiscoveryRetries = 0
                pendingSync = true
                syncing = true
                setStatus("重新连接手表录音入口", severity: .processing)
                debugLog("pull characteristic discovery reconnect attempt=\(characteristicDiscoveryReconnects)")
                if target === peripheral {
                    target = nil
                }
                central?.cancelPeripheralConnection(peripheral)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.pendingSync, self.syncing else { return }
                    self.scan(preservingTransfer: self.canResumeTransfer(),
                              preserveQueueRetries: true)
                }
                return
            }
            completeEntryRefreshUnavailable(for: peripheral)
            return
        }
        rememberWatchPeripheral(peripheral)
        debugLog("pull remembered verified peripheral id=\(peripheral.identifier.uuidString)")
        characteristicDiscoveryRetries = 0
        characteristicDiscoveryReconnects = 0
        guard let dataCharacteristic,
              dataCharacteristic.properties.contains(.read) else {
            fail("手表端版本需要更新")
            return
        }
        if dataCharacteristic.properties.contains(.notify), !dataCharacteristic.isNotifying {
            debugLog("pull data notify enable requested")
            peripheral.setNotifyValue(true, for: dataCharacteristic)
            scheduleNotificationFallback(for: peripheral)
            setStatus("准备手表录音通道", severity: .processing)
            return
        } else if dataCharacteristic.properties.contains(.notify), dataCharacteristic.isNotifying {
            debugLog("pull data notify already active")
            dataNotifyReady = true
        } else {
            debugLog("pull data notify unavailable properties=\(dataCharacteristic.properties.rawValue)")
            continueWithReadMode(peripheral, reason: "notify-property-missing")
            return
        }
        continueAfterDataChannelReady(peripheral)
    }

    private func continueAfterDataChannelReady(_ peripheral: CBPeripheral) {
        if let pendingAckID {
            setStatus("确认上一条手表录音", severity: .processing)
            debugLog("pull pending ack before queue id=\(pendingAckID)")
            ackItem(id: pendingAckID, continueSyncing: true)
            return
        }
        if currentItem != nil {
            let expected = currentItem?.size ?? currentOffset
            let progress = min(1, Double(currentOffset) / Double(max(1, expected)))
            let percent = Int((progress * 100).rounded(.down))
            setStatus(currentOffset > 0 ? "继续接收手表录音 \(percent)%" : "开始接收手表录音",
                      severity: .receiving,
                      progress: progress)
            requestChunk()
            return
        }
        setStatus("读取待同步录音", severity: .processing)
        scheduleQueueRead(from: peripheral,
                          after: queueReadSettleDelay,
                          reason: dataNotifyReady ? "notify-ready" : (queueReadRetries == 0 ? "queue-first-gatt-settle" : "queue-first-retry-settle"))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        debugLog("pull didUpdateNotificationState uuid=\(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "nil")")
        guard characteristic.uuid == dataUUID else { return }
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        if error == nil, characteristic.isNotifying {
            dataNotifyReady = true
            if currentItem != nil, transferRequestInFlight {
                debugLog("pull notify ready request already in flight")
                return
            }
            if currentItem != nil, currentOffset > 0 {
                let expected = currentItem?.size ?? currentOffset
                let progress = min(1, Double(currentOffset) / Double(max(1, expected)))
                let percent = Int((progress * 100).rounded(.down))
                setStatus("继续接收手表录音 \(percent)%", severity: .receiving, progress: progress)
                requestChunk()
                return
            }
            debugLog("pull notify ready for next transfer")
            continueAfterDataChannelReady(peripheral)
        } else {
            continueWithReadMode(peripheral, reason: "notify-state-failed")
        }
    }

    private func continueWithReadMode(_ peripheral: CBPeripheral, reason: String) {
        dataNotifyReady = false
        readOnlyTransfer = true
        notificationFallbackWorkItem?.cancel()
        notificationFallbackWorkItem = nil
        debugLog("pull notify unavailable reason=\(reason); using read mode")
        if currentItem != nil {
            let expected = currentItem?.size ?? currentOffset
            let progress = min(1, Double(currentOffset) / Double(max(1, expected)))
            let percent = Int((progress * 100).rounded(.down))
            setStatus(currentOffset > 0 ? "继续接收手表录音 \(percent)%" : "开始接收手表录音",
                      severity: .receiving,
                      progress: progress)
            if !transferRequestInFlight {
                requestChunk()
            }
            return
        }
        guard queueCharacteristic != nil else {
            fail("手表录音队列不可用")
            return
        }
        if queueReadWatchdogWorkItem != nil {
            debugLog("pull notify unavailable reason=\(reason); queue read already active")
            return
        }
        setStatus("读取待同步录音", severity: .processing)
        scheduleQueueRead(from: peripheral, after: 0, reason: reason)
    }

    private func scheduleNotificationFallback(for peripheral: CBPeripheral) {
        notificationFallbackWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.syncing,
                  self.target === peripheral,
                  !self.dataNotifyReady else {
                return
            }
            self.debugLog("pull notify fallback currentOffset=\(self.currentOffset) hasItem=\(self.currentItem != nil)")
            self.continueWithReadMode(peripheral, reason: "notify-fallback")
        }
        notificationFallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + notificationEnableFallbackDelay, execute: item)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid != dataUUID || error != nil {
            debugLog("pull didUpdateValue uuid=\(characteristic.uuid.uuidString) error=\(error?.localizedDescription ?? "nil") bytes=\(characteristic.value?.count ?? 0)")
        }
        guard error == nil else {
            fail("读取手表录音失败")
            return
        }
        if characteristic.uuid == queueUUID {
            handleQueue(characteristic.value)
        } else if characteristic.uuid == dataUUID {
            handleChunk(characteristic.value)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == controlUUID {
            debugLog("pull control write complete error=\(error?.localizedDescription ?? "nil")")
            guard error == nil else {
                transferRequestInFlight = false
                if canResumeTransfer() {
                    debugLog("pull control failure resume current transfer offset=\(currentOffset)")
                    resumeTransfer(after: 1.0, reason: "control_write_failed")
                    return
                }
                if retryQueueAfterControlFailure() {
                    return
                }
                fail("请求手表录音失败")
                return
            }
            guard target != nil, dataCharacteristic != nil else {
                transferRequestInFlight = false
                fail("同步状态异常")
                return
            }
            if shouldUseNotifyStream {
                debugLog("pull data notify active; waiting for stream offset=\(currentOffset)")
            } else {
                scheduleDataRead(after: 0.15)
            }
            return
        }
        guard characteristic.uuid == ackUUID else { return }
        debugLog("pull ack write complete id=\(awaitingAckID ?? "nil") error=\(error?.localizedDescription ?? "nil")")
        guard awaitingAckID != nil else {
            debugLog("pull ack write completion ignored no pending ack")
            return
        }
        guard error == nil else {
            if let awaitingAckID {
                rememberPendingAck(id: awaitingAckID)
            }
            fail("手表同步确认失败")
            return
        }
        clearPendingAck(id: awaitingAckID)
        finishAckFlow(continueSyncing: continueAfterAck)
    }
}
