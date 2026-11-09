import SwiftUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import Network

private enum StorageAction: Equatable {
    case clearAll
    case clearCompleted
}

enum RecordingDetailKind: String, Equatable {
    case transcript
    case notes

    var title: String {
        switch self {
        case .transcript: return "完整转写"
        case .notes: return "纪要"
        }
    }

    var copyLabel: String { "复制\(title)" }
    var shareLabel: String { "分享\(title)" }
}

private struct SelectedRecordingDetail: Identifiable, Equatable {
    let recordingID: UUID
    let kind: RecordingDetailKind

    var id: String {
        "\(recordingID.uuidString)-\(kind.rawValue)"
    }
}

private struct RecordingDayGroup: Identifiable {
    let date: Date
    let title: String
    let items: [MeetingRecording]

    var id: Date { date }
}

final class NetworkStatusMonitor: ObservableObject {
    @Published private(set) var status: NWPath.Status = .requiresConnection
    @Published private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "wanji.network-status")

    var isOffline: Bool {
        status != .satisfied
    }

    var canReachRemoteBackend: Bool {
        status == .satisfied
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.status = path.status
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var store = RecordingStore()
    @StateObject private var watchSyncRequester = BluetoothWatchSyncRequester()
    @StateObject private var watchPullClient = BluetoothWatchPullClient()
    @StateObject private var watchReceiver = BluetoothWatchReceiver()
    @StateObject private var networkMonitor = NetworkStatusMonitor()
    @AppStorage(AppSettings.watchTokenKey) private var watchToken = ""
    @AppStorage(AppSettings.watchBindingConfirmedKey) private var watchBindingConfirmed = false
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var selectedDetail: SelectedRecordingDetail?
    @State private var copiedValue: String?
    @State private var configured = false
    @State private var settingsRevision = 0
    @State private var confirmingClearAll = false
    @State private var confirmingClearCompletedAudio = false
    @State private var generatingAll = false
    @State private var storageAction: StorageAction?
    @State private var copyFeedback: CopyFeedback?
    @State private var storageFeedback: CopyFeedback?
    @State private var generationFeedback: CopyFeedback?
    @StateObject private var playback = AudioPlaybackController()
    @State private var manualWatchBindRequested = false
    @State private var syncDetailsExpanded = false
    @State private var automaticPullWorkItem: DispatchWorkItem?
    @State private var automaticPullReason: String?
    @State private var idleForegroundRecheckCount = 0
    @State private var searchText = ""
    @State private var harmonyPushFallbackPending = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if shouldShowReceiverPanel {
                            receiverPanel
                                .padding(.horizontal, 18)
                                .padding(.top, 8)
                        }
                        if store.hasActiveGeneration {
                            generationControlPanel
                                .padding(.horizontal, 18)
                        }
                        if let storageFeedback {
                            CopyConfirmationRow(feedback: storageFeedback)
                                .padding(.horizontal, 18)
                        }
                        if let error = store.errorText {
                            issuePanel(error)
                                .padding(.horizontal, 18)
                        }
                        queueSection
                        Color.clear.frame(height: 28)
                    }
                }
                .refreshable {
                    requestWatchSyncNow()
                    try? await Task.sleep(nanoseconds: 650_000_000)
                }
            }
            .navigationTitle("腕记")
            .navigationBarTitleDisplayMode(.inline)
            .wanjiSearchable(enabled: store.items.count >= 5, text: $searchText)
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.audio, .item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        let result = await store.importFiles(urls)
                        showImportFeedback(result)
                    }
                case .failure(let error):
                    store.errorText = "导入失败：\(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                settingsRevision += 1
            }) {
                SettingsView(totalRecordingCount: store.items.count,
                             completedAudioCount: store.completedAudioRetainedCount,
                             totalSizeText: store.totalSizeText,
                             dataActionsDisabled: store.hasActiveGeneration || storageAction != nil,
                             onImportAudio: {
                                 showingSettings = false
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                     showingImporter = true
                                 }
                             },
                             onClearCompletedAudio: clearCompletedAudio,
                             onClearAll: clearAllLocalRecordings)
            }
            .sheet(item: $selectedDetail) { selected in
                if let item = store.items.first(where: { $0.id == selected.recordingID }) {
                    RecordingDetailView(item: item,
                                        kind: selected.kind,
                                        playing: playback.isPlaying(item.id),
                                        playbackElapsed: playback.isPlaying(item.id) ? playback.elapsed : 0,
                                        playbackDurationText: playbackDurationText(for: item),
                                        regenerating: store.isActiveGeneration(item),
                                        canRegenerate: item.audioRetained) { seconds in
                        playRecordingFromTranscript(item, at: seconds)
                    } onSwitchKind: { kind in
                        selectedDetail = SelectedRecordingDetail(recordingID: item.id, kind: kind)
                    } onRegenerate: {
                        if canStartRemoteGeneration {
                            Task { await store.generateNotes(for: item) }
                        } else if backendConfigured {
                            showGenerationFeedback(CopyFeedback(text: networkWarningText ?? "网络不可用，请联网后重试", severity: .warning))
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } else {
                            selectedDetail = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showingSettings = true
                            }
                        }
                    }
                } else {
                    MissingRecordingDetailView()
                }
            }
            .onAppear {
                configureOnce()
                startWatchRequesterIfNeededForBinding()
                startHarmonyReceiverIfBound()
                watchPullClient.start()
                scheduleAutomaticWatchPull(reason: "appear")
                updateIdleTimer()
            }
            .onChange(of: scenePhase) { _, _ in
                updateIdleTimer()
                if scenePhase == .active {
                    startWatchRequesterIfNeededForBinding()
                    startHarmonyReceiverIfBound()
                    watchPullClient.start()
                    scheduleAutomaticWatchPull(reason: "active")
                }
                if scenePhase != .active {
                    automaticPullWorkItem?.cancel()
                    automaticPullWorkItem = nil
                    automaticPullReason = nil
                    idleForegroundRecheckCount = 0
                    watchSyncRequester.stop()
                }
            }
            .onChange(of: watchPullClient.syncing) { _, _ in
                updateIdleTimer()
            }
            .onChange(of: store.hasActiveGeneration) { _, _ in
                updateIdleTimer()
            }
            .onChange(of: watchSyncRequester.status) { _, status in
                if Self.isTerminalBindStatus(status) {
                    manualWatchBindRequested = false
                }
            }
            .onChange(of: watchBindingConfirmed) { _, confirmed in
                if confirmed {
                    manualWatchBindRequested = false
                    idleForegroundRecheckCount = 0
                    scheduleAutomaticWatchPull(reason: "bound")
                    startHarmonyReceiverIfBound()
                }
            }
            .onChange(of: watchPullClient.lastEvent.occurredAt) { _, _ in
                handleWatchPullEvent(watchPullClient.lastEvent.message)
            }
            .onOpenURL { url in
                handleConfigurationURL(url)
            }
            .onDisappear {
                automaticPullWorkItem?.cancel()
                automaticPullWorkItem = nil
                automaticPullReason = nil
                UIApplication.shared.isIdleTimerDisabled = false
                stopPlayback()
                watchSyncRequester.stop()
                watchPullClient.stop()
                watchReceiver.stop()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("设置")
                }
            }
        }
    }

    private func handleConfigurationURL(_ url: URL) {
        let result = BackendConfigurationLink.apply(url)
        applyConfigurationResult(result)
    }

    private func applyConfigurationResult(_ result: BackendConfigurationLink.ApplyResult) {
        guard let feedback = result.feedback else { return }
        settingsRevision += 1
        showStorageFeedback(feedback)
        if case .applied = result {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func configureOnce() {
        guard !configured else { return }
        configured = true
        if watchToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let legacyToken = UserDefaults.standard.string(forKey: AppSettings.legacyWatchTokenKey),
           !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            watchToken = legacyToken
            UserDefaults.standard.removeObject(forKey: AppSettings.legacyWatchTokenKey)
        }
        if watchToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            watchToken = Self.makeToken()
        }
        store.load()
        openDebugDetailIfRequested()
        watchPullClient.onAudioReceived = { data, filename, recordedAt, durationMs, uploadId in
            let outcome = try await MainActor.run {
                try store.ingestWatchAudioFromWatch(data,
                                                       filename: filename,
                                                       recordedAt: recordedAt ?? Date(),
                                                       durationMs: durationMs,
                                                       externalID: uploadId)
            }
            return outcome.watchMessage
        }
        watchReceiver.onAudioReceived = { data, filename, recordedAt, uploadId in
            let outcome = try await MainActor.run {
                try store.ingestWatchAudioFromWatch(data,
                                                     filename: filename,
                                                     recordedAt: recordedAt ?? Date(),
                                                     durationMs: nil,
                                                     externalID: uploadId)
            }
            return outcome.watchMessage
        }
        watchSyncRequester.onSyncCommandFinished = { _ in
            harmonyPushFallbackPending = false
        }
    }

    private func openDebugDetailIfRequested() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--wanji-open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                showingSettings = true
            }
            return
        }
        let kind: RecordingDetailKind?
        if arguments.contains("--wanji-open-notes") {
            kind = .notes
        } else if arguments.contains("--wanji-open-transcript") {
            kind = .transcript
        } else {
            kind = nil
        }
        guard let kind, let item = store.items.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            selectedDetail = SelectedRecordingDetail(recordingID: item.id, kind: kind)
        }
        #endif
    }

    private var backendConfigured: Bool {
        _ = settingsRevision
        return backendStatus.isReady
    }

    private var canStartRemoteGeneration: Bool {
        backendConfigured && networkMonitor.canReachRemoteBackend
    }

    private var backendStatus: MeetingNotesAPI.BackendStatus {
        _ = settingsRevision
        return MeetingNotesAPI.backendStatus()
    }

    private var backendSetupPanel: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 5) {
                Text("开启文字整理")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentBlue)
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("开启文字整理")
    }

    private var pendingReadyPanel: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .frame(width: 34, height: 34)
                        .background(Color.green.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(store.generateableCount) 条录音可生成")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.primaryText)
                        Text(generationReadinessText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        runBulkGenerate()
                    } label: {
                        if generatingAll {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 62, height: 34)
                        } else {
                            Text(bulkGenerateButtonTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(minWidth: 62, minHeight: 34)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(generatingAll || store.generateableCount == 0 || !canStartRemoteGeneration)
                    .accessibilityLabel("生成全部可处理录音")
                }
                if let networkWarningText {
                    NetworkStatusRow(text: networkWarningText, color: networkWarningColor)
                }
                if let generationFeedback {
                    CopyConfirmationRow(feedback: generationFeedback)
                }
            }
        }
    }

    @ViewBuilder
    private var receiverPanel: some View {
        if shouldExpandWatchPanel {
            AppCard {
                VStack(alignment: .leading, spacing: 8) {
                    watchSummaryRow
                    if shouldShowWatchConsole {
                        WatchSyncConsole(event: watchConsoleEvent,
                                         bound: watchBindingConfirmed,
                                         syncing: watchPullClient.syncing,
                                         preparing: watchBindPreparing,
                                         guidance: watchSyncGuidance,
                                         detailsExpanded: $syncDetailsExpanded)
                    }
                    if let copyFeedback {
                        CopyConfirmationRow(feedback: copyFeedback)
                    }
                }
            }
        } else {
            watchSummaryRow
                .padding(.horizontal, 4)
        }
    }

    private var watchSummaryRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    watchSummaryLabel
                    watchPrimaryAction
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    watchSummaryLabel
                    Spacer(minLength: 8)
                    watchPrimaryAction
                }
            }
        }
    }

    private var watchSummaryLabel: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(watchPanelColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(watchPanelTitle)
                    .font(.system(size: shouldExpandWatchPanel ? 17 : 14, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text(watchPanelSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(shouldExpandWatchPanel ? 2 : 1)
            }
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var watchPrimaryAction: some View {
        if watchBindingConfirmed {
            if watchPullClient.syncing || automaticRecheckPending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(watchPullClient.syncing ? "同步中" : "查找中")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondaryText)
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    requestWatchSyncNow()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 72, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentBlue)
                .disabled(watchBindPreparing)
                .accessibilityLabel("重新查找手表录音")
            }
        } else {
            Button {
                bindWatchNow()
            } label: {
                HStack(spacing: 8) {
                    if watchBindPreparing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                        Text("连接中")
                    } else {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                        Text("允许同步")
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 104, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!watchTokenReadyForConfig || watchBindPreparing)
            .accessibilityLabel("允许这台手表同步录音")
        }
    }

    private var watchTokenReadyForConfig: Bool {
        AppSettings.watchTokenValidationMessage(watchToken) == nil
    }

    private var watchPanelTitle: String {
        if watchNeedsUpdate { return "更新手表" }
        if watchBindPreparing { return "连接中" }
        if !watchBindingConfirmed { return "连接手表" }
        if watchPullClient.syncing { return "同步中" }
        if automaticRecheckPending { return "正在查找" }
        if watchStatusWarning { return "查找手表" }
        if autoRecoverableWatchError { return "查找手表" }
        if watchStatusError { return "打开手表" }
        return "已就绪"
    }

    private var watchPanelSubtitle: String {
        if watchNeedsUpdate {
            return "更新后会自动同步。"
        }
        if watchBindPreparing {
            return "靠近即可。"
        }
        if !watchBindingConfirmed {
            return "首次连接后自动同步。"
        }
        if watchPullClient.syncing {
            return watchPullClient.lastEvent.message
        }
        if automaticRecheckPending {
            return "靠近后自动同步。"
        }
        if watchStatusWarning {
            return "靠近后自动同步。"
        }
        if autoRecoverableWatchError {
            return "系统会自动重试。"
        }
        if watchStatusError {
            if watchPullClient.lastEvent.message.contains("封装损坏") {
                return watchPullClient.lastEvent.message
            }
            return "打开手表端腕记。"
        }
        return "打开手机会自动同步。"
    }

    private var watchPanelColor: Color {
        if watchNeedsUpdate { return .red }
        if watchBindPreparing { return .accentBlue }
        if !watchBindingConfirmed { return .orange }
        if watchPullClient.syncing { return .accentBlue }
        if automaticRecheckPending { return .accentBlue }
        if watchStatusWarning { return .accentBlue }
        if autoRecoverableWatchError { return .accentBlue }
        switch watchPullClient.lastEvent.severity {
        case .error: return .red
        case .warning: return .orange
        default: return .green
        }
    }

    private var watchStatusWarning: Bool {
        watchBindingConfirmed
            && !watchPullClient.syncing
            && watchPullClient.lastEvent.severity == .warning
    }

    private var watchStatusError: Bool {
        watchBindingConfirmed
            && !watchNeedsUpdate
            && !watchPullClient.syncing
            && watchPullClient.lastEvent.severity == .error
    }

    private var automaticRecheckPending: Bool {
        switch automaticPullReason {
        case "bluetooth_unready_recheck", "not_found_recheck", "queue_unavailable_recheck", "idle_recheck_early", "idle_recheck":
            return true
        default:
            return false
        }
    }

    private var autoRecoverableWatchError: Bool {
        watchBindingConfirmed
            && !watchPullClient.syncing
            && watchPullClient.lastEvent.message == "手表录音队列暂时不可用"
    }

    private var watchSyncGuidance: String {
        if watchBindPreparing {
            return "请在手表端打开腕记并保持靠近，连接后会自动同步。"
        }
        if !watchBindingConfirmed {
            return "这里仅允许腕记录音同步，不会改变华为运动健康的配对。"
        }
        if watchPullClient.syncing {
            return "同步时录音先落到手机本机；转写与纪要只在你配置后端后发生。"
        }
        if watchNeedsUpdate {
            return "手机已切到新的蓝牙通知流。更新手表端腕记后再同步。"
        }
        switch watchPullClient.lastEvent.severity {
        case .error:
            if autoRecoverableWatchError {
                return "队列暂时不可用。手机会在前台自动再查，手表端保持腕记打开即可。"
            }
            return "通常是手表端腕记未运行或版本未更新。打开手表端后手机会继续找。"
        case .warning:
            if watchPullClient.lastEvent.message == "未发现腕记蓝牙服务" {
                return "手机能扫描到附近蓝牙，但没有看到腕记同步服务。保持手表端腕记在前台，手机会自动再查。"
            }
            return "这是可恢复状态。系统会自动重试，手表端保持腕记打开即可。"
        case .success:
            return "新录音会在打开手机腕记时进入队列，也可以手动点同步。"
        default:
            return "手机主动读取手表录音，不经过后端。"
        }
    }

    private var pairingChecks: [PairingCheck] {
        [
            PairingCheck(title: "发现手表",
                         value: watchSyncRequester.status,
                         icon: "applewatch.radiowaves.left.and.right",
                         color: .accentBlue),
            PairingCheck(title: "同步授权",
                         value: watchBindPreparing ? "连接中" : (watchBindingConfirmed ? "已允许" : "未允许"),
                         icon: watchBindingConfirmed ? "link" : "link.badge.plus",
                         color: watchBindPreparing ? .accentBlue : (watchBindingConfirmed ? .green : .orange)),
            PairingCheck(title: "自动传输",
                         value: watchNeedsUpdate ? "需更新手表" : (watchPullClient.syncing ? "读取中" : "手机拉取"),
                         icon: watchNeedsUpdate ? "exclamationmark.triangle" : "applewatch.radiowaves.left.and.right",
                         color: watchNeedsUpdate ? .red : (watchPullClient.syncing ? .accentBlue : .green))
        ]
    }

    private var watchConsoleEvent: ReceiverEvent {
        if watchBindPreparing && !watchPullClient.syncing {
            return watchSyncRequester.lastEvent
        }
        return watchPullClient.lastEvent
    }

    private var watchNeedsUpdate: Bool {
        watchPullClient.lastEvent.severity == .error
            && watchPullClient.lastEvent.message.contains("手表端需要更新")
    }

    private var shouldShowWatchConsole: Bool {
        watchBindPreparing
            || watchPullClient.syncing
            || watchNeedsUpdate
            || (watchStatusError && !autoRecoverableWatchError)
    }

    private var shouldExpandWatchPanel: Bool {
        !watchBindingConfirmed
            || shouldShowWatchConsole
    }

    private var shouldShowReceiverPanel: Bool {
        !watchBindingConfirmed
            || watchBindPreparing
            || watchPullClient.syncing
            || automaticRecheckPending
            || watchStatusWarning
            || autoRecoverableWatchError
            || watchStatusError
            || copyFeedback != nil
    }

    private var shouldShowStorageNotice: Bool {
        !store.items.isEmpty
            && (store.totalAudioBytes > 250 * 1024 * 1024
                || storageAction != nil)
    }

    private var watchBindPreparing: Bool {
        if manualWatchBindRequested { return true }
        switch watchSyncRequester.status {
        case "查找可绑定手表", "扩大查找手表", "连接手表", "读取手表服务", "写入绑定":
            return true
        default:
            return false
        }
    }

    private var statusGrid: some View {
        AppCard {
            HStack(spacing: 0) {
                DashboardMetric(title: "录音", value: "\(store.items.count)")
                Divider().frame(height: 34)
                DashboardMetric(title: "待生成", value: "\(store.pendingCount)")
                Divider().frame(height: 34)
                DashboardMetric(title: "已完成", value: "\(store.completedCount)")
                Divider().frame(height: 34)
                DashboardMetric(title: "占用", value: store.totalSizeText)
                if store.unavailableCount > 0 {
                    Divider().frame(height: 34)
                    DashboardMetric(title: "不可重试", value: "\(store.unavailableCount)", color: .red)
                }
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("录音")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 18)
                .frame(minHeight: 44, alignment: .leading)

            if store.items.isEmpty {
                emptyState
                    .padding(.horizontal, 18)
            } else {
                if store.generateableCount > 0 {
                    Group {
                        if backendConfigured {
                            queueActionPanel
                        } else {
                            backendSetupPanel
                        }
                    }
                    .padding(.horizontal, 18)
                }
                ForEach(recordingDayGroups) { group in
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondaryText)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                    ForEach(group.items) { item in
                        RecordingRow(item: item,
                                     titleText: recordingTimeText(for: item),
                                     sending: store.sendingID == item.id,
                                     queued: store.isQueuedForGeneration(item),
                                     deletingLocked: store.isActiveGeneration(item),
                                     busy: generatingAll,
                                     queueBusy: store.sendingID != nil || generatingAll,
                                     backendReady: backendConfigured,
                                     networkReady: networkMonitor.canReachRemoteBackend,
                                     playing: playback.isPlaying(item.id),
                                     playbackProgress: playbackProgress(for: item),
                                     playbackElapsedText: playbackElapsedText(for: item),
                                     playbackDurationText: playbackDurationText(for: item),
                                     onGenerate: {
                                         if canStartRemoteGeneration {
                                             Task { await store.generateNotes(for: item) }
                                         } else if backendConfigured {
                                             showGenerationFeedback(CopyFeedback(text: networkWarningText ?? "网络不可用，请联网后重试", severity: .warning))
                                             UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                         }
                                     },
                                     onTogglePlayback: { togglePlayback(for: item) },
                                     onSeekPlayback: { progress in seekPlayback(to: progress, for: item) },
                                     onOpenTranscript: {
                                         selectedDetail = SelectedRecordingDetail(recordingID: item.id, kind: .transcript)
                                     },
                                     onOpenNotes: {
                                         selectedDetail = SelectedRecordingDetail(recordingID: item.id, kind: .notes)
                                     },
                                     onDeleteAudio: {
                                         deleteCompletedAudio(for: item)
                                     },
                                     onDelete: { deleteRecording(item) })
                            .padding(.horizontal, 18)
                    }
                }
            }
        }
    }

    private var filteredItems: [MeetingRecording] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            item.displayTitle.localizedCaseInsensitiveContains(query)
                || item.sourceText.localizedCaseInsensitiveContains(query)
                || item.transcriptText.localizedCaseInsensitiveContains(query)
                || item.noteText.localizedCaseInsensitiveContains(query)
        }
    }

    private var recordingDayGroups: [RecordingDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredItems) { item in
            calendar.startOfDay(for: item.importedAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            RecordingDayGroup(date: date,
                              title: recordingDayTitle(for: date),
                              items: grouped[date, default: []].sorted { $0.importedAt > $1.importedAt })
        }
    }

    private func recordingDayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            ? "M月d日"
            : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func recordingTimeText(for item: MeetingRecording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: item.importedAt)
        return item.durationMs > 0 ? "\(time) · \(item.durationText)" : time
    }

    private var storagePrivacyPanel: some View {
        AppCard {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: storageNoticeIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(storageNoticeColor)
                    .frame(width: 28, height: 28)
                    .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.cardBorder, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(storageNoticeTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(storagePrivacyText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if store.completedAudioRetainedCount > 0 {
                    Button {
                        confirmingClearCompletedAudio = true
                    } label: {
                        if storageAction == .clearCompleted {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 42, height: 34)
                        } else {
                            Image(systemName: "waveform.slash")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 42, height: 34)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.hasActiveGeneration || storageAction != nil)
                    .accessibilityLabel("只清理已完成原始音频")
                }
                Button(role: .destructive) {
                    confirmingClearAll = true
                } label: {
                    if storageAction == .clearAll {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 42, height: 34)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .frame(width: 42, height: 34)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.hasActiveGeneration || storageAction != nil)
                .accessibilityLabel("清空本机录音")
            }
        }
        .confirmationDialog("清理已完成原始音频？",
                            isPresented: $confirmingClearCompletedAudio,
                            titleVisibility: .visible) {
            Button("清理 \(store.completedAudioRetainedCount) 条原音频", role: .destructive) {
                clearCompletedAudio()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只删除已生成纪要记录里的本机原始音频，纪要文本会保留；清理后不能重新生成这些纪要。")
        }
    }

    private var storagePrivacyText: String {
        var base = "\(store.totalSizeText) · 本机加密保护，播放和上传期间保持可访问"
        if store.completedAudioRetainedCount > 0 {
            base += " · \(store.completedAudioRetainedCount) 条可清原音频"
        }
        if storageAction != nil {
            return "正在清理本机录音"
        }
        if store.hasActiveGeneration {
            return "\(base) · 生成中暂不可清空"
        }
        return base
    }

    private var storageNoticeTitle: String {
        store.totalAudioBytes > 100 * 1024 * 1024 ? "本机占用偏高" : "本机保护"
    }

    private var storageNoticeIcon: String {
        store.totalAudioBytes > 100 * 1024 * 1024 ? "externaldrive.badge.exclamationmark" : "lock.doc"
    }

    private var storageNoticeColor: Color {
        store.totalAudioBytes > 100 * 1024 * 1024 ? .orange : .accentBlue
    }

    private var queueActionPanel: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(store.generateableCount) 条待生成")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text(queueActionSubtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        runBulkGenerate()
                    } label: {
                        if generatingAll {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 52, height: 34)
                        } else {
                            Text(bulkGenerateButtonTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(minWidth: 62, minHeight: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(generatingAll || store.generateableCount == 0 || !networkMonitor.canReachRemoteBackend)
                    .accessibilityLabel("生成全部待处理录音")
                }
                if let networkWarningText, backendConfigured {
                    NetworkStatusRow(text: networkWarningText, color: networkWarningColor)
                }
                if let generationFeedback {
                    CopyConfirmationRow(feedback: generationFeedback)
                }
            }
        }
    }

    private var generationControlPanel: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .frame(width: 34, height: 34)
                        .background(Color.orange.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在生成")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.primaryText)
                        Text(generationControlText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        cancelGenerationQueue()
                    } label: {
                        Label("停止", systemImage: "xmark.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .labelStyle(.iconOnly)
                            .frame(width: 52, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("停止生成")
                }
                if let generationFeedback {
                    CopyConfirmationRow(feedback: generationFeedback)
                }
            }
        }
    }

    private var generationControlText: String {
        let active = store.sendingID == nil ? 0 : 1
        let queued = store.queuedGenerationIDs.count
        if queued > 0 {
            return "处理中，\(queued) 条等待。"
        }
        if active > 0 {
            return "处理中。"
        }
        return "队列处理中。"
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 7) {
            Text("还没有录音")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
            Text("同步完成后会出现在这里。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var bulkGenerateButtonTitle: String {
        if !networkMonitor.canReachRemoteBackend { return "离线" }
        if store.sendingID != nil { return "其余排队" }
        return "生成"
    }

    private var generationReadinessText: String {
        if let networkWarningText {
            return networkWarningText
        }
        return "后端已就绪；点按钮后按队列生成完整转写和纪要。"
    }

    private var queueActionSubtitle: String {
        if let networkWarningText { return networkWarningText }
        return "准备好后生成纪要"
    }

    private var networkWarningText: String? {
        if networkMonitor.isOffline {
            return "网络不可用，录音会留在本机；联网后可继续生成完整转写和纪要。"
        }
        if networkMonitor.isConstrained {
            return "当前是低数据模式，长录音转写可能变慢；建议在稳定网络下生成。"
        }
        return nil
    }

    private var networkWarningColor: Color {
        networkMonitor.isOffline ? .red : .orange
    }

    private func issuePanel(_ text: String) -> some View {
        InfoPanel(icon: "exclamationmark.triangle", title: "需要处理") {
            Text(text)
        }
    }

    private func copy(_ text: String, confirmation: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copiedValue = text
        showCopyFeedback(CopyFeedback(text: confirmation, severity: .success))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if self.copiedValue == text { self.copiedValue = nil }
        }
    }

    private func showCopyFeedback(_ feedback: CopyFeedback) {
        copyFeedback = feedback
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if self.copyFeedback == feedback { self.copyFeedback = nil }
        }
    }

    private func showCopyWarning(_ message: String) {
        copiedValue = nil
        copyFeedback = CopyFeedback(text: message, severity: .warning)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.copyFeedback == CopyFeedback(text: message, severity: .warning) {
                self.copyFeedback = nil
            }
        }
    }

    private func showStorageSuccess(_ message: String) {
        showStorageFeedback(CopyFeedback(text: message, severity: .success))
    }

    private func showStorageWarning(_ message: String) {
        showStorageFeedback(CopyFeedback(text: message, severity: .warning))
    }

    private func showStorageFeedback(_ feedback: CopyFeedback) {
        storageFeedback = feedback
        let generator = UINotificationFeedbackGenerator()
        switch feedback.severity {
        case .success:
            generator.notificationOccurred(.success)
        case .warning:
            generator.notificationOccurred(.warning)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if self.storageFeedback == feedback {
                self.storageFeedback = nil
            }
        }
    }

    private func showImportFeedback(_ result: ImportAudioResult) {
        if result.importedCount > 0, result.hasFailures {
            showStorageFeedback(CopyFeedback(text: "已导入 \(result.importedCount) 条，\(result.failedCount) 条失败", severity: .warning))
        } else if result.importedCount > 0 {
            showStorageSuccess("已导入 \(result.importedCount) 条音频")
        } else if result.hasFailures {
            showStorageFeedback(CopyFeedback(text: "导入失败，请确认文件仍可读取", severity: .warning))
        }
    }

    private func deleteRecording(_ item: MeetingRecording) {
        if store.delete(item) {
            let hasGeneratedText = !item.noteText.isEmpty
                || !item.transcriptText.isEmpty
                || !item.transcriptSegments.isEmpty
            let message = hasGeneratedText ? "已删除这条记录和纪要" : "已删除本机录音"
            showStorageSuccess(message)
        } else {
            showStorageWarning(store.errorText ?? "删除失败，请稍后重试")
        }
    }

    private func deleteCompletedAudio(for item: MeetingRecording) {
        if store.deleteCompletedAudioKeepingNotes(for: item) {
            showStorageSuccess("已清理 1 条原音频，纪要仍保留")
        } else {
            showStorageWarning(store.errorText ?? "原音频未清理，请稍后重试")
        }
    }

    private func clearAllLocalRecordings() {
        let count = store.items.count
        guard count > 0 else { return }
        runStorageAction(.clearAll) {
            if store.deleteAllLocalRecordings() {
                showStorageSuccess("已清空 \(count) 条本机记录")
            } else {
                showStorageWarning(store.errorText ?? "清空失败，未删除的录音已保留")
            }
        }
    }

    private func clearCompletedAudio() {
        runStorageAction(.clearCompleted) {
            let removed = store.deleteCompletedAudioKeepingNotes()
            if removed > 0 {
                showStorageSuccess("已清理 \(removed) 条原音频，纪要仍保留")
            } else {
                showStorageWarning(store.errorText ?? "没有可清理的原音频")
            }
        }
    }

    private func runStorageAction(_ action: StorageAction, operation: @escaping () -> Void) {
        guard storageAction == nil else { return }
        storageAction = action
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            operation()
            storageAction = nil
        }
    }

    private func cancelGenerationQueue() {
        let cancelled = store.cancelGenerationQueue()
        if cancelled > 0 {
            showGenerationFeedback(CopyFeedback(text: "已停止 \(cancelled) 条生成任务，可稍后重试", severity: .success))
        } else {
            showGenerationFeedback(CopyFeedback(text: store.errorText ?? "没有正在生成的任务", severity: .warning))
        }
    }

    private func showGenerationFeedback(_ feedback: CopyFeedback) {
        generationFeedback = feedback
        let generator = UINotificationFeedbackGenerator()
        switch feedback.severity {
        case .success:
            generator.notificationOccurred(.success)
        case .warning:
            generator.notificationOccurred(.warning)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if self.generationFeedback == feedback {
                self.generationFeedback = nil
            }
        }
    }

    private func scheduleAutomaticWatchPull(reason: String) {
        guard watchBindingConfirmed else {
            debugLog("auto pull skipped reason=\(reason) bound=false")
            return
        }
        if reason == "appear" || reason == "active" || reason == "bound" {
            idleForegroundRecheckCount = 0
        }
        let delay = automaticWatchPullDelay(reason: reason)
        if automaticPullWorkItem != nil {
            debugLog("auto pull cancel previous reason=\(reason)")
        }
        automaticPullWorkItem?.cancel()
        let item = DispatchWorkItem {
            automaticPullWorkItem = nil
            automaticPullReason = nil
            guard watchBindingConfirmed else {
                debugLog("auto pull fire skipped reason=\(reason) bound=false")
                return
            }
            guard !watchPullClient.syncing else {
                debugLog("auto pull fire skipped reason=\(reason) syncing=true")
                return
            }
            debugLog("auto pull fire reason=\(reason)")
            watchPullClient.start()
            watchPullClient.syncNow(reason: "auto_\(reason)")
        }
        automaticPullWorkItem = item
        automaticPullReason = reason
        debugLog("auto pull scheduled reason=\(reason) delay=\(String(format: "%.2f", delay))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func automaticWatchPullDelay(reason: String) -> TimeInterval {
        switch reason {
        case "bound":
            return 0.50
        case "appear", "active":
            return 0.0
        case "not_found_recheck":
            return 5.0
        case "bluetooth_unready_recheck":
            return 5.0
        case "queue_unavailable_recheck":
            return 10.0
        case "idle_recheck_early":
            return 30.0
        case "idle_recheck":
            return 90.0
        default:
            return 0.25
        }
    }

    private func handleWatchPullEvent(_ message: String) {
        guard scenePhase == .active,
              watchBindingConfirmed,
              !watchPullClient.syncing else {
            return
        }
        switch message {
        case "手机蓝牙未就绪":
            scheduleAutomaticWatchPull(reason: "bluetooth_unready_recheck")
        case let value where value.contains("未发现") && value.contains("录音服务"):
            startHarmonyPushFallback(reason: value)
        case "未发现腕记蓝牙服务":
            scheduleAutomaticWatchPull(reason: "not_found_recheck")
        case "手表录音队列暂时不可用":
            idleForegroundRecheckCount = 0
            scheduleAutomaticWatchPull(reason: "queue_unavailable_recheck")
        case "手表端版本需要更新", "手表录音服务不可用", "手表录音服务连接失败":
            startHarmonyPushFallback(reason: message)
        case "手表没有待同步录音":
            idleForegroundRecheckCount = 0
            automaticPullWorkItem?.cancel()
            automaticPullWorkItem = nil
            automaticPullReason = nil
            debugLog("auto pull idle recheck skipped reason=empty_queue")
        case let value where value.hasPrefix("已同步 ") && value.hasSuffix(" 条手表录音"):
            idleForegroundRecheckCount = 0
            automaticPullWorkItem?.cancel()
            automaticPullWorkItem = nil
            automaticPullReason = nil
            debugLog("auto pull idle recheck skipped reason=sync_complete")
        default:
            idleForegroundRecheckCount = 0
            break
        }
    }

    private func startWatchRequesterIfNeededForBinding() {
        if watchBindingConfirmed {
            debugLog("sync requester skipped on automatic path bound=true")
            return
        }
        watchSyncRequester.start()
    }

    private func startHarmonyReceiverIfBound() {
        guard watchBindingConfirmed else { return }
        watchReceiver.start()
    }

    private func startHarmonyPushFallback(reason: String) {
        guard watchBindingConfirmed, !harmonyPushFallbackPending else { return }
        harmonyPushFallbackPending = true
        debugLog("harmony push fallback reason=\(reason)")
        watchReceiver.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard watchBindingConfirmed else {
                harmonyPushFallbackPending = false
                return
            }
            watchSyncRequester.start()
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

    private func requestWatchSyncNow() {
        guard !watchPullClient.syncing, !watchBindPreparing else { return }
        cancelAutomaticWatchPull(reason: "manual_button")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        watchPullClient.start()
        watchPullClient.syncNow(reason: "manual_button")
    }

    private func cancelAutomaticWatchPull(reason: String) {
        guard automaticPullWorkItem != nil || automaticPullReason != nil else { return }
        debugLog("auto pull cancelled reason=\(reason) pending=\(automaticPullReason ?? "unknown")")
        automaticPullWorkItem?.cancel()
        automaticPullWorkItem = nil
        automaticPullReason = nil
    }

    private func bindWatchNow() {
        guard !watchBindPreparing, !watchPullClient.syncing else { return }
        manualWatchBindRequested = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if watchToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            watchToken = Self.makeToken()
        }
        watchSyncRequester.start()
        watchSyncRequester.bindDevice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if Self.isTerminalBindStatus(watchSyncRequester.status) || !watchSyncRequester.binding {
                manualWatchBindRequested = false
            }
        }
    }

    private func togglePlayback(for item: MeetingRecording) {
        if playback.isPlaying(item.id) {
            stopPlayback()
            return
        }
        playRecording(for: item)
    }

    private func playRecordingFromTranscript(_ item: MeetingRecording, at seconds: TimeInterval) {
        playRecording(for: item, startAt: seconds)
    }

    private func playRecording(for item: MeetingRecording, startAt seconds: TimeInterval? = nil) {
        guard item.audioRetained else {
            showStorageFeedback(CopyFeedback(text: "原音频已移除，不能播放", severity: .warning))
            return
        }
        do {
            let url = store.audioURL(for: item)
            try playback.play(url: url, recordingID: item.id, startAt: seconds)
        } catch {
            showStorageFeedback(CopyFeedback(text: "播放失败，请重新同步或导入原音频", severity: .warning))
        }
    }

    private func stopPlayback() {
        playback.stop()
    }

    private func seekPlayback(to progress: Double, for item: MeetingRecording) {
        guard playback.isPlaying(item.id), playback.duration > 0 else { return }
        playback.seek(to: progress)
    }

    private func playbackProgress(for item: MeetingRecording) -> Double {
        guard playback.isPlaying(item.id), playback.duration > 0 else { return 0 }
        return max(0, min(1, playback.elapsed / playback.duration))
    }

    private func playbackElapsedText(for item: MeetingRecording) -> String {
        guard playback.isPlaying(item.id) else { return "0:00" }
        return Self.formatPlaybackTime(playback.elapsed)
    }

    private func playbackDurationText(for item: MeetingRecording) -> String {
        let seconds = playback.isPlaying(item.id) && playback.duration > 0
            ? playback.duration
            : Double(item.durationMs) / 1000.0
        return MeetingRecording.formatPlaybackTime(seconds)
    }

    private static func formatPlaybackTime(_ seconds: TimeInterval) -> String {
        MeetingRecording.formatPlaybackTime(seconds)
    }

    private func runBulkGenerate() {
        guard !generatingAll else { return }
        guard backendConfigured else {
            showingSettings = true
            return
        }
        guard networkMonitor.canReachRemoteBackend else {
            showGenerationFeedback(CopyFeedback(text: networkWarningText ?? "网络不可用，请联网后重试", severity: .warning))
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        generatingAll = true
        Task {
            defer { generatingAll = false }
            let enqueued = await store.generatePendingNotes()
            if enqueued > 0 {
                showGenerationFeedback(CopyFeedback(text: "已加入 \(enqueued) 条转写队列", severity: .success))
            } else {
                showGenerationFeedback(CopyFeedback(text: "没有新的录音需要生成", severity: .warning))
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            && (watchPullClient.syncing || store.hasActiveGeneration)
    }

    static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement() ?? "A" })
    }

    private static func isTerminalBindStatus(_ status: String) -> Bool {
        switch status {
        case "已绑定手表", "绑定失败", "未发现手表", "手机蓝牙未就绪", "绑定凭证不可用":
            return true
        default:
            return false
        }
    }
}

struct RecordingRow: View {
    let item: MeetingRecording
    let titleText: String
    let sending: Bool
    let queued: Bool
    let deletingLocked: Bool
    let busy: Bool
    let queueBusy: Bool
    let backendReady: Bool
    let networkReady: Bool
    let playing: Bool
    let playbackProgress: Double
    let playbackElapsedText: String
    let playbackDurationText: String
    let onGenerate: () -> Void
    let onTogglePlayback: () -> Void
    let onSeekPlayback: (Double) -> Void
    let onOpenTranscript: () -> Void
    let onOpenNotes: () -> Void
    let onDeleteAudio: () -> Void
    let onDelete: () -> Void
    @State private var confirmingDelete = false
    @State private var scrubProgress: Double?
    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.snappy(duration: 0.2)) { swipeOffset = 0 }
                confirmingDelete = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: deletingLocked ? "lock" : "trash")
                    Text(deletingLocked ? "生成中" : "删除")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 76)
                .frame(maxHeight: .infinity)
                .background(deletingLocked ? Color.secondaryText : Color.red)
            }
            .buttonStyle(.plain)
            .disabled(deletingLocked)

            rowContent
                .background(Color.appBackground)
                .offset(x: swipeOffset)
                .contentShape(Rectangle())
                .simultaneousGesture(swipeGesture)
                .onTapGesture {
                    guard swipeOffset != 0 else { return }
                    withAnimation(.snappy(duration: 0.2)) { swipeOffset = 0 }
                }
        }
        .clipped()
        .accessibilityAction(named: Text(deletingLocked ? "生成中不可删除" : deleteMenuTitle)) {
            guard !deletingLocked else { return }
            confirmingDelete = true
        }
        .confirmationDialog(deleteDialogTitle,
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            if item.state == .sent && item.audioRetained {
                Button("只删除原音频", role: .destructive, action: onDeleteAudio)
            }
            Button(deleteDialogActionTitle, role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text(item.state == .sent && item.audioRetained
                 ? "可以只清理原音频并保留文字，或删除整条记录。删除后无法恢复。"
                 : deleteDialogMessage)
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.headline)
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(2)
                if let recordingMetaText {
                    Text(recordingMetaText)
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                }
            }

            if shouldShowProcessingStatus {
                processingStatus
            }

            if let recoveryText {
                RecordingRecoveryHint(text: recoveryText)
            }

            if playing {
                playbackControl
            }

            HStack(spacing: 8) {
                Button(action: onTogglePlayback) {
                    Label(playing ? "停止" : "播放",
                          systemImage: playing ? "stop.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: hasSecondaryAction ? .infinity : nil, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentBlue)
                .disabled(!item.audioRetained)
                .accessibilityLabel(playing ? "停止播放录音" : "播放录音")

                if shouldShowContentEntries {
                    Button(action: openGeneratedContent) {
                        HStack(spacing: 5) {
                            Text("查看内容")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentBlue)
                } else if shouldShowGenerateButton {
                    Button(action: onGenerate) {
                        HStack {
                            if sending {
                                ProgressView().controlSize(.small)
                            } else if queued {
                                Image(systemName: "clock.arrow.circlepath")
                            } else {
                                Image(systemName: "text.badge.checkmark")
                            }
                            Text(generateButtonTitle)
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentBlue)
                    .disabled(generateButtonDisabled)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                swipeOffset = min(0, max(-76, value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    swipeOffset = value.translation.width < -38 ? -76 : 0
                }
            }
    }

    private var deleteMenuTitle: String {
        hasGeneratedText ? "删除整条记录" : "删除本机录音"
    }

    private var deleteDialogTitle: String {
        hasGeneratedText ? "删除这条记录和纪要？" : "删除这条本机录音？"
    }

    private var deleteDialogActionTitle: String {
        hasGeneratedText ? "删除记录和纪要" : "删除录音"
    }

    private var deleteDialogMessage: String {
        if hasGeneratedText {
            return "这会删除腕记里的纪要文本和本机录音记录；不会删除后端已处理的数据。"
        }
        return "删除后无法在腕记里重试转写。"
    }

    private var generateButtonTitle: String {
        if sending { return item.backendStage == "notes_generating" ? "纪要中" : "转写中" }
        if queued { return "已排队" }
        if !item.audioRetained { return "原音频已移除" }
        if item.state == .sent { return "重新生成" }
        if !networkReady { return "离线" }
        if queueBusy { return "加入队列" }
        if item.state == .failed { return "重试" }
        return "生成转写"
    }

    private var generateButtonDisabled: Bool {
        sending || queued || busy || !item.audioRetained
    }

    private var shouldShowGenerateButton: Bool {
        backendReady && item.audioRetained
    }

    private var hasSecondaryAction: Bool {
        shouldShowContentEntries || shouldShowGenerateButton
    }

    private var recordingMetaText: String? {
        item.source == "watch" ? nil : "导入"
    }

    private var processingStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            if shouldShowStepPills {
                HStack(spacing: 8) {
                    RecordingStepPill(summary: transcriptStep)
                    RecordingStepPill(summary: notesStep)
                }
            }
            if let compactStatusText {
                Text(compactStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(compactStatusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var shouldShowProcessingStatus: Bool {
        shouldShowStepPills || compactStatusText != nil
    }

    private var shouldShowStepPills: Bool {
        if item.state == .local && !backendReady {
            return false
        }
        return !shouldShowContentEntries
    }

    private var compactStatusText: String? {
        if !item.audioRetained {
            return nil
        }
        if sending || queued {
            return compactActiveStatusText
        }
        if item.noteText == Self.missingNotesText {
            return "转写已保存，纪要可重试。"
        }
        if item.state == .failed {
            return compactFailureText
        }
        if item.state == .sent, transcriptComplete, notesComplete {
            return nil
        }
        if item.statusText.contains("文件缺失") || item.statusText.contains("封装损坏") {
            return item.statusText
        }
        return nil
    }

    private var compactActiveStatusText: String? {
        switch item.backendStage {
        case "uploading":
            return "上传中。"
        case "queued":
            return item.durationMs >= 8 * 60 * 1000 ? "长录音排队转写。" : "等待转写。"
        case "transcribing":
            return "转写中。"
        case "notes_generating":
            return "整理纪要。"
        default:
            if queued { return "排队中。" }
            return "处理中。"
        }
    }

    private var compactFailureText: String? {
        let text = item.statusText
            .replacingOccurrences(of: "生成失败：", with: "")
            .replacingOccurrences(of: "。可稍后重试", with: "")
            .replacingOccurrences(of: "录音已保留，", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "处理失败，可重试。"
        }
        if MeetingNotesAPI.isEmptyTranscriptMessage(text) {
            return "未识别出文字，可重试。"
        }
        if text.contains("上传中断") || text.contains("连接服务器失败") || text.contains("上传超时") {
            return "上传中断，可重试。"
        }
        if text.count > 32 {
            return "\(text.prefix(32))..."
        }
        return text.hasSuffix("。") ? text : "\(text)。"
    }

    private var compactStatusColor: Color {
        item.state == .failed ? .red : .secondaryText
    }

    private var playbackControl: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { scrubProgress ?? playbackProgress },
                set: { scrubProgress = max(0, min(1, $0)) }
            ), in: 0...1, onEditingChanged: { editing in
                guard !editing else { return }
                let target = scrubProgress ?? playbackProgress
                scrubProgress = nil
                onSeekPlayback(target)
            })
            .disabled(playbackDurationText == "0:00")
            HStack {
                Text(playbackElapsedText)
                Spacer()
                Text(playbackDurationText)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.secondaryText)
            .monospacedDigit()
        }
        .padding(.horizontal, 2)
    }

    private var recoveryText: String? {
        guard !item.audioRetained else { return nil }
        if item.state == .sent, hasGeneratedText {
            return "原音频已清理；纪要可继续查看和分享，不能重新生成。"
        }
        return "原音频不在手机上；请从手表重新上传，或导入原文件后再生成完整转写。"
    }

    private var hasGeneratedText: Bool {
        !item.noteText.isEmpty || !item.transcriptText.isEmpty || !item.transcriptSegments.isEmpty
    }

    private var transcriptComplete: Bool {
        !item.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !item.transcriptSegments.isEmpty
    }

    private var notesComplete: Bool {
        !meaningfulNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowContentEntries: Bool {
        transcriptComplete || notesComplete || item.noteText == Self.missingNotesText
    }

    private var contentEntryStatus: String {
        if transcriptComplete && notesComplete { return "转写与纪要" }
        if transcriptComplete { return "完整转写" }
        if notesComplete { return "纪要" }
        return "纪要待重试"
    }

    private var contentEntryColor: Color {
        item.noteText == Self.missingNotesText ? .orange : .green
    }

    private func openGeneratedContent() {
        if notesComplete {
            onOpenNotes()
        } else {
            onOpenTranscript()
        }
    }

    private var transcriptStep: RecordingStepSummary {
        if transcriptComplete {
            return RecordingStepSummary(title: "转写", value: "已完成", icon: "text.quote", color: .green)
        }
        if sending || item.backendStage == "transcribing" {
            return RecordingStepSummary(title: "转写", value: "处理中", icon: "waveform.badge.magnifyingglass", color: .accentBlue)
        }
        if queued {
            return RecordingStepSummary(title: "转写", value: "排队中", icon: "clock.arrow.circlepath", color: .orange)
        }
        if item.state == .failed {
            return RecordingStepSummary(title: "转写", value: "失败", icon: "exclamationmark.circle", color: .red)
        }
        return RecordingStepSummary(title: "转写", value: backendReady ? "待生成" : "未配置", icon: "text.badge.plus", color: backendReady ? .secondaryText : .orange)
    }

    private var notesStep: RecordingStepSummary {
        if notesComplete {
            return RecordingStepSummary(title: "纪要", value: "已完成", icon: "checkmark.seal", color: .green)
        }
        if item.noteText == Self.missingNotesText {
            return RecordingStepSummary(title: "纪要", value: "未返回", icon: "exclamationmark.triangle", color: .orange)
        }
        if item.backendStage == "notes_generating" {
            return RecordingStepSummary(title: "纪要", value: "处理中", icon: "doc.text.magnifyingglass", color: .accentBlue)
        }
        if sending || queued {
            return RecordingStepSummary(title: "纪要", value: transcriptComplete ? "待生成" : "等待转写", icon: "doc.text", color: .secondaryText)
        }
        if item.state == .failed {
            return RecordingStepSummary(title: "纪要", value: transcriptComplete ? "可重试" : "未生成", icon: "arrow.clockwise", color: .orange)
        }
        return RecordingStepSummary(title: "纪要", value: "待生成", icon: "doc.text", color: .secondaryText)
    }

    private var meaningfulNoteText: String {
        if item.noteText == Self.missingNotesText {
            return ""
        }
        return item.noteText
    }

    private static let missingNotesText = "服务器已完成转写，但没有返回纪要。"

    private var stateIcon: some View {
        let name: String
        let color: Color
        if queued {
            name = "clock.arrow.circlepath"
            color = .orange
        } else {
            switch item.state {
        case .local:
            name = item.source == "watch" ? "applewatch.radiowaves.left.and.right" : "doc.badge.plus"
            color = .accentBlue
        case .sending:
            name = "arrow.up.circle"
            color = .orange
        case .sent:
            name = "checkmark.seal"
            color = .green
        case .failed:
            name = "exclamationmark.circle"
            color = .red
            }
        }
        return Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
    }
}

struct RecordingRecoveryHint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("录音恢复提示：\(text)")
    }
}

struct RecordingStepSummary {
    let title: String
    let value: String
    let icon: String
    let color: Color
}

struct RecordingStepPill: View {
    let summary: RecordingStepSummary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: summary.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(summary.title)
                .font(.system(size: 11, weight: .semibold))
            Text(summary.value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(summary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(Color.primaryText)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(summary.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(summary.color.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ContentEntryButton: View {
    let title: String
    let status: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(status)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(status)")
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let totalRecordingCount: Int
    let completedAudioCount: Int
    let totalSizeText: String
    let dataActionsDisabled: Bool
    let onImportAudio: () -> Void
    let onClearCompletedAudio: () -> Void
    let onClearAll: () -> Void
    @AppStorage(AppSettings.serverURLKey) private var storedServerURL = AppSettings.defaultServerURL
    @State private var serverURL: String
    @State private var token: String
    @State private var confirmingDiscardSettings = false
    @State private var backendSaveError: String?
    @State private var backendLinkFeedback: CopyFeedback?
    @State private var backendConfigChanged = false
    @State private var backendSaving = false
    @State private var manualConfigExpanded = false
    @State private var confirmingClearCompletedAudio = false
    @State private var confirmingClearAll = false

    init(totalRecordingCount: Int = 0,
         completedAudioCount: Int = 0,
         totalSizeText: String = "0 KB",
         dataActionsDisabled: Bool = false,
         onImportAudio: @escaping () -> Void = {},
         onClearCompletedAudio: @escaping () -> Void = {},
         onClearAll: @escaping () -> Void = {}) {
        self.totalRecordingCount = totalRecordingCount
        self.completedAudioCount = completedAudioCount
        self.totalSizeText = totalSizeText
        self.dataActionsDisabled = dataActionsDisabled
        self.onImportAudio = onImportAudio
        self.onClearCompletedAudio = onClearCompletedAudio
        self.onClearAll = onClearAll
        _serverURL = State(initialValue: UserDefaults.standard.string(forKey: AppSettings.serverURLKey)
                           ?? AppSettings.defaultServerURL)
        _token = State(initialValue: KeychainStore.token() ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: backendStatus.isReady ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(backendStatus.isReady ? Color.green : Color.secondaryText)
                        Text(backendStatus.isReady ? "已开启" : "未开启")
                            .font(.body.weight(.semibold))
                    }

                    Button {
                        importBackendConfigurationFromPasteboard()
                    } label: {
                        Label("从剪贴板导入配置", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(settingsBusy)

                    if let backendSaveError {
                        Label(backendSaveError, systemImage: "xmark.octagon")
                            .foregroundStyle(Color.red)
                    } else if backendConfigChanged {
                        Label("后端配置已保存。回到首页后可生成待处理录音。",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(Color.green)
                    }
                    if let backendLinkFeedback {
                        CopyConfirmationRow(feedback: backendLinkFeedback)
                    }
                    DisclosureGroup(isExpanded: $manualConfigExpanded) {
                        TextField("服务地址", text: $serverURL, prompt: Text("https://api.example.com"))
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        SecureField("访问密钥", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            beginSaveBackendConfig()
                        } label: {
                            if backendSaving {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在保存后端配置")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            } else {
                                Label(backendSaveButtonTitle,
                                      systemImage: backendSaveButtonIcon)
                                    .frame(minHeight: 30)
                            }
                        }
                        .disabled(!backendCanSave || settingsBusy)
                    } label: {
                        Label("手动配置", systemImage: "slider.horizontal.3")
                    }

                    if backendStatus.isReady {
                        Button {
                            copyBackendConfigurationLink()
                        } label: {
                            Label("复制配置到其他设备", systemImage: "link")
                        }
                        .disabled(backendConfigurationURL == nil || settingsBusy)
                    }
                } header: {
                    Text("文字整理")
                } footer: {
                    if backendNeedsSave {
                        Text(backendDraftFooter)
                    } else if backendStatus.isReady {
                        Text("配置链接包含访问密钥，只发送给自己的设备。")
                    }
                }

                Section {
                    Button(action: onImportAudio) {
                        Label("导入音频", systemImage: "square.and.arrow.down")
                    }
                    .disabled(settingsHasUnsavedChanges || settingsBusy)
                    if totalRecordingCount > 0 {
                        LabeledContent("本机录音", value: "\(totalRecordingCount) 条")
                        LabeledContent("占用空间", value: totalSizeText)
                        if completedAudioCount > 0 {
                            Button {
                                confirmingClearCompletedAudio = true
                            } label: {
                                Label("清理已完成原音频", systemImage: "waveform.slash")
                            }
                            .disabled(dataActionsDisabled)
                        }
                        Button(role: .destructive) {
                            confirmingClearAll = true
                        } label: {
                            Label("清空全部录音", systemImage: "trash")
                        }
                        .disabled(dataActionsDisabled)
                    }
                } header: {
                    Text("数据管理")
                } footer: {
                    if totalRecordingCount > 0 {
                        Text("清理原音频会保留文字内容；清空全部会删除本机录音和已生成内容。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: serverURL) { _, _ in
                backendSaveError = nil
                backendLinkFeedback = nil
                if backendNeedsSave { backendConfigChanged = false }
            }
            .onChange(of: token) { _, _ in
                backendSaveError = nil
                backendLinkFeedback = nil
                if backendNeedsSave { backendConfigChanged = false }
            }
            .confirmationDialog("放弃未保存更改？",
                                isPresented: $confirmingDiscardSettings,
                                titleVisibility: .visible) {
                Button("放弃草稿并关闭", role: .destructive) {
                    dismiss()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("后端配置草稿还没有保存，关闭后会丢失。")
            }
            .confirmationDialog("清理已完成原始音频？",
                                isPresented: $confirmingClearCompletedAudio,
                                titleVisibility: .visible) {
                Button("清理 \(completedAudioCount) 条原音频", role: .destructive, action: onClearCompletedAudio)
                Button("取消", role: .cancel) {}
            } message: {
                Text("纪要和转写会保留；清理后不能重新生成这些内容。")
            }
            .confirmationDialog("清空全部本机录音？",
                                isPresented: $confirmingClearAll,
                                titleVisibility: .visible) {
                Button("清空 \(totalRecordingCount) 条录音", role: .destructive, action: onClearAll)
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除腕记里保存的录音和已生成内容，且无法恢复。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { finishSettings() }
                        .disabled(settingsBusy)
                }
            }
        }
        .interactiveDismissDisabled(settingsHasUnsavedChanges || settingsBusy)
    }

    private var backendStatus: MeetingNotesAPI.BackendStatus {
        MeetingNotesAPI.backendStatus(serverURL: serverURL, token: token)
    }

    private var backendNeedsSave: Bool {
        let savedServerURL = storedServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedToken = (KeychainStore.token() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return serverURL.trimmingCharacters(in: .whitespacesAndNewlines) != savedServerURL
            || token.trimmingCharacters(in: .whitespacesAndNewlines) != savedToken
    }

    private var backendCanSave: Bool {
        guard backendNeedsSave else { return false }
        switch backendStatus {
        case .ready, .missingServer, .missingToken:
            return true
        case .invalidURL, .insecureURL:
            return false
        }
    }

    private var backendSaveButtonTitle: String {
        if !backendNeedsSave { return "已保存" }
        return backendCanSave ? "保存连接设置" : "修正地址后保存"
    }

    private var backendSaveButtonIcon: String {
        if !backendNeedsSave { return "checkmark" }
        return backendCanSave ? "key" : "exclamationmark.triangle"
    }

    private var backendDraftFooter: String {
        if backendCanSave {
            return "当前状态按未保存草稿计算。保存后才会用于首页自动生成。"
        }
        return "当前地址格式不能保存。请使用 https:// 开头的地址；本机调试可用 localhost。"
    }

    private var backendConfigurationURL: URL? {
        BackendConfigurationLink.make(serverURL: serverURL, token: token)
    }

    private var settingsHasUnsavedChanges: Bool {
        backendNeedsSave
    }

    private var settingsBusy: Bool {
        backendSaving
    }

    private func beginSaveBackendConfig() {
        guard backendCanSave, !settingsBusy else { return }
        backendSaving = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            commitBackendConfig()
            backendSaving = false
        }
    }

    private func copyBackendConfigurationLink() {
        guard let url = backendConfigurationURL else {
            let feedback = CopyFeedback(text: "请先保存可用的后端配置", severity: .warning)
            backendLinkFeedback = feedback
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        UIPasteboard.general.string = url.absoluteString
        let feedback = CopyFeedback(text: "配置链接已复制", severity: .success)
        backendLinkFeedback = feedback
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.backendLinkFeedback == feedback {
                self.backendLinkFeedback = nil
            }
        }
    }

    private func importBackendConfigurationFromPasteboard() {
        guard let raw = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            showBackendLinkFeedback(CopyFeedback(text: "剪贴板没有配置链接", severity: .warning))
            return
        }

        let result = BackendConfigurationLink.apply(raw)
        switch result {
        case .applied(let server):
            serverURL = server
            storedServerURL = server
            token = KeychainStore.token() ?? token
            backendSaveError = nil
            backendConfigChanged = true
            showBackendLinkFeedback(result.feedback ?? CopyFeedback(text: "后端配置已保存", severity: .success))
        case .ignored:
            showBackendLinkFeedback(CopyFeedback(text: "剪贴板没有腕记配置链接", severity: .warning))
        case .invalid, .keychainFailed:
            showBackendLinkFeedback(result.feedback ?? CopyFeedback(text: "配置链接不可用", severity: .warning))
        }
    }

    private func showBackendLinkFeedback(_ feedback: CopyFeedback) {
        backendLinkFeedback = feedback
        let feedbackType: UINotificationFeedbackGenerator.FeedbackType =
            feedback.severity == .success ? .success : .warning
        UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.backendLinkFeedback == feedback {
                self.backendLinkFeedback = nil
            }
        }
    }

    private func commitBackendConfig() {
        guard backendCanSave || backendSaving else { return }
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        backendSaveError = nil
        let savedToken: Bool
        if trimmed.isEmpty {
            savedToken = KeychainStore.clearToken()
        } else {
            savedToken = KeychainStore.setToken(trimmed)
        }
        guard savedToken else {
            backendSaveError = "API Token 保存失败，请解锁设备后重试"
            return
        }

        storedServerURL = trimmedServer
        serverURL = trimmedServer
        token = trimmed
        backendConfigChanged = true
    }

    private func finishSettings() {
        if settingsHasUnsavedChanges {
            confirmingDiscardSettings = true
        } else {
            dismiss()
        }
    }
}

struct MissingRecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                Text("这条记录已不在列表中")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

struct RecordingDetailView: View {
    let item: MeetingRecording
    let kind: RecordingDetailKind
    let playing: Bool
    let playbackElapsed: TimeInterval
    let playbackDurationText: String
    let regenerating: Bool
    let canRegenerate: Bool
    let onPlaySegment: (TimeInterval) -> Void
    let onSwitchKind: (RecordingDetailKind) -> Void
    let onRegenerate: () -> Void
    @State private var copyFeedback: CopyFeedback?
    @State private var selectedSegmentID: UUID?
    @State private var confirmingRegeneration = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(.system(size: 20, weight: .bold))
                        if let detailDisplayName {
                            Text(detailDisplayName)
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryText)
                        }
                    }

                    Picker("内容类型", selection: Binding(
                        get: { kind },
                        set: { onSwitchKind($0) }
                    )) {
                        Text("转写").tag(RecordingDetailKind.transcript)
                        Text("纪要").tag(RecordingDetailKind.notes)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("切换转写和纪要")

                    if kind == .notes && item.audioRetained && (item.state == .sent || regenerating) {
                        Button {
                            confirmingRegeneration = true
                        } label: {
                            HStack(spacing: 7) {
                                if regenerating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(regenerating ? "正在重新生成" : "重新生成纪要")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentBlue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(regenerating || !canRegenerate)
                        .accessibilityLabel(regenerating ? "正在重新生成纪要" : "重新生成纪要")
                    }

                    if let copyFeedback {
                        CopyConfirmationRow(feedback: copyFeedback)
                    }

                    switch kind {
                    case .transcript:
                        DetailPlaybackHeader(playing: playing,
                                             canPlayAudio: item.audioRetained,
                                             elapsedText: MeetingRecording.formatPlaybackTime(playbackElapsed),
                                             durationText: playbackDurationText,
                                             currentSegmentText: currentSegment?.text)
                        if shouldShowTranscriptContext {
                            NoteContextBanner(context: transcriptContext)
                        }
                        TranscriptDetailSection(text: displayTranscriptText,
                                                segments: item.transcriptSegments,
                                                canPlayAudio: item.audioRetained,
                                                playing: playing,
                                                playbackElapsed: playbackElapsed,
                                                selectedSegmentID: selectedSegmentID) { segment in
                            selectedSegmentID = segment.id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onPlaySegment(segment.startSeconds)
                        }
                    case .notes:
                        if shouldShowNoteContext {
                            NoteContextBanner(context: noteContext)
                        }
                        MarkdownNoteSection(markdown: meaningfulNoteText)
                    }
                }
                .padding(18)
            }
            .background(Color.appBackground)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("重新生成这份纪要？",
                                isPresented: $confirmingRegeneration,
                                titleVisibility: .visible) {
                Button("重新生成") { onRegenerate() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会使用保留的原始录音重新转写并生成纪要。成功后替换当前内容；失败时保留当前纪要和原音频。")
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        copyCurrentPage()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(pageText.isEmpty)
                    .accessibilityLabel(kind.copyLabel)

                    ShareLink(item: pageText,
                              subject: Text(item.originalName)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(pageText.isEmpty)
                    .accessibilityLabel(kind.shareLabel)
                }
            }
        }
    }

    private func copyCurrentPage() {
        guard !pageText.isEmpty else { return }
        UIPasteboard.general.string = pageText
        let feedback = CopyFeedback(text: "内容已复制", severity: .success)
        copyFeedback = feedback
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if self.copyFeedback == feedback {
                self.copyFeedback = nil
            }
        }
    }

    private var pageText: String {
        switch kind {
        case .transcript:
            return displayTranscriptText
        case .notes:
            return meaningfulNoteText
        }
    }

    private var meaningfulNoteText: String {
        if item.noteText == "服务器已完成转写，但没有返回纪要。" {
            return ""
        }
        return item.noteText
    }

    private var detailDisplayName: String? {
        let name = URL(fileURLWithPath: item.originalName)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let lowered = name.lowercased()
        let genericPrefix = lowered.hasPrefix("recording_")
            || lowered.hasPrefix("watch_recording_")
            || lowered.hasPrefix("audio_")
        let identifierOnly = name.allSatisfy { character in
            character.isNumber || character == "-" || character == "_"
        }
        guard !genericPrefix, !identifierOnly, UUID(uuidString: name) == nil else { return nil }
        return name
    }

    private var displayTranscriptText: String {
        if !item.transcriptText.isEmpty {
            return item.transcriptText
        }
        return item.transcriptSegments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var currentSegment: TranscriptSegment? {
        guard playing else { return nil }
        return item.transcriptSegments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.startMs == $1.startMs {
                    return $0.endMs < $1.endMs
                }
                return $0.startMs < $1.startMs
            }
            .first { segment in
                let start = segment.startSeconds
                let end = max(start + 0.5, TimeInterval(segment.endMs) / 1000.0)
                return playbackElapsed >= start && playbackElapsed < end
            }
    }

    private var transcriptReady: Bool {
        !displayTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowTranscriptContext: Bool {
        !transcriptReady || item.transcriptSegments.isEmpty || !item.audioRetained
            || item.backendStage == "transcribing" || item.state == .sending || item.state == .failed
    }

    private var shouldShowNoteContext: Bool {
        meaningfulNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var transcriptContext: NoteContext {
        if transcriptReady, item.transcriptSegments.isEmpty {
            return NoteContext(title: "完整转写已保存",
                               message: "服务端返回了完整文字，但没有逐句时间轴；可以复制分享，暂时不能按句跳到录音。",
                               icon: "text.quote",
                               color: .green)
        }
        if transcriptReady {
            return NoteContext(title: item.audioRetained ? "可逐句核对" : "只能查看文字",
                               message: item.audioRetained ? "点击任一句转写，会立即跳到对应录音位置并高亮当前句。" : "原音频已清理，完整转写仍可查看和分享。",
                               icon: item.audioRetained ? "text.line.first.and.arrowtriangle.forward" : "waveform.slash",
                               color: item.audioRetained ? .accentBlue : .orange)
        }
        if item.backendStage == "transcribing" || item.state == .sending {
            return NoteContext(title: "完整转写生成中",
                               message: "长录音会先完成完整转写，再进入纪要阶段；完成前不要重复点击生成。",
                               icon: "waveform.badge.magnifyingglass",
                               color: .accentBlue)
        }
        if item.state == .failed {
            return NoteContext(title: "完整转写失败",
                               message: item.statusText.isEmpty ? "可回到列表重试生成完整转写。" : item.statusText,
                               icon: "arrow.clockwise",
                               color: .orange)
        }
        return NoteContext(title: "等待完整转写",
                           message: "先生成完整转写；它是纪要和逐句回听的依据。",
                           icon: "text.badge.plus",
                           color: .secondaryText)
    }

    private var noteContext: NoteContext {
        let transcriptReady = !displayTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if item.noteText == "服务器已完成转写，但没有返回纪要。" {
            return NoteContext(title: "纪要未返回",
                               message: "完整转写已保存；服务端没有返回 Markdown 纪要，可以回到列表重试纪要生成。",
                               icon: "exclamationmark.triangle",
                               color: .orange)
        }
        if item.backendStage == "notes_generating" || (item.state == .sending && transcriptReady) {
            return NoteContext(title: "纪要生成中",
                               message: "完整转写已进入纪要阶段，完成后这里会显示服务端返回的 Markdown 纪要。",
                               icon: "doc.text.magnifyingglass",
                               color: .accentBlue)
        }
        if !transcriptReady {
            return NoteContext(title: "等待完整转写",
                               message: "纪要必须先有完整转写作为依据；生成完成后再展示结构化 Markdown。",
                               icon: "text.badge.plus",
                               color: .orange)
        }
        if item.state == .failed {
            return NoteContext(title: "纪要生成失败",
                               message: item.statusText.isEmpty ? "完整转写仍可查看；回到列表可以重试纪要生成。" : item.statusText,
                               icon: "arrow.clockwise",
                               color: .orange)
        }
        return NoteContext(title: "纪要待生成",
                           message: "完整转写已可用；回到列表可生成或重新生成 Markdown 纪要。",
                           icon: "doc.text",
                           color: .accentBlue)
    }
}

private struct NoteContext {
    let title: String
    let message: String
    let icon: String
    let color: Color
}

private struct NoteContextBanner: View {
    let context: NoteContext

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: context.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(context.color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primaryText)
                Text(context.message)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

struct TranscriptDetailSection: View {
    let text: String
    let segments: [TranscriptSegment]
    let canPlayAudio: Bool
    let playing: Bool
    let playbackElapsed: TimeInterval
    let selectedSegmentID: UUID?
    let onPlaySegment: (TranscriptSegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let visibleSegments = sortedVisibleSegments
            if visibleSegments.isEmpty {
                if !text.isEmpty {
                    Text("没有逐句时间轴，不能跳到对应录音位置。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(text.isEmpty ? "暂无内容" : text)
                    .font(.system(size: 16))
                    .foregroundStyle(text.isEmpty ? Color.secondaryText : Color.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if !canPlayAudio {
                    Text("原音频已移除，只能查看文字，不能逐句播放。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleSegments) { segment in
                        let active = isActive(segment)
                        if canPlayAudio {
                            Button {
                                onPlaySegment(segment)
                            } label: {
                                segmentRow(segment, active: active)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .accessibilityLabel("从 \(segment.timeText) 播放：\(segment.text)")
                        } else {
                            segmentRow(segment, active: active)
                                .padding(.vertical, 4)
                                .accessibilityLabel("\(segment.timeText)：\(segment.text)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment, active: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.timeText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.green : (canPlayAudio ? Color.accentBlue : Color.secondaryText))
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)
            Text(segment.text)
                .font(.system(size: 16, weight: active ? .semibold : .regular))
                .foregroundStyle(Color.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.green.opacity(0.12) : (selectedSegmentID == segment.id ? Color.accentBlue.opacity(0.10) : Color.clear))
        )
        .contentShape(Rectangle())
    }

    private func isActive(_ segment: TranscriptSegment) -> Bool {
        guard playing else { return false }
        let start = segment.startSeconds
        let end = max(start + 0.5, TimeInterval(segment.endMs) / 1000.0)
        return playbackElapsed >= start && playbackElapsed < end
    }

    private var sortedVisibleSegments: [TranscriptSegment] {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.startMs == $1.startMs {
                    return $0.endMs < $1.endMs
                }
                return $0.startMs < $1.startMs
            }
    }
}

struct DetailPlaybackHeader: View {
    let playing: Bool
    let canPlayAudio: Bool
    let elapsedText: String
    let durationText: String
    let currentSegmentText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    Text("\(elapsedText) / \(durationText)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                }
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if !canPlayAudio { return "只能查看文字" }
        return playing ? "正在播放" : "逐句播放"
    }

    private var message: String {
        if !canPlayAudio {
            return "原音频已清理，完整转写仍可查看，句级跳转不可用。"
        }
        if let currentSegmentText, playing {
            return "当前句：\(currentSegmentText)"
        }
        return "点击任一句转写，会立即跳到对应录音位置并高亮当前句。"
    }

    private var icon: String {
        if !canPlayAudio { return "waveform.slash" }
        return playing ? "speaker.wave.2.fill" : "text.line.first.and.arrowtriangle.forward"
    }

    private var color: Color {
        if !canPlayAudio { return .orange }
        return playing ? .green : .accentBlue
    }
}

struct DetailTextSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text(text.isEmpty ? "暂无内容" : text)
                .font(.system(size: 16))
                .foregroundStyle(text.isEmpty ? Color.secondaryText : Color.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MarkdownNoteSection: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("暂无内容")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(blocks) { block in
                        MarkdownBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(markdown)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case task(checked: Bool, text: String)
        case numbered(number: String, text: String)
        case quote(String)
        case table(headers: [String], rows: [[String]])
        case code(String)
        case divider
    }

    let id = UUID()
    let kind: Kind

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(MarkdownBlock(kind: .paragraph(text)))
            }
            paragraph.removeAll()
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(MarkdownBlock(kind: .code(codeLines.joined(separator: "\n"))))
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    inCodeBlock = true
                }
                index += 1
                continue
            }
            if inCodeBlock {
                codeLines.append(rawLine)
                index += 1
                continue
            }
            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if line == "---" || line == "***" {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .divider))
                index += 1
                continue
            }
            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
                index += 1
                continue
            }
            if let table = parseTable(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .table(headers: table.headers, rows: table.rows)))
                index = table.nextIndex
                continue
            }
            if let task = parseTask(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .task(checked: task.checked, text: task.text)))
                index += 1
                continue
            }
            if let bullet = parseBullet(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .bullet(bullet)))
                index += 1
                continue
            }
            if let numbered = parseNumbered(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .numbered(number: numbered.number, text: numbered.text)))
                index += 1
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                let quote = line.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .quote(String(quote))))
                index += 1
                continue
            }
            paragraph.append(line)
            index += 1
        }

        if inCodeBlock {
            blocks.append(MarkdownBlock(kind: .code(codeLines.joined(separator: "\n"))))
        }
        flushParagraph()
        return blocks
    }

    static func previewText(from markdown: String) -> String {
        let chunks = parse(markdown).compactMap { block -> String? in
            switch block.kind {
            case .heading(_, let text),
                 .paragraph(let text),
                 .bullet(let text),
                 .task(_, let text),
                 .numbered(_, let text),
                 .quote(let text):
                return text
            case .table(let headers, let rows):
                let firstRow = rows.first ?? []
                let cells = (headers + firstRow)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return cells.isEmpty ? nil : cells.joined(separator: "，")
            case .code, .divider:
                return nil
            }
        }
        return chunks
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 4, line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseTask(_ line: String) -> (checked: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let body = line.dropFirst(marker.count)
            guard body.count >= 4, body.first == "[" else { continue }
            let check = body[body.index(after: body.startIndex)]
            let close = body.index(body.startIndex, offsetBy: 2)
            let space = body.index(body.startIndex, offsetBy: 3)
            guard body[close] == "]", body[space] == " " else { continue }
            let normalizedCheck = String(check).lowercased()
            guard normalizedCheck == " " || normalizedCheck == "x" else { continue }
            let text = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (normalizedCheck == "x", text)
        }
        return nil
    }

    private static func parseNumbered(_ line: String) -> (number: String, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = String(line[..<dot])
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : (number, rest)
    }

    private static func parseTable(startingAt index: Int, lines: [String]) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard let headers = parseTableRow(headerLine),
              !headers.isEmpty,
              let separator = parseTableRow(separatorLine),
              isTableSeparator(separator) else {
            return nil
        }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count {
            let rowLine = lines[nextIndex].trimmingCharacters(in: .whitespaces)
            guard !rowLine.isEmpty,
                  let row = parseTableRow(rowLine),
                  !isTableSeparator(row) else {
                break
            }
            rows.append(normalizedTableRow(row, width: headers.count))
            nextIndex += 1
        }

        guard !rows.isEmpty else { return nil }
        return (headers, rows, nextIndex)
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let cells = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.contains { !$0.isEmpty } ? cells : nil
    }

    private static func isTableSeparator(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            let markers = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return markers.count >= 3 && markers.allSatisfy { $0 == "-" }
        }
    }

    private static func normalizedTableRow(_ row: [String], width: Int) -> [String] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            markdownText(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(Color.primaryText)
                .padding(.top, level == 1 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            markdownText(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.primaryText)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentBlue)
                    .frame(width: 14, alignment: .center)
                markdownText(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .task(let checked, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(checked ? Color.green : Color.secondaryText)
                    .frame(width: 18, alignment: .center)
                markdownText(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentBlue)
                    .frame(width: 26, alignment: .trailing)
                markdownText(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentBlue.opacity(0.55))
                    .frame(width: 3)
                markdownText(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownTableRow(cells: headers, emphasized: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        MarkdownTableRow(cells: row, emphasized: false)
                    }
                }
                .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondaryText.opacity(0.16), lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primaryText)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider()
                .padding(.vertical, 3)
        }
    }

    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text,
                                                  options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 18
        default: return 16
        }
    }
}

private struct MarkdownTableRow: View {
    let cells: [String]
    let emphasized: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                markdownText(cell.isEmpty ? " " : cell)
                    .font(.system(size: 13, weight: emphasized ? .bold : .regular))
                    .foregroundStyle(emphasized ? Color.primaryText : Color.secondaryText)
                    .lineSpacing(2)
                    .frame(width: 118, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 9)
                    .background(emphasized ? Color.white.opacity(0.58) : Color.clear)
                    .border(Color.secondaryText.opacity(0.10), width: 0.5)
            }
        }
    }

    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text,
                                                  options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

struct InfoPanel<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        AppCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    content
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct PairingCheck: Identifiable {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var id: String { title }
}

struct PairingReadinessView: View {
    let items: [PairingCheck]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.color)
                        .frame(width: 18, height: 18)
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                    Spacer(minLength: 8)
                    Text(item.value)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(item.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .frame(minHeight: 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct WatchSyncConsole: View {
    let event: ReceiverEvent
    let bound: Bool
    let syncing: Bool
    let preparing: Bool
    let guidance: String
    @Binding var detailsExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.cardBorder, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(event.severity == .info ? Color.secondaryText : Color.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if let progress = event.progress, event.severity == .receiving {
                ProgressView(value: progress)
                    .tint(color)
                    .accessibilityLabel("手表录音接收进度")
                    .accessibilityValue("\(Int((progress * 100).rounded(.down)))%")
            } else if syncing || preparing || event.severity == .processing {
                ProgressView()
                    .tint(color)
                    .accessibilityLabel("手表同步状态")
            }

            if showsGuidance {
                DisclosureGroup(isExpanded: $detailsExpanded) {
                    ReceiverGuidanceRow(text: guidance, color: color, icon: "lightbulb")
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12, weight: .semibold))
                        Text("查看处理建议")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(Color.secondaryText)
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    private var showsGuidance: Bool {
        !bound || preparing || syncing || event.severity == .warning || event.severity == .error
    }

    private var title: String {
        if !bound { return "先绑定手表" }
        if preparing { return "正在连接" }
        if syncing {
            if event.severity == .receiving { return "正在接收" }
            if event.message.contains("查找") { return "正在查找" }
            if event.message.contains("连接") { return "正在连接" }
            if event.message.contains("读取") { return "正在读取" }
            if event.message.contains("继续") { return "继续查找" }
            return "正在同步"
        }
        switch event.severity {
        case .success: return "已准备好"
        case .warning: return "暂时没连上"
        case .error: return "需要处理"
        case .receiving: return "正在接收"
        case .processing: return "正在处理"
        case .info: return "自动同步已开启"
        }
    }

    private var message: String {
        if !bound {
            return "绑定一次后，打开手机会自动同步。"
        }
        if preparing {
            return "正在找手表，保持两台设备靠近。"
        }
        if syncing {
            return event.message
        }
        switch event.severity {
        case .success:
            return "新录音会自动进入会议队列。"
        case .warning:
            return "手表可能没有打开腕记，系统会继续重试。"
        case .error:
            if event.message.contains("更新") { return "手表端版本需要更新后再同步。" }
            if event.message.contains("封装损坏") { return event.message }
            if event.message.contains("校验失败") { return event.message }
            return "没有读到录音队列。"
        case .receiving:
            return event.message
        case .processing:
            return "正在保存录音。"
        case .info:
            return "无需手动上传，保持腕记在手表端运行即可。"
        }
    }

    private var icon: String {
        if !bound { return "link.badge.plus" }
        if preparing || syncing { return "arrow.triangle.2.circlepath" }
        switch event.severity {
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .receiving: return "arrow.down.circle"
        case .processing: return "tray.and.arrow.down"
        case .info: return "applewatch.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        if !bound { return .orange }
        if preparing || syncing { return .accentBlue }
        switch event.severity {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .receiving: return .accentBlue
        case .processing: return .orange
        case .info: return Color.secondaryText
        }
    }
}

extension CopyFeedback {
    var icon: String {
        switch severity {
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch severity {
        case .success: return .green
        case .warning: return .orange
        }
    }
}

struct CopyConfirmationRow: View {
    let feedback: CopyFeedback

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: feedback.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(feedback.color)
                .frame(width: 18, height: 18)
            Text(feedback.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(feedback.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(feedback.text)
    }
}

struct NetworkStatusRow: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(text)
    }
}

struct ReceiverEventRow: View {
    let event: ReceiverEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if event.severity == .receiving {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(event.message)
                    .font(.system(size: 14, weight: event.severity == .error ? .semibold : .regular))
                    .foregroundStyle(event.severity == .info ? Color.secondaryText : Color.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if event.severity == .receiving, let progress = event.progress {
                    ProgressView(value: progress)
                        .tint(color)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("手表录音接收进度")
                        .accessibilityValue("\(Int((progress * 100).rounded(.down)))%")
                } else if event.severity == .processing {
                    ProgressView()
                        .tint(color)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("手表录音保存进度")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(color.opacity(event.severity == .info ? 0.06 : 0.12),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("最近接收事件：\(event.message)")
    }

    private var icon: String {
        switch event.severity {
        case .info: return "info.circle"
        case .receiving: return "arrow.down.circle"
        case .processing: return "tray.and.arrow.down"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch event.severity {
        case .info: return Color.secondaryText
        case .receiving: return Color.accentBlue
        case .processing: return Color.orange
        case .success: return Color.green
        case .warning: return Color.orange
        case .error: return Color.red
        }
    }
}

struct ReceiverGuidanceRow: View {
    let text: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("接收端恢复提示：\(text)")
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentBlue)
                Text(value)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DashboardMetric: View {
    let title: String
    let value: String
    var color: Color = .primaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}

struct MonoValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.primaryText)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(Color.panelMuted, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WanjiBrandMark: View {
    private let bars: [CGFloat] = [9, 16, 23, 28, 23, 16, 9]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primaryText)
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .padding(4)

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(Color.cardBackground)
                        .frame(width: 3, height: height)
                }
            }

            Capsule()
                .fill(Color.cardBackground.opacity(0.86))
                .frame(width: 18, height: 2)
                .offset(y: 16)
        }
    }
}

struct AppBackground: View {
    var body: some View {
        Color.appBackground.ignoresSafeArea()
    }
}

private extension View {
    @ViewBuilder
    func wanjiSearchable(enabled: Bool, text: Binding<String>) -> some View {
        if enabled {
            searchable(text: text, prompt: "搜索录音或内容")
        } else {
            self
        }
    }
}

extension Color {
    static let appBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.055, blue: 0.060, alpha: 1)
            : UIColor(red: 0.985, green: 0.978, blue: 0.962, alpha: 1)
    })
    static let cardBackground = Color(uiColor: .secondarySystemBackground)
    static let cardBorder = Color(uiColor: .separator)
    static let panelMuted = Color(uiColor: .secondarySystemBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let accentBlue = Color(uiColor: .systemBlue)
    static let brandInk = Color(red: 0.02, green: 0.09, blue: 0.08)
    static let brandDial = Color(red: 0.02, green: 0.24, blue: 0.20)
    static let brandGold = Color(red: 0.82, green: 0.66, blue: 0.43)
    static let brandIvory = Color(red: 0.96, green: 0.90, blue: 0.78)
    static let brandGlint = Color(red: 0.23, green: 0.79, blue: 0.97)
}
