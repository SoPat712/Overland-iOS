import AVFoundation
import Observation

@Observable
@MainActor
final class SilentAudioSession {
    private(set) var status = "Off"
    private(set) var isPlaying = false

    @ObservationIgnored private lazy var worker = SilentAudioWorker { [weak self] status, isPlaying in
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status = status
            self.isPlaying = isPlaying
        }
    }

    func setEnabled(_ enabled: Bool) {
        worker.setEnabled(enabled)
    }

    func refresh() {
        worker.refresh()
    }

    func retry() {
        worker.retry()
    }
}

private final class SilentAudioWorker: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.overland.silent-audio")
    private let report: @Sendable (String, Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private var interrupted = false
    private var requiresReenable = false
    private var ownsAudioSession = false
    private var player: AVAudioPlayer?
    private var isPlaying = false

    init(report: @escaping @Sendable (String, Bool) -> Void) {
        self.report = report
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            self.queue.async { self.handleInterruption(value, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleMediaServicesReset() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setEnabled(_ value: Bool) {
        queue.async { self.applyEnabled(value) }
    }

    func refresh() {
        queue.async { self.refreshPlayback() }
    }

    func retry() {
        queue.async {
            guard self.enabled else { return }
            self.interrupted = false
            self.requiresReenable = false
            self.refreshPlayback()
        }
    }

    private func applyEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value {
            requiresReenable = false
            if interrupted {
                publish("Silent audio paused for an interruption", playing: false)
            } else {
                start()
            }
        } else {
            requiresReenable = false
            stopPlayback()
            publish("Off", playing: false)
        }
    }

    private func refreshPlayback() {
        guard enabled, !interrupted, !requiresReenable else { return }
        if player?.isPlaying == true { return }
        if isPlaying { stopPlayback() }
        start()
    }

    private func start() {
        guard enabled, !interrupted, !requiresReenable, !isPlaying else { return }
        do {
            let nextPlayer = try AVAudioPlayer(data: Self.silentWAV())
            nextPlayer.delegate = self
            nextPlayer.numberOfLoops = -1
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            ownsAudioSession = true
            guard nextPlayer.prepareToPlay() else {
                stopPlayback()
                publish("Silent audio could not be decoded.", playing: false)
                return
            }
            guard nextPlayer.play() else {
                stopPlayback()
                publish("Silent audio could not start.", playing: false)
                return
            }
            player = nextPlayer
            publish("Silent audio active", playing: true)
        } catch {
            stopPlayback()
            publish("Silent audio could not start: \(error.localizedDescription)", playing: false)
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handleInterruption(_ value: UInt, options: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        switch type {
        case .began:
            interrupted = true
            player?.stop()
            player = nil
            isPlaying = false
            if enabled { publish("Silent audio paused for an interruption", playing: false) }
        case .ended:
            interrupted = false
            guard enabled else { return }
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                start()
            } else {
                requiresReenable = true
                publish("Silent audio paused after an interruption", playing: false)
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        player?.stop()
        player = nil
        isPlaying = false
        ownsAudioSession = false
        refreshPlayback()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        let detail = error?.localizedDescription
        queue.async {
            guard self.player.map(ObjectIdentifier.init) == identity else { return }
            self.stopPlayback()
            self.publish(detail.map { "Silent audio stopped: \($0)" } ?? "Silent audio could not be decoded.", playing: false)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        queue.async {
            guard self.player.map(ObjectIdentifier.init) == identity else { return }
            self.stopPlayback()
            self.publish("Silent audio stopped unexpectedly.", playing: false)
        }
    }

    private func publish(_ value: String, playing: Bool) {
        isPlaying = playing
        report(value, isPlaying)
    }

    private static func silentWAV() -> Data {
        var data = Data(capacity: 16_044)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(16_036, bytes: 4, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(16, bytes: 4, to: &data)
        appendLittleEndian(1, bytes: 2, to: &data)
        appendLittleEndian(1, bytes: 2, to: &data)
        appendLittleEndian(8_000, bytes: 4, to: &data)
        appendLittleEndian(16_000, bytes: 4, to: &data)
        appendLittleEndian(2, bytes: 2, to: &data)
        appendLittleEndian(16, bytes: 2, to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(16_000, bytes: 4, to: &data)
        data.append(Data(count: 16_000))
        return data
    }

    private static func appendLittleEndian(_ value: UInt32, bytes: Int, to data: inout Data) {
        for offset in 0..<bytes {
            data.append(UInt8((value >> (offset * 8)) & 0xff))
        }
    }
}
