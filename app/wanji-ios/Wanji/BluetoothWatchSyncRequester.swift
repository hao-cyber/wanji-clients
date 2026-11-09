import Foundation
import CoreBluetooth

final class BluetoothWatchSyncRequester: NSObject, ObservableObject {
    @Published private(set) var status = "等待手表"
    @Published private(set) var lastEvent = ReceiverEvent(message: "打开手机腕记后会查找已绑定手表",
                                                          severity: .info,
                                                          occurredAt: Date())
    @Published private(set) var binding = false

    var onSyncCommandFinished: ((Bool) -> Void)?

    private let serviceUUID = CBUUID(string: AppSettings.watchSyncServiceUUID)
    private let commandUUID = CBUUID(string: AppSettings.watchSyncCommandCharacteristicUUID)
    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var command: CBCharacteristic?
    private var lastRequestAt = Date.distantPast
    private var scanStopWorkItem: DispatchWorkItem?
    private var scanRetryWorkItem: DispatchWorkItem?
    private var commandMode: CommandMode = .sync
    private var scanGeneration = 0
    private var broadScanActive = false
    private var ignoredBroadDiscoveries = 0
    private var activeRetryAttempt = 0
    private let maxAutoRetryAttempts = 2
    private let narrowScanFallbackDelay: TimeInterval = 0.35
    private let broadScanTimeout: TimeInterval = 4.5
    private let disconnectCompletionFallbackDelay: TimeInterval = 0.6
    private var pendingSyncCommandSuccess: Bool?
    private var syncCompletionFallbackWorkItem: DispatchWorkItem?

    private enum CommandMode {
        case sync
        case bind
    }

    func start() {
        binding = UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey)
        debugLog("start centralExists=\(central != nil) bound=\(binding) tokenConfigured=\(tokenConfigured)")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
            return
        }
        if binding {
            requestSync(force: true)
        } else {
            setStatus("等待绑定手表", severity: .info)
        }
    }

    func stop() {
        debugLog("stop")
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        scanRetryWorkItem?.cancel()
        scanRetryWorkItem = nil
        syncCompletionFallbackWorkItem?.cancel()
        syncCompletionFallbackWorkItem = nil
        pendingSyncCommandSuccess = nil
        if let target {
            central?.cancelPeripheralConnection(target)
        }
        target = nil
        command = nil
        central?.stopScan()
        scanGeneration += 1
        broadScanActive = false
        ignoredBroadDiscoveries = 0
        activeRetryAttempt = 0
    }

    func requestSync(force: Bool = false) {
        binding = UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey)
        guard binding else {
            debugLog("sync skipped bound=false tokenConfigured=\(tokenConfigured)")
            setStatus("等待绑定手表", severity: .info)
            return
        }
        guard pendingSyncCommandSuccess == nil else {
            debugLog("sync skipped pending command completion")
            return
        }
        commandMode = .sync
        scan(force: force, status: "查找手表", retryAttempt: 0)
    }

    func bindDevice() {
        commandMode = .bind
        UserDefaults.standard.set(false, forKey: AppSettings.watchBindingConfirmedKey)
        binding = false
        scan(force: true, status: "查找可绑定手表", retryAttempt: 0)
    }

    private func scan(force: Bool, status: String, retryAttempt: Int) {
        guard let central else {
            debugLog("scan skipped central=nil force=\(force) status=\(status)")
            return
        }
        scanRetryWorkItem?.cancel()
        scanRetryWorkItem = nil
        activeRetryAttempt = retryAttempt
        debugLog("scan requested force=\(force) status=\(status) retry=\(retryAttempt) centralState=\(central.state.rawValue) bound=\(binding) mode=\(commandMode)")
        guard central.state == .poweredOn else {
            debugLog("scan deferred bluetooth state=\(central.state.rawValue)")
            setStatus("手机蓝牙未就绪", severity: .warning)
            return
        }
        if !force && Date().timeIntervalSince(lastRequestAt) < 20 {
            debugLog("scan skipped debounce seconds=\(String(format: "%.1f", Date().timeIntervalSince(lastRequestAt)))")
            return
        }
        lastRequestAt = Date()
        setStatus(status, severity: .info)
        target = nil
        command = nil
        scanGeneration += 1
        broadScanActive = false
        ignoredBroadDiscoveries = 0
        central.stopScan()
        central.scanForPeripherals(withServices: [serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        debugLog("scan narrow service=\(serviceUUID.uuidString) generation=\(scanGeneration)")
        let generation = scanGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.scanGeneration == generation, self.target == nil else { return }
            self.broadScanActive = true
            self.ignoredBroadDiscoveries = 0
            self.central?.stopScan()
            self.setStatus("扩大查找手表", severity: .info)
            self.debugLog("scan broad generation=\(generation)")
            self.central?.scanForPeripherals(withServices: nil,
                                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            let finalItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == generation, self.target == nil else { return }
                self.central?.stopScan()
                self.broadScanActive = false
                self.debugLog("scan timeout generation=\(generation) ignoredBroad=\(self.ignoredBroadDiscoveries)")
                if self.scheduleAutoRetryIfNeeded(after: retryAttempt, reason: "timeout") {
                    return
                }
                self.setStatus("未发现手表", severity: .warning)
            }
            self.scanStopWorkItem = finalItem
            DispatchQueue.main.asyncAfter(deadline: .now() + broadScanTimeout, execute: finalItem)
        }
        scanStopWorkItem?.cancel()
        scanStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + narrowScanFallbackDelay, execute: item)
    }

    @discardableResult
    private func scheduleAutoRetryIfNeeded(after retryAttempt: Int, reason: String) -> Bool {
        let bound = UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey)
        guard commandMode == .sync,
              bound,
              retryAttempt < maxAutoRetryAttempts,
              pendingSyncCommandSuccess == nil else {
            return false
        }
        let nextAttempt = retryAttempt + 1
        let delay = min(2.0 + Double(retryAttempt), 4.0)
        scanRetryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.target == nil, self.pendingSyncCommandSuccess == nil else { return }
            self.debugLog("scan auto retry firing attempt=\(nextAttempt) reason=\(reason)")
            self.scan(force: true, status: "继续查找手表", retryAttempt: nextAttempt)
        }
        scanRetryWorkItem = item
        setStatus("继续查找手表", severity: .info)
        debugLog("scan auto retry scheduled attempt=\(nextAttempt) delay=\(String(format: "%.1f", delay)) reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return true
    }

    private func writeSyncCommand() {
        guard let target, let command else { return }
        let token = AppSettings.normalizedWatchToken(
            UserDefaults.standard.string(forKey: AppSettings.watchTokenKey) ?? ""
        )
        guard !token.isEmpty else {
            setStatus("绑定凭证不可用", severity: .error)
            return
        }
        let prefix = commandMode == .bind ? "bind:" : "sync:"
        let payload = "\(prefix)\(token)".data(using: .utf8) ?? Data()
        setStatus(commandMode == .bind ? "写入绑定" : "唤起手表同步", severity: .processing)
        let writeType: CBCharacteristicWriteType = command.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        debugLog("write command mode=\(commandMode) type=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")")
        target.writeValue(payload, for: command, type: writeType)
        if writeType == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.completeWrite(error: nil)
            }
        }
    }

    private func completeWrite(error: Error?) {
        let finishedMode = commandMode
        let connectedTarget = target
        if error == nil {
            debugLog("write complete success mode=\(commandMode)")
            if commandMode == .bind {
                UserDefaults.standard.set(true, forKey: AppSettings.watchBindingConfirmedKey)
                binding = true
                setStatus("已绑定手表", severity: .success)
            } else {
                setStatus("已通知手表同步", severity: .success)
            }
        } else {
            debugLog("write complete error=\(error?.localizedDescription ?? "unknown") mode=\(commandMode)")
            setStatus(commandMode == .bind ? "绑定失败" : "手表同步请求失败", severity: .error)
        }
        if let target {
            central?.cancelPeripheralConnection(target)
        }
        if finishedMode == .sync {
            beginSyncCommandCompletion(success: error == nil,
                                       waitingForDisconnect: connectedTarget != nil)
        }
    }

    private func beginSyncCommandCompletion(success: Bool, waitingForDisconnect: Bool) {
        pendingSyncCommandSuccess = success
        syncCompletionFallbackWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finishPendingSyncCommand(reason: waitingForDisconnect ? "disconnect-timeout" : "no-target")
        }
        syncCompletionFallbackWorkItem = item
        let delay: TimeInterval = waitingForDisconnect ? disconnectCompletionFallbackDelay : 0.2
        debugLog("sync command completion pending success=\(success) waitingForDisconnect=\(waitingForDisconnect) delay=\(delay)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func finishPendingSyncCommand(reason: String) {
        guard let success = pendingSyncCommandSuccess else { return }
        pendingSyncCommandSuccess = nil
        syncCompletionFallbackWorkItem?.cancel()
        syncCompletionFallbackWorkItem = nil
        debugLog("sync command callback success=\(success) reason=\(reason)")
        onSyncCommandFinished?(success)
    }

    private func setStatus(_ status: String, severity: ReceiverEventSeverity) {
        debugLog("status=\(status) severity=\(severity)")
        DispatchQueue.main.async {
            self.status = status
            self.lastEvent = ReceiverEvent(message: status,
                                           severity: severity,
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

extension BluetoothWatchSyncRequester: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let bound = UserDefaults.standard.bool(forKey: AppSettings.watchBindingConfirmedKey)
        debugLog("central state=\(central.state.rawValue) bound=\(bound) tokenConfigured=\(tokenConfigured) mode=\(commandMode)")
        if central.state == .poweredOn {
            if commandMode == .bind {
                scan(force: true, status: "查找可绑定手表", retryAttempt: 0)
            } else if bound {
                requestSync(force: true)
            } else {
                setStatus("等待绑定手表", severity: .info)
            }
        } else {
            setStatus("手机蓝牙未就绪", severity: .warning)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if broadScanActive,
           !matchesWatchAdvertisement(peripheral: peripheral,
                                      advertisementData: advertisementData) {
            ignoredBroadDiscoveries += 1
            return
        }
        debugLog("didDiscover name=\(peripheral.name ?? "nil") rssi=\(RSSI) broad=\(broadScanActive) adv=\(advertisementSummary(advertisementData))")
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        scanGeneration += 1
        broadScanActive = false
        central.stopScan()
        target = peripheral
        peripheral.delegate = self
        setStatus("连接手表", severity: .processing)
        debugLog("connect peripheral=\(peripheral.identifier.uuidString)")
        central.connect(peripheral)
    }

    private func matchesWatchAdvertisement(peripheral: CBPeripheral,
                                           advertisementData: [String: Any]) -> Bool {
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           serviceUUIDs.contains(serviceUUID) {
            return true
        }
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 7,
           manufacturerData[0] == 0xFF,
           manufacturerData[1] == 0xFF,
           manufacturerData.suffix(5) == Data("WANJI".utf8) {
            return true
        }
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let normalizedName = localName.lowercased()
        return normalizedName.contains("wanji")
            || normalizedName.contains("wristnote")
            || normalizedName.contains("腕记")
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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debugLog("didConnect peripheral=\(peripheral.identifier.uuidString)")
        setStatus("读取手表服务", severity: .processing)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        debugLog("didFailToConnect error=\(error?.localizedDescription ?? "unknown")")
        if target === peripheral {
            target = nil
        }
        let message = error?.localizedDescription ?? ""
        if message.localizedCaseInsensitiveContains("Peer removed pairing information") {
            setStatus("蓝牙连接需要恢复：请保持手表端腕记打开，重开手机蓝牙后重试", severity: .error)
        } else {
            if scheduleAutoRetryIfNeeded(after: activeRetryAttempt, reason: "connect_failed") {
                return
            }
            setStatus("手表连接失败", severity: .error)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        debugLog("didDisconnect error=\(error?.localizedDescription ?? "nil")")
        if target === peripheral {
            target = nil
            command = nil
            finishPendingSyncCommand(reason: "disconnect")
        }
    }
}

extension BluetoothWatchSyncRequester: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        debugLog("didDiscoverServices error=\(error?.localizedDescription ?? "nil") services=\(peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "nil")")
        guard error == nil, let services = peripheral.services else {
            setStatus("手表服务不可用", severity: .error)
            return
        }
        guard let service = services.first(where: { $0.uuid == serviceUUID }) else {
            setStatus("手表版本不匹配", severity: .warning)
            return
        }
        peripheral.discoverCharacteristics([commandUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        debugLog("didDiscoverCharacteristics error=\(error?.localizedDescription ?? "nil") characteristics=\(service.characteristics?.map { "\($0.uuid.uuidString):\($0.properties.rawValue)" }.joined(separator: ",") ?? "nil")")
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == commandUUID }) else {
            setStatus("手表同步入口不可用", severity: .warning)
            return
        }
        command = characteristic
        writeSyncCommand()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        debugLog("didWriteValue error=\(error?.localizedDescription ?? "nil")")
        completeWrite(error: error)
    }
}
