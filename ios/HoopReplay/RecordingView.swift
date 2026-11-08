import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UIKit

// The landscape recorder, a straight port of the Android RecorderScreen: the same two-position
// Start/Pause/Resume + Exit/Stop state machine from docs/record_button_workflow_v3.md, the same
// team panels and stat flows from docs/stat_buttons_workflow.md, and a camera session that pauses
// and resumes into one file with the scoreboard burned into the video.

/// Recording-mode state machine: IDLE (Start/Exit), RECORDING (Pause/Stop), PAUSED (Resume/Stop);
/// STARTING/STOPPING/ERROR are internal transient states used for debouncing and recovery.
enum RecorderState { case idle, starting, recording, paused, stopping, error }

private let minRecordingBytes: Int64 = 500 * 1024 * 1024

private func lowStorage() -> Bool {
    let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let available = values?.volumeAvailableCapacityForImportantUsage else { return false }
    return available < minRecordingBytes
}

private var recordingsDirectory: URL {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func videoFileName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd_HHmmssSSS"
    return "HoopReplay_\(formatter.string(from: Date())).mp4"
}

/// Moves a finished movie into the Photos library and returns the asset identifier, or nil when
/// the library is unavailable (the file then stays in the app's Recordings folder).
private func saveToPhotos(_ url: URL) async -> String? {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { return nil }
    var identifier: String?
    do {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            identifier = request?.placeholderForCreatedAsset?.localIdentifier
        }
    } catch { return nil }
    if identifier != nil { try? FileManager.default.removeItem(at: url) }
    return identifier
}

/**
 A crash while recording leaves the movie file in the Recordings folder and the segment row without
 a uri. Publishing the file and backfilling the segment keeps the footage instead of losing it.
 Returns the total recovered duration in milliseconds.
 */
@MainActor
private func recoverPendingRecordings(_ store: AppStore, _ gameId: Int64) async -> Int64 {
    let orphans = store.orphanSegments(gameId)
    guard !orphans.isEmpty, let game = store.game(gameId) else { return 0 }
    let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
    var recovered: Int64 = 0
    for file in files where file.lastPathComponent.hasPrefix("HoopReplay_\(gameId)_") {
        let rest = file.lastPathComponent.dropFirst("HoopReplay_\(gameId)_".count)
        guard let sequence = Int(rest.split(separator: "_").first ?? ""), let segmentId = orphans.first(where: { $0.1 == sequence })?.0 else { continue }
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { try? FileManager.default.removeItem(at: file); continue }
        let durationMs = Int64(duration.seconds * 1000)
        let uri = await saveToPhotos(file) ?? file.path
        store.finalizeSegment(segmentId, uri: uri, durationMs: durationMs)
        // The recovered file joins the game's Plays like any normally finished recording.
        store.addEvent(gameId: gameId, teamId: game.homeId, playerId: nil, type: "VIDEO", value: Int(durationMs / 1000), period: game.currentPeriod, clock: game.clockRemainingMs, segment: sequence, segmentMs: durationMs, videoMs: durationMs)
        recovered += durationMs
    }
    return recovered
}

// MARK: - Camera session

/// Camera preview plus a pausable recorder. Pause and Resume act on the same file: paused time never
/// enters the video. Every frame carries the scoreboard bar, like the Android OverlayEffect.
final class CameraSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "HoopReplay.camera.session")
    private let writerQueue = DispatchQueue(label: "HoopReplay.camera.writer")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var device: AVCaptureDevice?
    private var videoQuality: String
    private let gameId: Int64
    private let homeTeamId: Int64
    private weak var store: AppStore?
    var onCameraReady: (() -> Void)?

    var sequence = 0
    var completedMs: Int64 = 0
    private let lock = NSLock()
    private var _recordedMs: Int64 = 0
    /// Time actually recorded into the current file; the clock stops while paused.
    var recordedMs: Int64 { lock.lock(); defer { lock.unlock() }; return _recordedMs }
    private func setRecorded(_ value: Int64) { lock.lock(); _recordedMs = value; lock.unlock() }
    private(set) var isRecording = false

    // Writer state, touched only on writerQueue.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var fileURL: URL?
    private var writerStarted = false
    private var startPTS = CMTime.zero
    private var lastVideoPTS: CMTime?
    private var lastFrameDuration = CMTime.zero
    private var timeOffset = CMTime.zero
    private var paused = false
    private var needsOffset = false
    private var stopState = "PAUSED"
    private var onEvent: ((String) -> Void)?
    private var currentSegmentId: Int64?

    // Scoreboard overlay, updated from the main thread and read on the writer queue.
    private var overlayClockMs: Int64 = 0
    private var overlayPeriod = 1
    private var overlayPeriodCount = 4
    private var overlayHomeName = "Home"
    private var overlayAwayName = "Away"
    private var overlayHomeScore = 0
    private var overlayAwayScore = 0
    private var overlayImage: CIImage?
    private var overlayKey = ""
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(store: AppStore, gameId: Int64, homeTeamId: Int64, videoQuality: String) {
        self.store = store; self.gameId = gameId; self.homeTeamId = homeTeamId; self.videoQuality = videoQuality
        super.init()
    }

    @MainActor func updateClock(period: Int, periodCount: Int, clockMs: Int64) { lock.lock(); overlayPeriod = period; overlayPeriodCount = periodCount; overlayClockMs = clockMs; lock.unlock() }
    @MainActor func updateScoreboard(homeName: String, homeScore: Int, awayName: String, awayScore: Int) { lock.lock(); overlayHomeName = homeName; overlayHomeScore = homeScore; overlayAwayName = awayName; overlayAwayScore = awayScore; lock.unlock() }

    func configure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.applyPreset()
            if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) { self.session.addInput(input); self.device = camera }
            if let microphone = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: microphone), self.session.canAddInput(input) { self.session.addInput(input) }
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.writerQueue)
            self.audioOutput.setSampleBufferDelegate(self, queue: self.writerQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            if self.session.canAddOutput(self.audioOutput) { self.session.addOutput(self.audioOutput) }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.onCameraReady?() }
        }
    }

    private func applyPreset() {
        let preset: AVCaptureSession.Preset
        switch videoQuality {
        case "UHD": preset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        case "FHD": preset = .hd1920x1080
        case "HD": preset = .hd1280x720
        case "SD": preset = .vga640x480
        default: preset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .high
        }
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
    }

    /// Quality changes only apply while idle; the next Start records at the new resolution.
    func setVideoQuality(_ value: String) {
        guard !isRecording, value != videoQuality else { return }
        videoQuality = value
        sessionQueue.async { self.session.beginConfiguration(); self.applyPreset(); self.session.commitConfiguration() }
    }

    /// Pinch to zoom on the preview.
    func zoom(by factor: CGFloat) {
        guard let device else { return }
        let target = min(max(device.videoZoomFactor * factor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 10))
        if (try? device.lockForConfiguration()) != nil { device.videoZoomFactor = target; device.unlockForConfiguration() }
    }

    func setRotation(_ angle: CGFloat) {
        sessionQueue.async {
            if let connection = self.videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    /// Start creates a new unique file; the RECORDING event fires once the first frame is written.
    @MainActor
    func start(onEvent: @escaping (String) -> Void) -> Bool {
        guard !isRecording, session.isRunning, let store else { return false }
        sequence += 1
        setRecorded(0)
        let url = recordingsDirectory.appendingPathComponent(videoFileName())
        let segmentId = store.startSegment(gameId, sequence: sequence)
        isRecording = true
        writerQueue.async {
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { DispatchQueue.main.async { self.isRecording = false; onEvent("ERROR") }; return }
            // Fragments every few seconds keep the file playable even if the app dies mid-recording.
            writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            self.writer = writer; self.fileURL = url; self.onEvent = onEvent; self.currentSegmentId = segmentId
            self.writerStarted = false; self.lastVideoPTS = nil; self.timeOffset = .zero; self.paused = false; self.needsOffset = false; self.stopState = "PAUSED"; self.lastFrameDuration = .zero
            self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
        }
        return true
    }
    func pause() { writerQueue.async { self.paused = true } }
    func resume() { writerQueue.async { self.paused = false; self.needsOffset = true } }

    /// Stop finalizes the file automatically; every finished file becomes one recording entry in Plays.
    func stop(finalState: String = "PAUSED") {
        writerQueue.async {
            self.stopState = finalState
            guard let writer = self.writer else { DispatchQueue.main.async { self.isRecording = false; self.onEvent?(finalState) }; return }
            let duration = self.recordedMs
            let url = self.fileURL
            let segmentId = self.currentSegmentId
            let period = self.overlayPeriod, clock = self.overlayClockMs, sequence = self.sequence
            self.writer = nil
            let finish: (Bool) -> Void = { ok in
                Task { @MainActor in
                    self.completedMs += duration
                    self.setRecorded(0)
                    self.isRecording = false
                    var uri = url?.path ?? ""
                    if ok, duration > 0, let url { uri = await saveToPhotos(url) ?? url.path } else if let url { try? FileManager.default.removeItem(at: url) }
                    if let segmentId { self.store?.finalizeSegment(segmentId, uri: uri, durationMs: duration); if let store = self.store { VideoUpload.schedule(store, gameId: self.gameId) } }
                    if ok && duration > 0 { self.store?.addEvent(gameId: self.gameId, teamId: self.homeTeamId, playerId: nil, type: "VIDEO", value: Int(duration / 1000), period: period, clock: clock, segment: sequence, segmentMs: duration, videoMs: duration) }
                    self.onEvent?(ok ? finalState : "ERROR")
                }
            }
            if self.writerStarted && writer.status == .writing {
                self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
                writer.finishWriting { finish(writer.status == .completed) }
            } else {
                writer.cancelWriting()
                finish(true)
            }
        }
    }
    func segmentMs() -> Int64 { isRecording ? recordedMs : 0 }
    func videoMs() -> Int64 { completedMs + segmentMs() }
    func close() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    // MARK: Sample handling (writer queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if !writerStarted {
                guard setUpInputs(writer, sampleBuffer, pixelBuffer) else { return }
                guard writer.startWriting() else { failWriter(writer); return }
                writer.startSession(atSourceTime: pts)
                startPTS = pts; writerStarted = true
                DispatchQueue.main.async { self.onEvent?("RECORDING") }
            }
            if paused { return }
            if needsOffset, let last = lastVideoPTS { timeOffset = timeOffset + (pts - last) - lastFrameDuration; needsOffset = false }
            if let last = lastVideoPTS, !needsOffset, pts > last, lastFrameDuration == .zero || pts - last < CMTime(seconds: 1, preferredTimescale: 600) { lastFrameDuration = pts - last }
            lastVideoPTS = pts
            let adjusted = pts - timeOffset
            guard let videoInput, videoInput.isReadyForMoreMediaData, let adaptor else { return }
            if let composited = composite(pixelBuffer, pool: adaptor.pixelBufferPool) { adaptor.append(composited, withPresentationTime: adjusted) }
            else { adaptor.append(pixelBuffer, withPresentationTime: adjusted) }
            setRecorded(max(0, Int64((adjusted - startPTS).seconds * 1000)))
        } else if output === audioOutput {
            guard writerStarted, !paused, !needsOffset, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if timeOffset == .zero { audioInput.append(sampleBuffer); return }
            var count: CMItemCount = 0
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
            for index in timing.indices { timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - timeOffset; if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - timeOffset } }
            var adjustedBuffer: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &adjustedBuffer)
            if let adjustedBuffer { audioInput.append(adjustedBuffer) }
        }
    }

    private func failWriter(_ writer: AVAssetWriter) {
        writer.cancelWriting(); self.writer = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.main.async { self.isRecording = false; self.onEvent?("ERROR") }
    }

    private func setUpInputs(_ writer: AVAssetWriter, _ sampleBuffer: CMSampleBuffer, _ pixelBuffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var settings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) ?? [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        settings[AVVideoWidthKey] = width; settings[AVVideoHeightKey] = height
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        videoInput = video
        if let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) { writer.add(audio); audioInput = audio }
        }
        return true
    }

    /// Draws the scoreboard bar over the frame, re-rendering the bar only when its text changes.
    private func composite(_ source: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        lock.lock()
        let centerText = "\(t("Period {period}/{count}", ["period": overlayPeriod, "count": overlayPeriodCount]))  \(formatClock(overlayClockMs))"
        let awayText = "\(String(overlayAwayName.prefix(20)))  \(overlayAwayScore)"
        let homeText = "\(overlayHomeScore)  \(String(overlayHomeName.prefix(20)))"
        lock.unlock()
        let key = "\(width)x\(height)|\(awayText)|\(centerText)|\(homeText)"
        if key != overlayKey || overlayImage == nil {
            overlayKey = key
            overlayImage = renderOverlay(width: width, height: height, away: awayText, center: centerText, home: homeText)
        }
        guard let overlayImage else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }
        let base = CIImage(cvPixelBuffer: source)
        ciContext.render(overlayImage.composited(over: base), to: output)
        return output
    }

    private func renderOverlay(width: Int, height: Int, away: String, center: String, home: String) -> CIImage? {
        let size = CGFloat(min(width, height))
        let padding = size * 0.025
        let font = UIFont.boldSystemFont(ofSize: size * 0.045)
        let barHeight = font.lineHeight + padding * 2
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: barHeight), format: format).image { _ in
            let barLeft = CGFloat(width) * 0.04, barRight = CGFloat(width) * 0.96
            UIColor(white: 0, alpha: 140 / 255).setFill()
            UIBezierPath(roundedRect: CGRect(x: barLeft, y: 0, width: barRight - barLeft, height: barHeight), cornerRadius: padding).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            (away as NSString).draw(at: CGPoint(x: barLeft + padding, y: padding), withAttributes: attributes)
            let centerWidth = (center as NSString).size(withAttributes: attributes).width
            (center as NSString).draw(at: CGPoint(x: CGFloat(width) / 2 - centerWidth / 2, y: padding), withAttributes: attributes)
            let homeWidth = (home as NSString).size(withAttributes: attributes).width
            (home as NSString).draw(at: CGPoint(x: barRight - padding - homeWidth, y: padding), withAttributes: attributes)
        }
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height) - barHeight))
    }
}

/// Camera viewfinder that follows the interface orientation and supports pinch-to-zoom.
struct CameraPreview: UIViewRepresentable {
    let session: CameraSession
    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var onRotation: ((CGFloat) -> Void)?
        private var runningObserver: NSObjectProtocol?
        init(session: AVCaptureSession) {
            super.init(frame: .zero); previewLayer.videoGravity = .resizeAspectFill; previewLayer.session = session; layer.addSublayer(previewLayer)
            // The preview connection only exists once the session is configured (async), usually after the
            // first layout pass; re-run layout then so the landscape angle replaces the portrait default.
            runningObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main) { [weak self] _ in
                self?.setNeedsLayout(); self?.layoutIfNeeded()
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let runningObserver { NotificationCenter.default.removeObserver(runningObserver) } }
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            let angle = Self.rotationAngle(for: window?.windowScene?.interfaceOrientation)
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            onRotation?(angle)
        }

        private static func rotationAngle(for orientation: UIInterfaceOrientation?) -> CGFloat {
            switch orientation {
            case .landscapeLeft: return 180
            case .landscapeRight: return 0
            case .portrait: return 90
            case .portraitUpsideDown: return 270
            default: return 0
            }
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(session: session.session)
        view.onRotation = { session.setRotation($0) }
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    final class Coordinator: NSObject {
        let session: CameraSession
        init(_ session: CameraSession) { self.session = session }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) { if gesture.state == .changed { session.zoom(by: gesture.scale); gesture.scale = 1 } }
    }
}

// MARK: - Recorder screen

struct RecorderScreen: View {
    @EnvironmentObject private var store: AppStore
    let initial: Game
    var scoreOnly = false
    let onOpenTeam: (Int64) -> Void
    let onDone: () -> Void

    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var permissionAsked = false
    @State private var state: RecorderState = .idle
    @State private var clockMs: Int64 = 0
    @State private var period = 1
    @State private var cameraReady = false
    @State private var recTick = 0
    @State private var showStats = false
    @State private var resumeAfterStats = false
    @State private var showPlays = false
    @State private var pendingAction: PlayerAction?
    // The shooter is nil when the user chose to assign the player later.
    @State private var madeShot: (action: PlayerAction, shooter: Player?)?
    @State private var missedShot: (action: PlayerAction, shooter: Player?)?
    @State private var freeThrow: FreeThrowFlow?
    // A missed last free throw leaves the ball live, so the trip is only finished once the rebound
    // is assigned; the attempts are held here until then so they are written in play order.
    @State private var freeThrowRebound: (flow: FreeThrowFlow, results: [Bool])?
    @State private var foul: FoulFlow?
    @State private var substitution: Int64?
    @State private var starterTeamId: Int64?
    @State private var homeLineup: Set<Int64> = []
    @State private var awayLineup: Set<Int64> = []
    @State private var selectedQuality = ""
    @State private var showClockEditor = false
    @State private var showLowStorage = false
    @State private var showStopFirst = false
    @State private var recoveredNoticeMs: Int64?
    @State private var fullStats = true
    @State private var addPlayerTeamId: Int64?
    @State private var editingPlay: StatEvent?
    @State private var session: CameraSession?
    @State private var wasCompleted = false
    @State private var started = false

    private var game: Game { store.game(initial.id) ?? initial }
    private var events: [StatEvent] { store.activeEvents(initial.id) }
    private var statEntryOpen: Bool { pendingAction != nil || madeShot != nil || missedShot != nil || freeThrow != nil || freeThrowRebound != nil || foul != nil || substitution != nil || showClockEditor }

    // Replay the lineup events to see who is on the floor.
    private func lineupsFromEvents() -> (Set<Int64>, Set<Int64>) {
        let recorded = events
        func lineupOf(_ teamId: Int64) -> Set<Int64> {
            let roster = Set(store.players(teamId).map(\.id))
            var onCourt: Set<Int64> = []
            for event in recorded where event.teamId == teamId {
                guard let playerId = event.playerId, roster.contains(playerId) else { continue }
                switch event.type { case "STARTER", "SUB_IN": onCourt.insert(playerId); case "SUB_OUT": onCourt.remove(playerId); default: break }
            }
            return onCourt
        }
        return (lineupOf(game.homeId), lineupOf(game.awayId))
    }
    // Undo and play edits change the lineup events behind the panel counts, so the on-court sets
    // are re-derived from the event log instead of drifting away from it.
    private func refreshLineups() { let (home, away) = lineupsFromEvents(); homeLineup = home; awayLineup = away }

    private func reload() { store.recalculateScore(game.id) }
    private func event(_ team: Int64, _ player: Player?, _ type: String, _ value: Int, points: Int = 0) {
        // A STARTER can only happen at the start of a period, so it is stamped with the period's
        // full clock no matter when the lineup is confirmed. A stat never creates a STARTER.
        let eventClock = type == "STARTER" ? game.periodDurationMs : clockMs
        store.addEvent(gameId: game.id, teamId: team, playerId: player?.id, type: type, value: value, period: period, clock: eventClock, segment: session?.sequence ?? 0, segmentMs: session?.segmentMs() ?? 0, videoMs: session?.videoMs() ?? 0)
        if let player { if team == game.homeId { homeLineup.insert(player.id) } else if team == game.awayId { awayLineup.insert(player.id) } }
        if points != 0 { store.score(game, homeDelta: team == game.homeId ? points : 0, awayDelta: team == game.awayId ? points : 0) }
        reload()
    }
    private func undo() {
        guard let e = store.undo(game.id) else { return }
        if isScoringType(e.type) { store.score(game, homeDelta: e.teamId == game.homeId ? -e.value : 0, awayDelta: e.teamId == game.awayId ? -e.value : 0) }
        reload(); refreshLineups()
    }
    /// Leaving is only possible while idle. A finished game keeps COMPLETED and a never-recorded game stays READY.
    private func leaveRecorder() {
        if !wasCompleted && game.status == "RECORDING" { store.status(game.id, "PAUSED") }
        store.saveProgress(game.id, period: period, clockRemainingMs: clockMs)
    }
    private func leaveToTeam(_ teamId: Int64) {
        if state != .idle && state != .error { showStopFirst = true; return }
        leaveRecorder(); onOpenTeam(teamId)
    }
    private func onRecordEvent(_ evt: String) {
        switch evt {
        case "RECORDING": state = .recording; if !wasCompleted { store.status(game.id, "RECORDING") }
        case "ERROR": state = .error
        default:
            // The file finalized and its Plays entry is written; the workflow returns to idle.
            state = .idle
            if !wasCompleted { store.status(game.id, "PAUSED") }
            store.saveProgress(game.id, period: period, clockRemainingMs: clockMs)
            reload()
        }
    }
    /// Start creates a new unique file after the storage gate.
    private func startRecording() {
        guard state == .idle, let session else { return }
        if lowStorage() { showLowStorage = true; return }
        state = .starting
        if !session.start(onEvent: { evt in DispatchQueue.main.async { onRecordEvent(evt) } }) { state = .idle }
    }
    /// Stop disables everything, finalizes the file automatically, and returns to idle.
    private func stopRecording() {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        store.saveProgress(game.id, period: period, clockRemainingMs: clockMs)
        session?.stop(finalState: "FINALIZED")
    }
    /// Retry re-runs pending-file recovery; success returns the workflow to idle.
    private func retryRecovery() {
        guard state == .error else { return }
        state = .stopping
        Task { _ = await recoverPendingRecordings(store, game.id); state = store.orphanSegments(game.id).isEmpty ? .idle : .error; reload() }
    }
    private func requestPermission() {
        Task {
            let video = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            permission = video
            if video { session?.configure() }
        }
    }
    private var statusText: String {
        switch state {
        case .idle: return t("Ready")
        case .starting: return t("Starting…")
        case .recording: return scoreOnly ? t("Running") : t("● REC {time}", ["time": formatClock(session?.recordedMs ?? 0)])
        case .paused: return scoreOnly ? t("Paused") : t("Paused {time}", ["time": formatClock(session?.recordedMs ?? 0)])
        case .stopping: return t("Stopping…")
        case .error: return t("Error")
        }
    }

    var body: some View {
        ZStack {
            Theme.scoreboardBackground.ignoresSafeArea()
            if !scoreOnly && !permission {
                VStack(spacing: 8) {
                    Text(t("Camera permission is required to record")).font(Fonts.bodyLarge).foregroundStyle(.white)
                    MButton(t("Grant Permission")) { if AVCaptureDevice.authorizationStatus(for: .video) == .denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } else { requestPermission() } }
                    MButton(t("Back"), action: onDone)
                }
            } else {
                mainContent
            }
            dialogs
        }
        .statusBarHidden(true)
        .onAppear { if !started { started = true; setUp() } }
        .onDisappear { session?.close() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // The game clock follows the recording: it runs while RECORDING and freezes with Pause. It also
            // freezes while a stat-entry dialog is open; the recording timer keeps counting.
            guard state == .recording else { return }
            recTick += 1
            if !statEntryOpen {
                // Score mode is often used while re-watching a recorded game, so its game clock runs at half speed.
                clockMs = max(0, clockMs - (scoreOnly ? 500 : 1000))
                store.saveProgress(game.id, period: period, clockRemainingMs: clockMs)
            }
        }
        .onChange(of: clockMs) { _, _ in session?.updateClock(period: period, periodCount: game.periodCount, clockMs: clockMs) }
        .onChange(of: period) { _, _ in session?.updateClock(period: period, periodCount: game.periodCount, clockMs: clockMs) }
        .onChange(of: game.homeScore + game.awayScore * 1000) { _, _ in session?.updateScoreboard(homeName: game.homeName, homeScore: game.homeScore, awayName: game.awayName, awayScore: game.awayScore) }
    }

    private func setUp() {
        wasCompleted = initial.status == "COMPLETED"
        period = initial.currentPeriod
        // The saved game clock can be ahead of the event log (for example after
        // reopening a paused game). The remaining time must never be later than
        // the last actual play in the current period. STARTER and VIDEO are
        // metadata, not plays, so they do not constrain the clock.
        let lastPlayClock = store.events(initial.id)
            .filter { !$0.reverted && $0.period == period && $0.type != "STARTER" && $0.type != "VIDEO" }
            .max { $0.id < $1.id }?
            .gameClockMs
        clockMs = lastPlayClock.map { min(initial.clockRemainingMs, $0) } ?? initial.clockRemainingMs
        selectedQuality = initial.videoQuality
        cameraReady = scoreOnly
        refreshLineups()
        if !scoreOnly {
            let camera = CameraSession(store: store, gameId: initial.id, homeTeamId: initial.homeId, videoQuality: initial.videoQuality)
            camera.onCameraReady = { cameraReady = true }
            camera.updateClock(period: period, periodCount: initial.periodCount, clockMs: clockMs)
            camera.updateScoreboard(homeName: initial.homeName, homeScore: initial.homeScore, awayName: initial.awayName, awayScore: initial.awayScore)
            session = camera
            if permission { camera.configure() } else { requestPermission() }
            Task { let recovered = await recoverPendingRecordings(store, initial.id); if recovered > 0 { recoveredNoticeMs = recovered } }
        }
    }

    private var mainContent: some View {
        ZStack {
            if !scoreOnly, let session { CameraPreview(session: session).ignoresSafeArea() }
            HStack(spacing: 0) {
                TeamPanel(score: game.awayScore, lineupCount: awayLineup.count, fullStats: fullStats, transparentAccents: !scoreOnly, onStarters: { starterTeamId = game.awayId }, onAddPlayer: { addPlayerTeamId = game.awayId }, onPoints: { points in if fullStats { pendingAction = PlayerAction(teamId: game.awayId, type: "PTS_\(points)", value: points, points: points, needsAssist: points == 2 || points == 3) } else { event(game.awayId, nil, "PTS_\(points)", points, points: points) } }, onMiss: { pendingAction = PlayerAction(teamId: game.awayId, type: "MISS_\($0)", value: $0, needsRebound: true) }, onFreeThrow: { freeThrow = FreeThrowFlow(teamId: game.awayId) }, onFoul: { foul = FoulFlow(teamId: game.awayId) }, onSubstitution: { substitution = game.awayId }, onStat: { pendingAction = PlayerAction(teamId: game.awayId, type: $0, value: 1) }, onAdjust: { delta in if delta > 0 || game.awayScore > 0 { event(game.awayId, nil, "ADJ", delta, points: delta) } }, teamName: game.awayName)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(0)
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.26 }
                // Scoreboard, timeline and toolbar share one column: the timeline takes whatever height the
                // other two leave, so no strip of empty background is left over below the last play.
                VStack(spacing: 0) {
                    // Team links flank the clock with the same 1 / 1.35 / 1 split as Android; the clock never
                    // wraps, it just draws past its column edge when a wide digit combination is a little long.
                    WeightedRow(weights: [1, 1.35, 1], spacing: 0) { index, _ in
                        switch index {
                        case 0: TeamNameLink(name: "\(game.awayName) \(t("(A)"))", maxLines: 1) { leaveToTeam(game.awayId) }
                        case 1:
                            VStack(spacing: 0) {
                                Text("\(period > game.periodCount ? t("OT {n}", ["n": period - game.periodCount]) : t("Period {period}/{count}", ["period": period, "count": game.periodCount]))  \(formatClock(clockMs))").font(Fonts.titleLarge).foregroundStyle(.white).lineLimit(1).fixedSize()
                                Text(statusText).font(Fonts.bodyLarge).foregroundStyle(state == .recording && !scoreOnly ? .red : Theme.orange).lineLimit(1)
                            }.frame(maxWidth: .infinity)
                        default: TeamNameLink(name: "\(game.homeName) \(t("(H)"))", maxLines: 1) { leaveToTeam(game.homeId) }
                        }
                    }
                    .frame(height: 50)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.black.opacity(0.25))
                    // Recording mode is a viewfinder: the middle stays clear so the camera preview behind it is
                    // what the user frames. The play list belongs to Score mode, which has no preview to cover.
                    if scoreOnly {
                        EventTimeline(game: game, events: events, editable: true, autoScrollToLatest: true, showTeamHeader: false, onEdit: { editingPlay = $0 })
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
                    } else { Spacer(minLength: 0) }
                    toolbar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TeamPanel(score: game.homeScore, lineupCount: homeLineup.count, fullStats: fullStats, transparentAccents: !scoreOnly, onStarters: { starterTeamId = game.homeId }, onAddPlayer: { addPlayerTeamId = game.homeId }, onPoints: { points in if fullStats { pendingAction = PlayerAction(teamId: game.homeId, type: "PTS_\(points)", value: points, points: points, needsAssist: points == 2 || points == 3) } else { event(game.homeId, nil, "PTS_\(points)", points, points: points) } }, onMiss: { pendingAction = PlayerAction(teamId: game.homeId, type: "MISS_\($0)", value: $0, needsRebound: true) }, onFreeThrow: { freeThrow = FreeThrowFlow(teamId: game.homeId) }, onFoul: { foul = FoulFlow(teamId: game.homeId) }, onSubstitution: { substitution = game.homeId }, onStat: { pendingAction = PlayerAction(teamId: game.homeId, type: $0, value: 1) }, onAdjust: { delta in if delta > 0 || game.homeScore > 0 { event(game.homeId, nil, "ADJ", delta, points: delta) } }, teamName: game.homeName)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.26 }
            }
            if let teamId = addPlayerTeamId {
                RosterNumbersOverlay(teamId: teamId, teamName: teamId == game.homeId ? game.homeName : game.awayName, onDismiss: { addPlayerTeamId = nil })
            }
        }
    }

    private var toolbar: some View {
        // Outline-only toolbar buttons: transparent fill with white labels, so the strip's backdrop shows
        // through; Record and Exit keep their red/orange accents. The border never changes when disabled.
        VStack(spacing: 6) {
            WeightedRow(weights: [1.2, 1, 1, 1.6]) { index, _ in
                switch index {
                case 0:
                    // Position 1: Start / Pause / Resume (Retry after an error). The button never vanishes —
                    // when its action is unavailable it is disabled with the border intact.
                    let label: String = { switch state { case .idle: return t("Start"); case .starting: return t("Starting…"); case .recording: return t("Pause"); case .paused: return t("Resume"); case .stopping: return t("Start"); case .error: return t("Retry") } }()
                    let enabled: Bool = { switch state { case .idle: return cameraReady; case .recording, .paused, .error: return true; default: return false } }()
                    MOutlinedButton(label, enabled: enabled, content: Theme.orange, border: Theme.orange, borderWidth: 2, horizontalPadding: 8, fullWidth: true, font: Fonts.labelMedium) {
                        switch state {
                        case .idle: if scoreOnly { state = .recording } else { startRecording() }
                        case .recording: if !scoreOnly { session?.pause() }; state = .paused; store.saveProgress(game.id, period: period, clockRemainingMs: clockMs)
                        case .paused: if !scoreOnly { session?.resume() }; state = .recording
                        case .error: retryRecovery()
                        default: break
                        }
                    }.accessibilityIdentifier("recorder_pos1")
                case 1:
                    // Position 2: Exit while idle, Stop while a session is running or paused — in both modes.
                    let pos2Stop = state == .recording || state == .paused || state == .stopping
                    let enabled = state == .idle || state == .recording || state == .paused || state == .error
                    MOutlinedButton(pos2Stop ? t("Stop") : t("Exit"), enabled: enabled, container: scoreOnly ? Theme.exitRed : .clear, content: scoreOnly ? .white : Theme.exitRed, border: scoreOnly ? .clear : Theme.exitRed, borderWidth: scoreOnly ? 0 : 2, horizontalPadding: 8, fullWidth: true, font: Fonts.labelMedium) {
                        if state == .recording || state == .paused {
                            if scoreOnly { state = .idle; store.saveProgress(game.id, period: period, clockRemainingMs: clockMs) } else { stopRecording() }
                        } else { leaveRecorder(); onDone() }
                    }.accessibilityIdentifier("recorder_pos2")
                case 2: MOutlinedButton(t("Undo"), content: .white, horizontalPadding: 4, fullWidth: true, font: Fonts.labelMedium) { undo() }
                default:
                    // Period and clock are edited together; always available — the game clock freezes while the editor is open.
                    MOutlinedButton(t("Period/Time"), content: .white, horizontalPadding: 4, fullWidth: true, font: Fonts.labelMedium) { showClockEditor = true }
                }
            }.frame(height: 40)
            WeightedRow(weights: [1.35, 1, 1, 1.45]) { index, _ in
                switch index {
                case 0: MOutlinedButton(fullStats ? t("Score Mode") : t("Stat Mode"), content: .white, horizontalPadding: 6, fullWidth: true) { fullStats.toggle() }
                case 1: MOutlinedButton(t("Stats"), content: .white, horizontalPadding: 6, fullWidth: true) { resumeAfterStats = state == .recording; if resumeAfterStats && !scoreOnly { session?.pause() }; if resumeAfterStats { state = .paused }; showStats = true }
                case 2: MOutlinedButton(t("Plays"), content: .white, horizontalPadding: 6, fullWidth: true) { showPlays = true }
                default:
                    Menu {
                        ForEach(videoQualityOptions, id: \.key) { option in Button(t(option.label)) { selectedQuality = option.key; session?.setVideoQuality(option.key); store.videoQuality(game.id, option.key) } }
                    } label: {
                        Text(t("Quality: {quality}", ["quality": selectedQuality == "HIGHEST" ? t("Max") : selectedQuality])).font(Fonts.labelLarge).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(state == .idle ? .white : Theme.disabledLabel)
                            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                            .overlay(Capsule().strokeBorder(Theme.outline, lineWidth: 1))
                    }
                    .disabled(state != .idle)
                }
            }.frame(height: 40)
        }
        .padding(8)
        .background(Theme.scoreboardBackground)
    }

    @ViewBuilder private var dialogs: some View {
        if showStopFirst {
            AlertPanel(title: t("Recording in progress"), onDismiss: { showStopFirst = false }) { Text(t("Stop the recording before leaving this screen.")) } buttons: { MButton(t("OK")) { showStopFirst = false }.accessibilityIdentifier("stop_first_ok") }
        }
        if showLowStorage {
            AlertPanel(title: t("Not Enough Storage"), onDismiss: { showLowStorage = false }) { Text(t("Recording needs at least 500 MB of free space. Free up storage and try again.")) } buttons: { MButton(t("OK")) { showLowStorage = false } }
        }
        if let ms = recoveredNoticeMs {
            AlertPanel(title: t("Recording Recovered"), onDismiss: { recoveredNoticeMs = nil }) { Text(t("An unfinished recording from this game was recovered ({clock}). It stays linked to this game.", ["clock": formatClock(ms)])) } buttons: { MButton(t("OK")) { recoveredNoticeMs = nil } }
        }
        if showClockEditor {
            ClockEditorDialog(initialMs: clockMs, maxMs: game.periodDurationMs, initialPeriod: period, periodCount: game.periodCount, onDismiss: { showClockEditor = false }, onConfirm: confirmClock)
        }
        if let teamId = starterTeamId {
            let current = teamId == game.homeId ? homeLineup : awayLineup
            StarterSelectionDialog(teamId: teamId, players: store.players(teamId), initial: current, onConfirm: { selected in
                // Every confirmed starter gets a STARTER record for this period — including players who
                // were already on court from earlier, so the period's lineup record stays complete.
                let already = Set(events.filter { $0.teamId == teamId && $0.period == period && $0.type == "STARTER" }.compactMap(\.playerId))
                for playerId in selected where !already.contains(playerId) { event(teamId, store.player(playerId), "STARTER", 1) }
                // Deselected players leave the floor, and the event log must say so.
                for playerId in current where !selected.contains(playerId) { event(teamId, store.player(playerId), "SUB_OUT", 1) }
                if teamId == game.homeId { homeLineup = selected } else { awayLineup = selected }
                starterTeamId = nil
            }, onDismiss: { starterTeamId = nil })
        }
        if let action = pendingAction {
            PlayerChoiceDialog(teamId: action.teamId, title: action.needsRebound ? t("Who took this shot?") : action.points > 0 ? t("Who scored?") : t("Who recorded this stat?"), players: store.players(action.teamId), showNone: true, onPlayer: { player in
                if action.needsRebound { missedShot = (action, player); pendingAction = nil }
                else if action.needsAssist { madeShot = (action, player); pendingAction = nil }
                else { event(action.teamId, player, action.type, action.value, points: action.points); pendingAction = nil }
            }, onNone: {
                // Deferring the player keeps the rest of the flow: the rebound or assist is still asked.
                if action.needsRebound { missedShot = (action, nil); pendingAction = nil }
                else if action.needsAssist { madeShot = (action, nil); pendingAction = nil }
                else { event(action.teamId, nil, action.type, action.value, points: action.points); pendingAction = nil }
            }, onDismiss: { pendingAction = nil }, noneLabel: t("Assign later"), context: action.needsRebound ? t("Missed {points}-point shot", ["points": action.value]) : action.points > 0 ? t("Made {points}-point shot", ["points": action.points]) : action.type)
        }
        if let made = madeShot {
            let action = made.action, shooter = made.shooter
            PlayerChoiceDialog(teamId: action.teamId, title: t("Who made the assist?"), players: store.players(action.teamId).filter { $0.id != shooter?.id }, showNone: true, onPlayer: { player in
                event(action.teamId, player, "AST", 1); event(action.teamId, shooter, action.type, action.value, points: action.points); madeShot = nil
            }, onNone: { event(action.teamId, shooter, action.type, action.value, points: action.points); madeShot = nil },
            // Cancel here only drops the assist question: the made shot was already confirmed.
            onDismiss: { event(action.teamId, shooter, action.type, action.value, points: action.points); madeShot = nil },
            context: t("Scorer: {scorer} · {points} points", ["scorer": shooter?.label ?? t("assign later"), "points": action.points]), onBack: { madeShot = nil; pendingAction = action })
        }
        if let missed = missedShot {
            let action = missed.action, shooter = missed.shooter
            ReboundChoiceDialog(homeName: game.homeName, awayName: game.awayName, awayTeamId: game.awayId, shootingTeamId: action.teamId, homeTeamId: game.homeId, onPlayer: { player in
                event(action.teamId, shooter, action.type, action.value); event(player.teamId, player, "REB", 1); missedShot = nil
            }, onNone: { event(action.teamId, shooter, action.type, action.value); missedShot = nil },
            // Cancel here only drops the rebound question: the missed shot was already confirmed.
            onDismiss: { event(action.teamId, shooter, action.type, action.value); missedShot = nil })
        }
        if let flow = freeThrow {
            if flow.player == nil && !flow.playerSkipped {
                PlayerChoiceDialog(teamId: flow.teamId, title: t("Select shooter"), players: rosterOrder(store.players(flow.teamId)), showNone: true, onPlayer: { player in var next = flow; next.player = player; freeThrow = next }, onNone: { var next = flow; next.playerSkipped = true; freeThrow = next }, onDismiss: { freeThrow = nil }, noneLabel: t("Assign later"), context: t("Select the player taking the free throws"))
            } else {
                FreeThrowDialog(flow: flow, onUpdate: { freeThrow = $0 }, onSave: { results in
                    if results.last == false { freeThrowRebound = (flow, results) }
                    else { for made in results { event(flow.teamId, flow.player, made ? "FT_MADE" : "FT_MISS", 1, points: made ? 1 : 0) } }
                    freeThrow = nil
                }, onDismiss: { freeThrow = nil }, onBack: { freeThrow = FreeThrowFlow(teamId: flow.teamId) })
            }
        }
        if let pending = freeThrowRebound {
            let flow = pending.flow, results = pending.results
            let recordAttempts = { for made in results { event(flow.teamId, flow.player, made ? "FT_MADE" : "FT_MISS", 1, points: made ? 1 : 0) } }
            ReboundChoiceDialog(homeName: game.homeName, awayName: game.awayName, awayTeamId: game.awayId, shootingTeamId: flow.teamId, homeTeamId: game.homeId, onPlayer: { player in recordAttempts(); event(player.teamId, player, "REB", 1); freeThrowRebound = nil }, onNone: { recordAttempts(); freeThrowRebound = nil },
            // Cancel here only drops the rebound question: the free throws were already recorded.
            onDismiss: { recordAttempts(); freeThrowRebound = nil })
        }
        if let flow = foul {
            let opponentTeamId = flow.teamId == game.homeId ? game.awayId : game.homeId
            if flow.player == nil && !flow.playerSkipped {
                PlayerChoiceDialog(teamId: flow.teamId, title: t("Who committed the foul?"), players: rosterOrder(store.players(flow.teamId)), showNone: true, onPlayer: { player in var next = flow; next.player = player; foul = next }, onNone: { var next = flow; next.playerSkipped = true; foul = next }, onDismiss: { foul = nil }, noneLabel: t("Assign later"), context: t("Select the player who committed the foul"))
            } else {
                // The cloud schema calls this event FOUL_DRAWN. Keep that canonical name locally too.
                PlayerChoiceDialog(teamId: opponentTeamId, title: t("Who was fouled?"), players: rosterOrder(store.players(opponentTeamId)), showNone: true, onPlayer: { player in event(flow.teamId, flow.player, "FOUL", 1); event(opponentTeamId, player, "FOUL_DRAWN", 1); foul = nil }, onNone: { event(flow.teamId, flow.player, "FOUL", 1); foul = nil }, onDismiss: { foul = nil }, noneLabel: t("Assign later"), context: t("Select the opposing player who was fouled"), onBack: { foul = FoulFlow(teamId: flow.teamId) })
            }
        }
        if let teamId = substitution {
            let lineup = teamId == game.homeId ? homeLineup : awayLineup
            let roster = store.players(teamId)
            // One list instead of out/in questions: the on-court five arrive selected, the user reshuffles
            // freely, and Save turns the difference into sub events written as out/in pairs.
            StarterSelectionDialog(teamId: teamId, players: roster, initial: lineup, onConfirm: { selected in
                let outs = lineup.subtracting(selected).compactMap { id in roster.first { $0.id == id } }
                let ins = selected.subtracting(lineup).compactMap { id in roster.first { $0.id == id } }
                for i in 0..<max(outs.count, ins.count) {
                    if i < outs.count { event(teamId, outs[i], "SUB_OUT", 1) }
                    if i < ins.count { event(teamId, ins[i], "SUB_IN", 1) }
                }
                if teamId == game.homeId { homeLineup = selected } else { awayLineup = selected }
                substitution = nil
            }, onDismiss: { substitution = nil }, title: t("Substitution"), hint: t("Tap players to change who is on the court"), selectedLabel: t("On court"), unselectedLabel: t("Bench"), confirmLabel: t("Save"))
        }
        if showStats {
            GameStatsDialog(game: game, onDismiss: { showStats = false; if resumeAfterStats { if !scoreOnly { session?.resume() }; state = .recording; resumeAfterStats = false } })
        }
        if showPlays {
            PlaysDialog(game: game, events: events, onDismiss: { showPlays = false }, onEdit: { editingPlay = $0 })
        }
        if let event = editingPlay {
            ScreenDialog(onDismiss: { editingPlay = nil }, dismissOnScrim: false) {
                EditPlayPanel(event: event, periodDurationMs: game.periodDurationMs, periodCount: game.periodCount, roster: store.players(event.teamId), onDismiss: { editingPlay = nil }, onDelete: {
                    store.revertEvent(event.id)
                    let points = eventPoints(event.type, event.value)
                    if points != 0 { store.score(game, homeDelta: event.teamId == game.homeId ? -points : 0, awayDelta: event.teamId == game.awayId ? -points : 0) }
                    editingPlay = nil; reload(); refreshLineups()
                }, onSave: { playerId, newPeriod, clockMs in savePlayEdit(store, event, playerId, newPeriod, clockMs); editingPlay = nil; reload(); refreshLineups() })
            }
        }
    }

    private func confirmClock(_ newPeriod: Int, _ newMs: Int64) {
        // Correcting the clock from t1 to t2 shifts this period's plays recorded at ti <= t2 by
        // s = t2 - t1, capped at t2: they happened while the clock should have been stopped, so none
        // may end up earlier in the game than t2. Plays with ti > t2 predate the correction and stay.
        if newPeriod == period && newMs != clockMs {
            let delta = newMs - clockMs
            for e in store.events(game.id) where e.period == period && !e.reverted && e.gameClockMs <= newMs {
                store.updateEvent(e.id, playerId: e.playerId, type: e.type, value: e.value, period: e.period, gameClockMs: min(max(0, e.gameClockMs + delta), newMs))
            }
        }
        // Moving forward to a new period carries the on-court five with it: without an explicit STARTER
        // record in the new period the minutes attribution loses those players entirely.
        if newPeriod > period {
            let existing = Set(store.events(game.id).filter { !$0.reverted && $0.period == newPeriod && $0.type == "STARTER" }.compactMap(\.playerId))
            for (teamId, lineup) in [(game.homeId, homeLineup), (game.awayId, awayLineup)] {
                for playerId in lineup where !existing.contains(playerId) {
                    store.addEvent(gameId: game.id, teamId: teamId, playerId: playerId, type: "STARTER", value: 1, period: newPeriod, clock: game.periodDurationMs, segment: session?.sequence ?? 0, segmentMs: session?.segmentMs() ?? 0, videoMs: session?.videoMs() ?? 0)
                }
            }
        }
        period = newPeriod
        clockMs = newMs
        store.saveProgress(game.id, period: newPeriod, clockRemainingMs: newMs)
        showClockEditor = false
    }
}
