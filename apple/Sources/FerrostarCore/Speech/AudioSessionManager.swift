import AVFoundation

/// The request/release operations must check cancellation before mutating focus.
/// The production actor performs each check and AVAudioSession mutation without
/// a suspension point, so a cancelled queued operation cannot affect new speech.
protocol AudioSessionManaging: Sendable {
    func requestAudioFocus() async
    func releaseAudioFocus() async
}

/// Manages the `AVAudioSession` for the app,
/// allowing the ``SpokenInstructionObserver`` to request
/// "focus." This will duck audio from most other apps (e.g. Music),
/// and interrupt speech for apps playing back spoken audio (e.g. Podcasts).
///
/// Automatically releases focus on deinit.
actor AudioSessionManager: AudioSessionManaging {
    private var hasAudioFocus = false
    private let audioSession = AVAudioSession.sharedInstance()

    /// Requests audio focus, ducking others and interrupting spoken audio.
    func requestAudioFocus() {
        guard !Task.isCancelled, !hasAudioFocus else { return }

        do {
            try audioSession.setCategory(.playback, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try audioSession.setMode(.voicePrompt)
            try audioSession.setActive(true)
            hasAudioFocus = true
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    /// Releases audio focus by deactivating the audio session and notifies other apps.
    ///
    /// This will resume playback from spoken word apps, and "un-duck" audio from other apps.
    func releaseAudioFocus() {
        guard !Task.isCancelled, hasAudioFocus else { return }

        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            hasAudioFocus = false
        } catch {
            print("Failed to release audio session: \(error)")
        }
    }

    deinit {
        if hasAudioFocus {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
