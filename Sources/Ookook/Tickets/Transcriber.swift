import Foundation
import AVFoundation
import WhisperKit

/// On-device transcription for WhatsApp voice notes and video audio.
///
/// DeepSeek cannot take audio (its Files API is images only), and Apple's
/// speech stack has no on-device Turkish: `SpeechTranscriber` ships 30 locales
/// without tr, and `SFSpeechRecognizer` reports
/// `supportsOnDeviceRecognition = false` for tr-TR - using it would ship the
/// customer's voice to Apple. So this runs Whisper locally through WhisperKit.
///
/// The model is downloaded once from Hugging Face, into Application Support.
@MainActor
final class Transcriber: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// The variants worth offering, with their one-time download size.
    static let models: [(id: String, label: String)] = [
        ("large-v3-v20240930_626MB", "Large v3 Turbo · 626 MB"),
        ("small", "Small · 480 MB"),
        ("tiny", "Tiny · 75 MB (weakest)"),
    ]
    static let defaultModel = "large-v3-v20240930_626MB"

    private static let modelKey = "ticketsWhisperModel"

    @Published private(set) var state: State = .idle

    private let engine = WhisperEngine()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var model: String {
        get { defaults.string(forKey: Self.modelKey) ?? Self.defaultModel }
        set {
            guard newValue != model else { return }
            defaults.set(newValue, forKey: Self.modelKey)
            state = .idle
            Task { await engine.unload() }
        }
    }

    /// Loads (and, on first use, downloads) the model ahead of the first voice
    /// note, so the settings pane can do it deliberately.
    func prepare() {
        guard state != .loading else { return }
        state = .loading
        let model = self.model
        Task {
            do {
                try await engine.load(model: model)
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Whether the model files are already on disk. The folder alone is not
    /// enough: an interrupted download leaves one behind, so a compiled model
    /// has to be inside.
    var isModelDownloaded: Bool {
        let items = try? FileManager.default.contentsOfDirectory(atPath: WhisperModels.folder(for: model).path)
        return items?.contains { $0.hasSuffix(".mlmodelc") } ?? false
    }

    /// Best effort: nil on failure, so a transient problem (model not ready,
    /// unreadable file) is retried on the next poll instead of being cached as
    /// an empty transcript.
    func transcribe(fileURL: URL, language: String?) async -> String? {
        if state != .ready { state = .loading }
        do {
            let text = try await engine.transcribe(url: fileURL, model: model, language: language)
            state = .ready
            return text
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Appends transcripts to the voice and video messages in place, cached per
    /// message id so a file either client has since purged keeps its text.
    /// Media is resolved through `ChatMedia`, which both stores feed absolute
    /// paths into, so the source no longer matters here.
    func attachTranscripts(to messages: inout [ChatMessage], cache: inout [String: String], language: String?) async {
        // "" means auto-detect; normalize here so no caller can pass an empty
        // language code, which Whisper treats as a real (invalid) language.
        let language = language?.isEmpty == false ? language : nil
        for index in messages.indices {
            let message = messages[index]
            guard message.mediaType == 2 || message.mediaType == 3 else { continue }
            let key = message.id
            if let cached = cache[key] {
                Self.append(cached, to: &messages[index])
                continue
            }
            guard let url = ChatMedia.url(message.mediaPath) else {
                // Gone from disk: remember that, or every poll would look again.
                cache[key] = ""
                continue
            }
            guard let text = await transcribe(fileURL: url, language: language) else { continue }
            cache[key] = text
            Self.append(text, to: &messages[index])
        }
    }

    private static func append(_ transcript: String, to message: inout ChatMessage) {
        guard !transcript.isEmpty else { return }
        let label = message.mediaType == 3 ? "voice transcript" : "video transcript"
        message.text += " (\(label): \(String(transcript.prefix(1200))))"
    }
}

/// Serialises the Whisper work so two projects never fight over the ANE.
actor WhisperEngine {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    func load(model: String) async throws {
        _ = try await pipe(for: model)
    }

    func unload() {
        pipe = nil
        loadedModel = nil
    }

    func transcribe(url: URL, model: String, language: String?) async throws -> String {
        let pipe = try await pipe(for: model)
        let (audioURL, isTemporary) = try await Self.audioFile(for: url)
        defer { if isTemporary { try? FileManager.default.removeItem(at: audioURL) } }
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        // Auto-detect by default: forcing the wrong language (an English video
        // in a Turkish chat) garbles the output, and Whisper is reliable on
        // anything longer than a couple of seconds.
        options.usePrefillPrompt = language != nil
        options.detectLanguage = language == nil
        let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pipe(for model: String) async throws -> WhisperKit {
        if let pipe, loadedModel == model { return pipe }
        let config = WhisperKitConfig(model: model, downloadBase: WhisperModels.downloadBase,
                                      verbose: false, logLevel: .error,
                                      prewarm: false, load: true, download: true)
        let loaded = try await WhisperKit(config)
        pipe = loaded
        loadedModel = model
        return loaded
    }

    /// Voice notes are Ogg Opus, which CoreAudio reads directly. Videos need
    /// their audio track exported first.
    private static func audioFile(for url: URL) async throws -> (URL, Bool) {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi"]
        guard videoExtensions.contains(url.pathExtension.lowercased()) else { return (url, false) }

        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw TranscriptionError.noAudioTrack
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.cannotExport
        }
        if try await asset.load(.duration).seconds > maxVideoSeconds {
            export.timeRange = CMTimeRange(start: .zero,
                                           duration: CMTime(seconds: maxVideoSeconds, preferredTimescale: 600))
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ookook-\(UUID().uuidString).m4a")
        export.outputURL = output
        export.outputFileType = .m4a
        // AVAssetExportSession is not Sendable; the callback is the only thing
        // that touches it, and it runs exactly once.
        let box = ExportSessionBox(export)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch box.session.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: box.session.error ?? TranscriptionError.cannotExport)
                }
            }
        }
        return (output, true)
    }

    /// Only the start of a long video is transcribed.
    private static let maxVideoSeconds: Double = 600
}

/// Lets the export callback read the session without tripping Sendable checks.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// Where WhisperKit keeps its models, shared by the engine and the settings
/// status row. Kept out of ~/Documents, where WhisperKit would put them.
enum WhisperModels {
    static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Ookook/Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func folder(for model: String) -> URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)",
                                            isDirectory: true)
    }
}

enum TranscriptionError: LocalizedError {
    case noAudioTrack
    case cannotExport

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "the video has no audio track"
        case .cannotExport: return "the video's audio could not be extracted"
        }
    }
}
