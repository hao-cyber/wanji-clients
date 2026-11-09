import Foundation
import Combine
import CoreBluetooth

enum ReceiverEventSeverity {
    case info
    case success
    case warning
    case error
    case receiving
    case processing
}

struct ReceiverEvent {
    let message: String
    let severity: ReceiverEventSeverity
    var progress: Double?
    let occurredAt: Date
}

enum ReceiverState: Equatable {
    case stopped
    case starting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .stopped:
            return "未启动"
        case .starting:
            return "启动中"
        case .ready:
            return "已开启"
        case .failed:
            return "不可用"
        }
    }

    var failureMessage: String? {
        if case let .failed(message) = self {
            return message
        }
        return nil
    }
}

private struct BLEWatchAudioHeader: Decodable {
    let token: String
    let filename: String?
    let createdAt: Double?
    let uploadId: String?
    let size: Int

    private enum CodingKeys: String, CodingKey {
        case token
        case filename
        case createdAt
        case uploadId
        case size
    }

    private enum CompactCodingKeys: String, CodingKey {
        case token = "t"
        case filename = "f"
        case createdAt = "c"
        case uploadId = "u"
        case size = "s"
    }

    init(from decoder: Decoder) throws {
        let full = try decoder.container(keyedBy: CodingKeys.self)
        let compact = try decoder.container(keyedBy: CompactCodingKeys.self)

        token = try full.decodeIfPresent(String.self, forKey: .token)
            ?? compact.decode(String.self, forKey: .token)
        filename = try full.decodeIfPresent(String.self, forKey: .filename)
            ?? compact.decodeIfPresent(String.self, forKey: .filename)
        createdAt = try full.decodeIfPresent(Double.self, forKey: .createdAt)
            ?? compact.decodeIfPresent(Double.self, forKey: .createdAt)
        uploadId = try full.decodeIfPresent(String.self, forKey: .uploadId)
            ?? compact.decodeIfPresent(String.self, forKey: .uploadId)
        size = try full.decodeIfPresent(Int.self, forKey: .size)
            ?? compact.decode(Int.self, forKey: .size)
    }
}

private final class BLEWatchTransfer {
    let filename: String
    let recordedAt: Date?
    let uploadId: String?
    let expectedBytes: Int
    var body = Data()

    init(header: BLEWatchAudioHeader) {
        self.filename = header.filename?.isEmpty == false
            ? header.filename!
            : "watch-\(Int(Date().timeIntervalSince1970)).m4a"
        if let createdAt = header.createdAt, createdAt.isFinite {
            let seconds = createdAt > 10_000_000_000 ? createdAt / 1000 : createdAt
            let date = Date(timeIntervalSince1970: seconds)
            let lowerBound = Date(timeIntervalSince1970: 946_684_800)
            let upperBound = Date().addingTimeInterval(24 * 60 * 60)
            self.recordedAt = (date >= lowerBound && date <= upperBound) ? date : nil
        } else {
            self.recordedAt = nil
        }
        self.uploadId = header.uploadId
        self.expectedBytes = header.size
    }
}

final class BluetoothWatchReceiver: NSObject, ObservableObject {
    @Published private(set) var state: ReceiverState = .stopped
    @Published private(set) var endpoint: String = AppSettings.bleEndpoint
    @Published private(set) var lastEvent = ReceiverEvent(message: "等待手表蓝牙连接",
                                                          severity: .info,
                                                          occurredAt: Date())

    var onAudioReceived: ((Data, String, Date?, String?) async throws -> String)?

    private let serviceUUID = CBUUID(string: AppSettings.bleServiceUUID)
    private let writeUUID = CBUUID(string: AppSettings.bleWriteCharacteristicUUID)
    private var manager: CBPeripheralManager?
    private var transfer: BLEWatchTransfer?
    private let maxBodyBytes = 30 * 1024 * 1024

    func start() {
        debugLog("receiver start state=\(state)")
        guard state != .starting && state != .ready else { return }
        setState(.starting)
        setLastEvent("正在开启蓝牙接收", severity: .info)
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            configureIfPoweredOn()
        }
    }

    func stop() {
        debugLog("receiver stop")
        transfer = nil
        manager?.stopAdvertising()
        manager?.removeAllServices()
        setEndpoint(AppSettings.bleEndpoint)
        setState(.stopped)
        setLastEvent("蓝牙接收端已停止", severity: .info)
    }

    @discardableResult
    func refreshEndpoint(reportUnchanged: Bool = false) -> String {
        if reportUnchanged {
            setLastEvent("蓝牙配置已是最新", severity: .success)
        }
        return AppSettings.bleEndpoint
    }

    private func configureIfPoweredOn() {
        guard let manager else { return }
        debugLog("receiver configure state=\(manager.state.rawValue)")
        guard manager.state == .poweredOn else {
            let message: String
            switch manager.state {
            case .poweredOff:
                message = "蓝牙未开启，请在系统设置打开蓝牙"
            case .unauthorized:
                message = "腕记没有蓝牙权限，请在系统设置允许蓝牙"
            case .unsupported:
                message = "此设备不支持蓝牙接收"
            default:
                message = "蓝牙接收暂未就绪"
            }
            setState(.failed(message))
            setLastEvent(message, severity: .error)
            return
        }

        manager.removeAllServices()
        let write = CBMutableCharacteristic(type: writeUUID,
                                            properties: [.write],
                                            value: nil,
                                            permissions: [.writeable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [write]
        manager.add(service)
        debugLog("receiver add service=\(serviceUUID.uuidString) write=\(writeUUID.uuidString)")
    }

    private func handleFrame(_ data: Data) -> CBATTError.Code {
        debugLog("receiver frame bytes=\(data.count) type=\(data.first.map(String.init) ?? "nil")")
        guard let frameType = data.first else { return .invalidPdu }
        let payload = data.dropFirst()
        switch frameType {
        case 1:
            return handleHeader(Data(payload))
        case 2:
            return handleChunk(Data(payload))
        case 3:
            return .success
        default:
            return .requestNotSupported
        }
    }

    private func handleHeader(_ data: Data) -> CBATTError.Code {
        guard let header = try? JSONDecoder().decode(BLEWatchAudioHeader.self, from: data) else {
            setLastEvent("蓝牙上传被拒绝：头信息格式错误", severity: .warning)
            return .invalidPdu
        }
        let expected = AppSettings.normalizedWatchToken(
            UserDefaults.standard.string(forKey: AppSettings.watchTokenKey) ?? ""
        )
        guard !expected.isEmpty && header.token == expected else {
            setLastEvent("手表绑定不匹配：请重新绑定手表", severity: .error)
            return .insufficientAuthentication
        }
        guard header.size > 2_000 && header.size <= maxBodyBytes else {
            setLastEvent("蓝牙上传被拒绝：音频大小不可用", severity: .warning)
            return .invalidAttributeValueLength
        }
        transfer = BLEWatchTransfer(header: header)
        debugLog("receiver header accepted size=\(header.size) filename=\(header.filename ?? "nil")")
        setLastEvent("正在接收手表录音 0%（0 B/\(Self.byteCountText(header.size))）",
                     severity: .receiving,
                     progress: 0)
        return .success
    }

    private func handleChunk(_ data: Data) -> CBATTError.Code {
        guard let transfer else { return .unlikelyError }
        guard transfer.body.count + data.count <= maxBodyBytes else {
            setLastEvent("蓝牙上传被拒绝：音频超过 30 MB", severity: .warning)
            self.transfer = nil
            return .invalidAttributeValueLength
        }
        transfer.body.append(data)
        if transfer.body.count == data.count || transfer.body.count == transfer.expectedBytes {
            debugLog("receiver chunk progress=\(transfer.body.count)/\(transfer.expectedBytes)")
        }
        let progress = min(1, Double(transfer.body.count) / Double(max(1, transfer.expectedBytes)))
        let percent = Int((progress * 100).rounded(.down))
        setLastEvent("正在接收手表录音 \(percent)%（\(Self.byteCountText(transfer.body.count))/\(Self.byteCountText(transfer.expectedBytes))）",
                     severity: .receiving,
                     progress: progress)
        return .success
    }

    private func finish(_ request: CBATTRequest) {
        guard let transfer else {
            manager?.respond(to: request, withResult: .unlikelyError)
            return
        }
        guard transfer.body.count == transfer.expectedBytes else {
            self.transfer = nil
            setLastEvent("蓝牙上传中断：收到的音频不完整", severity: .warning)
            manager?.respond(to: request, withResult: .unlikelyError)
            return
        }
        guard transfer.body.count > 2_000 else {
            self.transfer = nil
            setLastEvent("蓝牙上传被拒绝：音频太短或未录到内容", severity: .warning)
            manager?.respond(to: request, withResult: .invalidAttributeValueLength)
            return
        }

        self.transfer = nil
        let body = transfer.body
        debugLog("receiver finish bytes=\(body.count) filename=\(transfer.filename)")
        setLastEvent("蓝牙录音已接收，正在保存到本机并加入转写队列",
                     severity: .processing)
        Task {
            do {
                let receipt = try await onAudioReceived?(body,
                                                         transfer.filename,
                                                         transfer.recordedAt,
                                                         transfer.uploadId) ?? "蓝牙收到 \(transfer.filename)"
                await MainActor.run {
                    self.setLastEvent(receipt, severity: .success)
                    self.manager?.respond(to: request, withResult: .success)
                }
            } catch {
                await MainActor.run {
                    self.setLastEvent("保存失败：本机空间或文件权限异常", severity: .error)
                    self.manager?.respond(to: request, withResult: .unlikelyError)
                }
            }
        }
    }

    private static func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func setState(_ state: ReceiverState) {
        DispatchQueue.main.async { self.state = state }
    }

    private func setEndpoint(_ endpoint: String) {
        DispatchQueue.main.async { self.endpoint = endpoint }
    }

    private func setLastEvent(_ event: String,
                              severity: ReceiverEventSeverity,
                              progress: Double? = nil) {
        debugLog("receiver event=\(event) severity=\(severity)")
        DispatchQueue.main.async {
            self.lastEvent = ReceiverEvent(message: event,
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
}

extension BluetoothWatchReceiver: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        debugLog("receiver manager state=\(peripheral.state.rawValue)")
        configureIfPoweredOn()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            let message = "蓝牙服务启动失败：\(error.localizedDescription)"
            setState(.failed(message))
            setLastEvent(message, severity: .error)
            return
        }
        debugLog("receiver didAdd service=\(service.uuid.uuidString)")
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Wanji",
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            let message = "蓝牙广播失败：\(error.localizedDescription)"
            debugLog("receiver advertising failed=\(error.localizedDescription)")
            setState(.failed(message))
            setLastEvent(message, severity: .error)
            return
        }
        debugLog("receiver advertising started service=\(serviceUUID.uuidString)")
        setEndpoint(AppSettings.bleEndpoint)
        setState(.ready)
        setLastEvent("蓝牙接收端已开启", severity: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        debugLog("receiver didReceiveWrite count=\(requests.count)")
        for request in requests {
            guard request.characteristic.uuid == writeUUID, let value = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            if value.first == 3 {
                finish(request)
                continue
            }
            peripheral.respond(to: request, withResult: handleFrame(value))
        }
    }
}
