#if os(macOS)
import AVFoundation
import Foundation

/// Captures mic audio locally with `AVAudioEngine`, watches the input level
/// for silence-based endpointing, and submits the captured WAV to OpenAI's
/// `/v1/audio/transcriptions` endpoint (Whisper). Returns the transcript.
///
/// Replaces `SFSpeechRecognizer` (which was triggering the macOS Speech
/// Recognition permission dialog on every fresh build) — the only Apple
/// system the listening path uses now is the microphone itself.
nonisolated public final class WhisperDictation: @unchecked Sendable {
    public enum DictationError: Error, Sendable {
        case missingAPIKey
        case audioEngineFailed(String)
        case whisperHTTP(Int, String)
        case whisperDecodeFailed
    }

    public init() {}

    public func transcribeOnce(
        silenceTimeout: TimeInterval = 1.2,
        totalTimeout: TimeInterval = 30,
        onPartialLevel: @escaping (Float) -> Void = { _ in }
    ) async throws -> String? {
        VoiceDiagnosticLog.log("whisper: start")

        guard let apiKey = Self.resolveAPIKey() else {
            VoiceDiagnosticLog.log("whisper ERROR: no OPENAI_API_KEY in environment")
            throw DictationError.missingAPIKey
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetalker-utterance-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: outputURL)

        // We write whatever format the input gives us — Whisper accepts WAV
        // at common sample rates; `AVAudioFile` defaults to a wav container
        // when the URL ends in `.wav`.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        } catch {
            VoiceDiagnosticLog.log("whisper ERROR: AVAudioFile init failed \(error)")
            throw DictationError.audioEngineFailed(String(describing: error))
        }

        final class State: @unchecked Sendable {
            let lock = NSLock()
            var lastVoiceAt = Date()
            var heardVoice = false
        }
        let state = State()
        let writerQueue = DispatchQueue(label: "codetalker.whisper.writer")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            writerQueue.async {
                try? audioFile.write(from: buffer)
            }
            // RMS level on first channel for cheap silence detection.
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            if frames == 0 { return }
            var sum: Float = 0
            for i in 0..<frames {
                let s = channelData[i]
                sum += s * s
            }
            let rms = (sum / Float(frames)).squareRoot()
            onPartialLevel(rms)
            if rms > 0.012 {
                state.lock.lock()
                state.heardVoice = true
                state.lastVoiceAt = Date()
                state.lock.unlock()
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            VoiceDiagnosticLog.log("whisper ERROR: engine start failed \(error)")
            throw DictationError.audioEngineFailed(String(describing: error))
        }

        let started = Date()
        var endReason = "?"
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            if Date().timeIntervalSince(started) > totalTimeout {
                endReason = "total-timeout"
                break
            }
            state.lock.lock()
            let heard = state.heardVoice
            let lastAt = state.lastVoiceAt
            state.lock.unlock()
            if heard, Date().timeIntervalSince(lastAt) > silenceTimeout {
                endReason = "silence"
                break
            }
        }
        if Task.isCancelled { endReason = "cancelled" }

        engine.stop()
        input.removeTap(onBus: 0)
        // Let the writer queue flush before we read the file.
        writerQueue.sync {}

        state.lock.lock()
        let heard = state.heardVoice
        state.lock.unlock()
        guard heard else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        // POST the captured WAV to Whisper.
        let transcript: String
        do {
            transcript = try await Self.callWhisper(fileURL: outputURL, apiKey: apiKey)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        try? FileManager.default.removeItem(at: outputURL)

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceDiagnosticLog.log("whisper: returning transcript=\"\(trimmed)\" (\(endReason))")
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODETALKER_REALTIME_EPHEMERAL_KEY", "OPENAI_REALTIME_EPHEMERAL_KEY"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func callWhisper(fileURL: URL, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "----CodeTalkerBoundary\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("model", "whisper-1")
        addField("response_format", "json")
        addField("language", "en")

        // File field
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DictationError.whisperDecodeFailed
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            VoiceDiagnosticLog.log("whisper ERROR: HTTP \(http.statusCode) body=\(body.prefix(400))")
            throw DictationError.whisperHTTP(http.statusCode, body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw DictationError.whisperDecodeFailed
        }
        return text
    }
}
#endif
