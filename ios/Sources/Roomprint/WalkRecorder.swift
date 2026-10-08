import ARKit
import AVFoundation
import QuartzCore

/// Records what the camera sees during a RoomPlan scan, plus the microphone, into one
/// .mov. Frames are polled from the AR session's currentFrame, so RoomPlan keeps the
/// session (and its delegate) to itself. Video and sound are written separately and
/// joined at the end; both start together, so they stay in sync.
@MainActor
final class WalkRecorder: NSObject {
    private let session: ARSession
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var link: CADisplayLink?
    private var first: TimeInterval?
    private var last: TimeInterval = 0
    private var audio: AVAudioRecorder?
    private var finished: Task<URL?, Never>?

    private let stamp = Int(Date().timeIntervalSince1970)
    private var dir: URL { FileManager.default.temporaryDirectory }
    private var videoURL: URL { dir.appendingPathComponent("walk-\(stamp)-video.mov") }
    private var audioURL: URL { dir.appendingPathComponent("walk-\(stamp)-audio.m4a") }
    var outputURL: URL { dir.appendingPathComponent("walk-\(stamp).mov") }

    init(session: ARSession) {
        self.session = session
    }

    func start() {
        guard link == nil else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers, .defaultToSpeaker])
        try? s.setActive(true)
        audio = try? AVAudioRecorder(url: audioURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        audio?.record()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        guard let frame = session.currentFrame, frame.timestamp > last else { return }
        last = frame.timestamp
        let pb = frame.capturedImage
        if writer == nil {
            guard setUpWriter(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)) else { return }
            first = frame.timestamp
        }
        guard let input, input.isReadyForMoreMediaData, let first else { return }
        adaptor?.append(pb, withPresentationTime: CMTime(seconds: frame.timestamp - first, preferredTimescale: 600))
    }

    private func setUpWriter(width: Int, height: Int) -> Bool {
        guard let w = try? AVAssetWriter(outputURL: videoURL, fileType: .mov) else { return false }
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        i.expectsMediaDataInRealTime = true
        // The sensor image is landscape; the app is held in portrait.
        i.transform = CGAffineTransform(rotationAngle: .pi / 2)
        guard w.canAdd(i) else { return false }
        w.add(i)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
        guard w.startWriting() else { return false }
        w.startSession(atSourceTime: .zero)
        writer = w
        input = i
        return true
    }

    /// Stops recording and returns the finished video with sound (nil if nothing was filmed).
    func finish() async -> URL? {
        if finished == nil { finished = Task { await stopAndSave() } }
        return await finished!.value
    }

    private func stopAndSave() async -> URL? {
        link?.invalidate()
        link = nil
        audio?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let writer, let input else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return (try? await mux()) ?? videoURL
    }

    private func mux() async throws -> URL? {
        let video = AVURLAsset(url: videoURL)
        let sound = AVURLAsset(url: audioURL)
        guard let vt = try await video.loadTracks(withMediaType: .video).first else { return nil }
        let duration = try await video.load(.duration)
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vt, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        if let at = try? await sound.loadTracks(withMediaType: .audio).first,
           let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let ad = try await sound.load(.duration)
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, ad)), of: at, at: .zero)
        }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return nil }
        try? FileManager.default.removeItem(at: outputURL)
        ex.outputURL = outputURL
        ex.outputFileType = .mov
        await ex.export()
        return ex.status == .completed ? outputURL : nil
    }
}
