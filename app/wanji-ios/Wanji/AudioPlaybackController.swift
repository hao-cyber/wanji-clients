import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var recordingID: UUID?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func isPlaying(_ id: UUID) -> Bool {
        recordingID == id
    }

    func play(url: URL, recordingID id: UUID, startAt seconds: TimeInterval? = nil) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        stop()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        recordingID = id
        elapsed = 0
        duration = 0

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }

        if let seconds, seconds.isFinite, seconds > 0 {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        } else {
            player.play()
        }
    }

    func stop() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        recordingID = nil
        elapsed = 0
        duration = 0
    }

    func seek(to progress: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(1, progress)) * duration
        elapsed = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func updateProgress() {
        guard let player else { return }
        let currentSeconds = player.currentTime().seconds
        if currentSeconds.isFinite, currentSeconds >= 0 {
            elapsed = currentSeconds
        }
        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = itemDuration
        }
    }
}
