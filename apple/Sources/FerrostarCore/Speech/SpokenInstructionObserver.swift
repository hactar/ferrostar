import AVFoundation
import Combine
import FerrostarCoreFFI
import Foundation

/// An Spoken instruction provider that triggers speech synthesis in response to navigation events.
public class SpokenInstructionObserver {
    @Published public private(set) var isMuted: Bool

    let synthesizer: SpeechSynthesizer
    private let audioManager: any AudioSessionManaging
    // Synthesizers can call back synchronously into the observer. Serialize that
    // reentrancy without holding a lock across suspension points. Synthesizer
    // operations themselves run on the main actor; audio focus stays on its actor.
    private let speechLock = NSRecursiveLock()
    private var generation = UUID()
    private var pendingInstructions: [UUID: Task<Void, Never>] = [:]
    private var lastInstructionTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var audioFocusReleaseTask: Task<Void, Never>?

    /// Whether this observer should manage the app's shared `AVAudioSession` while speaking.
    ///
    /// Defaults to `true`, which preserves the existing behavior: audio focus is requested
    /// (ducking other apps) before speaking and released afterwards.
    ///
    /// Set this to `false` when the host app manages its own audio session. This matters for apps
    /// that inject a custom ``SpeechSynthesizer`` which plays audio through the app's own session:
    ///
    /// * `requestAudioFocus()` sets `.duckOthers` and `.interruptSpokenAudioAndMixWithOthers`
    ///   on the shared session and uses the `.voicePrompt` mode.
    /// * `releaseAudioFocus()` only clears `hasAudioFocus` **after** `setActive(false)` succeeds,
    ///   and `setActive(false)` fails while the session still has active audio I/O.
    ///
    /// An app that keeps a microphone tap open (e.g. for wake-word standby) or plays its own
    /// audio can therefore prevent focus from being released, so other apps stay ducked for the
    /// rest of the session. Recovering by re-applying `setCategory` is not a workable fix either:
    /// changing the category of an already-active session interrupts other apps' playback.
    ///
    /// When `true`, this observer automatically manages audio focus before speaking and releases
    /// it after each instruction. Setting it to `false` means the application manages the audio
    /// session lifecycle and focus itself.
    private let managesAudioSession: Bool

    /// Creates a spoken instruction observer with any ``SpeechSynthesizer``.
    ///
    /// - Parameters:
    ///   - synthesizer: The speech synthesizer.
    ///   - isMuted: Whether the speech synthesizer is currently muted. (Normally this will be false,
    ///     unless you're providing your own "hot" synth.)
    ///   - managesAudioSession: Whether this observer should manage the shared `AVAudioSession`
    ///     while speaking. Defaults to `true`. Set to `false` if the host app will manage the
    ///     audio session lifecycle and focus itself.
    public init(
        synthesizer: SpeechSynthesizer,
        isMuted: Bool,
        managesAudioSession: Bool = true
    ) {
        self.synthesizer = synthesizer
        self.isMuted = isMuted
        self.managesAudioSession = managesAudioSession
        audioManager = AudioSessionManager()
    }

    /// Keep audio-session timing controllable in library tests without adding a
    /// second public customization surface next to managesAudioSession.
    init(synthesizer: SpeechSynthesizer, isMuted: Bool, managesAudioSession: Bool,
         audioManager: any AudioSessionManaging)
    {
        self.synthesizer = synthesizer
        self.isMuted = isMuted
        self.managesAudioSession = managesAudioSession
        self.audioManager = audioManager
    }

    deinit {
        for task in pendingInstructions.values {
            task.cancel()
        }
        audioFocusReleaseTask?.cancel()
    }

    public func spokenInstructionTriggered(_ instruction: FerrostarCoreFFI.SpokenInstruction) {
        speechLock.withLock {
            guard !isMuted else { return }
            cancelAudioFocusRelease()
            let expectedGeneration = generation
            let id = UUID()
            let previousStop = stopTask
            let previousInstruction = lastInstructionTask
            let task = Task<Void, Never> { [weak self, audioManager, managesAudioSession] in
                defer { self?.removePendingInstruction(id: id) }
                // A prior stop must finish unducking before new speech can
                // acquire focus; delayed cleanup must not affect a new session.
                await previousStop?.value
                await previousInstruction?.value
                guard !Task.isCancelled, self?.prepareToSpeak(generation: expectedGeneration) == true else { return }
                if managesAudioSession {
                    await audioManager.requestAudioFocus()
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.speak(instruction, generation: expectedGeneration)
                }
            }
            pendingInstructions[id] = task
            lastInstructionTask = task
        }
    }

    private func prepareToSpeak(generation expectedGeneration: UUID) -> Bool {
        speechLock.withLock {
            guard generation == expectedGeneration, !isMuted else { return false }
            cancelAudioFocusRelease()
            return true
        }
    }

    private func removePendingInstruction(id: UUID) {
        speechLock.withLock { _ = pendingInstructions.removeValue(forKey: id) }
    }

    @MainActor
    private func speak(_ instruction: FerrostarCoreFFI.SpokenInstruction, generation expectedGeneration: UUID) {
        speechLock.withLock {
            guard !Task.isCancelled, generation == expectedGeneration, !isMuted else { return }
            let utterance: AVSpeechUtterance = if #available(iOS 16.0, *),
                                                  let ssml = instruction.ssml,
                                                  let ssmlUtterance = AVSpeechUtterance(ssmlRepresentation: ssml)
            {
                ssmlUtterance
            } else {
                AVSpeechUtterance(string: instruction.text)
            }
            synthesizer.speak(utterance)
            // A custom synth may synchronously call Stop/Mute from speak.
            if managesAudioSession, generation == expectedGeneration, !isMuted {
                scheduleAudioFocusRelease()
            }
        }
    }

    /// Toggle the mute.
    public func toggleMute() {
        speechLock.withLock {
            isMuted.toggle()
            if isMuted {
                stopAndClearQueue()
            }
        }
    }

    /// Immediately invalidates every instruction queued before this command,
    /// including one waiting for audio focus. Current synthesis is stopped on
    /// the main actor, before instructions from a newer session may speak.
    public func stopAndClearQueue() {
        speechLock.withLock {
            generation = UUID()
            for task in pendingInstructions.values {
                task.cancel()
            }
            pendingInstructions.removeAll()
            lastInstructionTask = nil
            cancelAudioFocusRelease()
            let previousStop = stopTask
            stopTask = Task { [audioManager, synthesizer, managesAudioSession] in
                await previousStop?.value
                await MainActor.run { _ = synthesizer.stopSpeaking(at: .immediate) }
                if managesAudioSession {
                    await audioManager.releaseAudioFocus()
                }
            }
        }
    }

    func scheduleAudioFocusRelease() {
        speechLock.withLock {
            cancelAudioFocusRelease()
            let expectedGeneration = generation
            audioFocusReleaseTask = Task { [weak self, audioManager] in
                // Keep the existing polling policy. Synthesizer delegate/queue
                // completion belongs to the separate audio-session proposal.
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 500 * NSEC_PER_MSEC) } catch { return }
                    let speaking = await MainActor.run { [weak self] in
                        self?.isSpeaking(generation: expectedGeneration)
                    }
                    guard let speaking else { return }
                    if !speaking {
                        break
                    }
                }
                guard !Task.isCancelled else { return }
                await audioManager.releaseAudioFocus()
            }
        }
    }

    @MainActor
    private func isSpeaking(generation expectedGeneration: UUID) -> Bool? {
        speechLock.withLock {
            guard !Task.isCancelled, generation == expectedGeneration, !isMuted else { return nil }
            return synthesizer.isSpeaking
        }
    }

    private func cancelAudioFocusRelease() {
        audioFocusReleaseTask?.cancel()
        audioFocusReleaseTask = nil
    }
}

public extension SpokenInstructionObserver {
    /// Create a new spoken instruction observer with AFFoundation's AVSpeechSynthesizer.
    ///
    /// - Parameters:
    ///    - synthesizer: An instance of AVSpeechSynthesizer. One is provided by default, but you can inject your own.
    ///    - isMuted: If the synthesizer is muted. This should be false unless you're providing a "hot" synth that is
    /// speaking.
    /// - Returns: The instance of SpokenInstructionObserver
    static func initAVSpeechSynthesizer(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
                                        isMuted: Bool = false) -> SpokenInstructionObserver
    {
        SpokenInstructionObserver(synthesizer: synthesizer, isMuted: isMuted)
    }
}
