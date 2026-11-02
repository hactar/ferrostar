import AVFoundation
import Foundation

/// An abstracted speech synthesizer that is used by the ``SpokenInstructionObserver``
///
/// Any functions that are needed for use in the ``SpokenInstructionObserver`` should be exposed through
/// this protocol.
/// The observer invokes these operations on the main actor. Implementations
/// should enqueue their audio work and return promptly, rather than blocking
/// for playback or a remote service. A host can still manage its own audio
/// session with `SpokenInstructionObserver`'s `managesAudioSession` option.
public protocol SpeechSynthesizer {
    // TODO: We could further abstract this to allow other speech synths.
    //       E.g. with a `struct SpeechUtterance` if and when another speech service comes along.

    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizer {
    // No def required
}

class PreviewSpeechSynthesizer: SpeechSynthesizer {
    var isSpeaking: Bool = false

    func speak(_: AVSpeechUtterance) {
        // No action for previews
    }

    func stopSpeaking(at _: AVSpeechBoundary) -> Bool {
        // No action for previews
        true
    }
}
