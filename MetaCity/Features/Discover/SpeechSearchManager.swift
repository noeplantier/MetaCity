import AVFoundation
import Speech
import SwiftUI

/// Thin wrapper around `SFSpeechRecognizer` for one-shot voice search input.
/// Writes recognized text back through a binding. The caller toggles `isListening`
/// via `DiscoverViewModel.isListening` — this manager starts / stops the session
/// in response to that value via `onChange` in the containing view.
@MainActor
final class SpeechSearchManager: ObservableObject {

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Requests permission and starts listening. Writes incremental results to `text`.
    /// Calls `onFinished` when the user stops speaking (automatic silence detection).
    func startListening(text: Binding<String>, onFinished: @escaping () -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { self?.beginSession(text: text, onFinished: onFinished) }
        }
    }

    private func beginSession(text: Binding<String>, onFinished: @escaping () -> Void) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return }

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }
        request.shouldReportPartialResults = true

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            try audioEngine.start()
        } catch {
            stopListening()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                DispatchQueue.main.async { text.wrappedValue = result.bestTranscription.formattedString }
                if result.isFinal { DispatchQueue.main.async { self?.stopListening(); onFinished() } }
            }
            if error != nil { DispatchQueue.main.async { self?.stopListening() } }
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
