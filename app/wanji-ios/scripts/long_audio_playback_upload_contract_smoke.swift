import Foundation

@main
struct LongAudioPlaybackUploadContractSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let playback = try String(contentsOf: root.appendingPathComponent("Wanji/AudioPlaybackController.swift"),
                                  encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)
        let api = try String(contentsOf: root.appendingPathComponent("Wanji/MeetingNotesAPI.swift"),
                             encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Wanji/RecordingStore.swift"),
                               encoding: .utf8)
        let info = try String(contentsOf: root.appendingPathComponent("Info.plist"),
                              encoding: .utf8)

        precondition(playback.contains("final class AudioPlaybackController"),
                     "Long playback should live in a focused controller")
        precondition(playback.contains("AVPlayerItem(url: url)") &&
                     playback.contains("addPeriodicTimeObserver"),
                     "Long audio playback should use AVPlayer with a time observer")
        precondition(!content.contains("AVAudioPlayer(contentsOf:"),
                     "ContentView should not use AVAudioPlayer for retained long recordings")
        precondition(api.contains("uploadForMeetingNotes(fileURL: URL") &&
                     api.contains("URLSession.shared.upload(for: request, fromFile: fileURL)"),
                     "Production meeting-note upload should stream from file URL")
        precondition(api.contains("JobProgress(jobId: \"\", status: \"uploading\", stage: \"uploading\")") &&
                     api.contains("performUploadWithTimeout") &&
                     api.contains("uploadAcceptTimeoutNanoseconds") &&
                     api.contains("uploadTransportError") &&
                     api.contains("上传中断，录音已保留，可重试"),
                     "Long upload should expose an immediate uploading state and map disconnects to retryable retained-audio failures")
        precondition(store.contains("MeetingNotesAPI.uploadForMeetingNotes(fileURL: fileURL"),
                     "RecordingStore default generation path should use file-backed upload")
        precondition(store.contains("items[index].backendJobId = nil") &&
                     store.contains("items[index].backendStage = \"uploading\"") &&
                     store.contains("正在上传保留录音到后端"),
                     "Retrying retained audio should clear stale backend jobs and show upload progress immediately")
        precondition(store.contains("$0.autoProcess") &&
                     store.contains("$0.durationMs >= 8 * 60 * 1000"),
                     "Auto recovery should reupload retained long recordings even before a fresh backend job exists")
        precondition(info.contains("<string>audio</string>") &&
                     info.contains("<string>bluetooth-central</string>"),
                     "iOS app should declare audio and Bluetooth background modes")

        print("long_audio_playback_upload_contract_smoke passed")
    }
}
