import Foundation

@main
struct HomeCognitiveLoadSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains(#".navigationTitle("腕记")"#) &&
                     !content.contains("private var hero: some View") &&
                     !content.contains("WanjiBrandMark()"),
                     "Home should use a compact navigation title instead of a promotional hero")
        precondition(content.contains(#"Circle()"#) && content.contains(".fill(watchPanelColor)"),
                     "Watch status should be reduced to a lightweight status dot")
        precondition(content.contains("private var watchPrimaryAction: some View"),
                     "Watch card should keep one compact action")
        precondition(content.contains("private var shouldShowReceiverPanel: Bool") &&
                     content.contains("!watchBindingConfirmed") &&
                     content.contains("if shouldShowReceiverPanel {") &&
                     content.contains("|| watchStatusError"),
                     "Healthy idle watch status should disappear while first connection and actionable states remain")
        precondition(content.contains(".refreshable {") &&
                     content.contains("requestWatchSyncNow()") &&
                     content.contains(#"Text("允许同步")"#),
                     "Routine sync should use pull-to-refresh while first-time authorization remains explicit")
        let watchCardStart = content.range(of: "private var receiverPanel: some View")!.lowerBound
        let watchCardEnd = content.range(of: "@ViewBuilder\n    private var watchPrimaryAction")!.lowerBound
        let watchCardRange = watchCardStart..<watchCardEnd
        precondition(!content[watchCardRange].contains(#"Menu {"#),
                     "Watch card should not expose competing diagnostic/rebind menu on the home surface")
        precondition(content.contains(#"Label("导入音频", systemImage: "square.and.arrow.down")"#) &&
                     content.contains(#"Text("数据管理")"#) &&
                     content.contains(#"Label("清空全部录音", systemImage: "trash")"#),
                     "Import and bulk deletion should live together in settings data management")
        precondition(content.contains(#"Text("还没有录音")"#),
                     "Empty state should be a simple result container")
        precondition(content.contains(#"Text("同步完成后会出现在这里。")"#),
                     "Empty state should explain where recordings appear without repeating watch discovery copy")
        precondition(content.contains("private var watchSummaryRow: some View"),
                     "Compact home should retain one quiet watch status row")
        precondition(!content.contains(#"if !backendConfigured && store.generateableCount > 0"#),
                     "Backend setup should not occupy the top home surface by default")
        precondition(!content.contains("if shouldShowStorageNotice {"),
                     "Routine storage reassurance should not occupy the home surface")
        precondition(content.contains(#"Text("\(store.generateableCount) 条待生成")"#) &&
                     content.contains(#""准备好后生成纪要""#),
                     "Bulk generation surface should be compact and chunked")
        precondition(content.contains("if backendConfigured {\n                            queueActionPanel") &&
                     content.contains("} else {\n                            backendSetupPanel") &&
                     content.contains(#"Text("开启文字整理")"#),
                     "Backend setup should appear once at queue level when generation is unavailable")
        precondition(content.contains("ForEach(recordingDayGroups)") &&
                     content.contains("recordingTimeText(for: item)") &&
                     content.contains(#"if calendar.isDateInToday(date) { return "今天" }"#) &&
                     content.contains(#"if calendar.isDateInYesterday(date) { return "昨天" }"#),
                     "Recordings should scan by day with compact time and duration rows")
        precondition(!content.contains(#"return "去设置""#) &&
                     !content.contains(#"return "设置""#) &&
                     content.contains("backendReady && item.audioRetained"),
                     "Recording rows should not repeat the global backend setup action")
        precondition(!content.contains(#"Label("更多", systemImage: "ellipsis")"#) &&
                     content.contains("private var swipeGesture: some Gesture") &&
                     content.contains(#"Text(deletingLocked ? "生成中" : "删除")"#),
                     "Recording deletion should use a labeled swipe action without an overflow menu")
        precondition(content.contains("wanjiSearchable(enabled: store.items.count >= 5"),
                     "Search should appear only after the recording list becomes large enough")
        precondition(!content.contains(#"StatusPill(label:"#),
                     "Home should not reintroduce competing status pills")
        precondition(!content.contains("queueStatusText") &&
                     !content.contains("queueStatusIcon") &&
                     !content.contains("queueStatusColor"),
                     "Queue status should not add another visible decision layer on the home header")
        precondition(!content.contains("录音自动到手机") &&
                     !content.contains("等待手表录音") &&
                     !content.contains("立即同步") &&
                     !content.contains("保持手表端腕记打开，手机会自动再查。") &&
                     !content.contains("打开手机后会自动查找手表。") &&
                     !content.contains(#"return "自动再查""#) &&
                     !content.contains(#"return "手表打开后会继续找。""#),
                     "Old verbose home copy should stay removed")

        print("home_cognitive_load_smoke passed")
    }
}
