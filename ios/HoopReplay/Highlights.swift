import AVFoundation
import Foundation
import Photos

/// Who a highlight is for: one player's plays, or one team's scoring plays.
enum HighlightTarget: Hashable {
    case player(Int64)
    case team(Int64)
}

/// A stretch of one recording, [startMs, endMs) inside segment `segment`.
struct Clip: Hashable {
    var segment: Int
    var startMs: Int64
    var endMs: Int64
}

private let clipBeforeMs: Int64 = 8000
private let clipAfterMs: Int64 = 2000
private let teamTypes: Set<String> = ["PTS_1", "PTS_2", "PTS_3", "FT_MADE"]
private let playerTypes = teamTypes.union(["REB", "OREB", "DREB", "AST", "STL", "BLK"])

/// The highlight clip rule shared with Android and the Web (web/lib/highlight-clips.ts; the fixture
/// web/lib/highlight-clips.fixture.json pins all three). Each play becomes a window from 8 s before
/// to 2 s after it was recorded, kept inside its own recording; overlapping or touching windows merge.
func highlightClips(_ events: [StatEvent], _ segments: [RecordingSegment], _ target: HighlightTarget) -> [Clip] {
    let durations = Dictionary(segments.filter { $0.sequence > 0 }.map { ($0.sequence, $0.durationMs) }, uniquingKeysWith: { a, _ in a })
    let windows = events
        .filter { e in
            guard !e.reverted, durations[e.segment] != nil else { return false }
            switch target {
            case .player(let id): return e.playerId == id && playerTypes.contains(e.type)
            case .team(let id): return e.teamId == id && teamTypes.contains(e.type)
            }
        }
        .map { Clip(segment: $0.segment, startMs: max(0, $0.segmentTimeMs - clipBeforeMs), endMs: min(durations[$0.segment]!, $0.segmentTimeMs + clipAfterMs)) }
        // A play stamped past the end of its recording has nothing to show.
        .filter { $0.startMs < $0.endMs }
        .sorted { ($0.segment, $0.startMs) < ($1.segment, $1.startMs) }
    var clips: [Clip] = []
    for w in windows {
        if let last = clips.last, last.segment == w.segment, w.startMs <= last.endMs {
            clips[clips.count - 1].endMs = max(last.endMs, w.endMs)
        } else {
            clips.append(w)
        }
    }
    return clips
}

// MARK: - Phone export (phase 1)


/// What a finished highlight export produced: the local file (kept for upload) and its Photos asset.
struct HighlightResult {
    var file: URL
    var clips: Int
    var skipped: Int
    var durationMs: Int64
}

enum HighlightError: LocalizedError {
    case photosDenied, exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .photosDenied: t("Allow HoopReplay to access Photos to cut highlights from your recordings")
        case .exportFailed(let message): message
        }
    }
}

/// The recording behind a segment uri: a Photos asset id, or a file path when Photos access was denied while recording.
private func recordingAsset(_ uri: String) async -> AVAsset? {
    if uri.hasPrefix("/") { return FileManager.default.fileExists(atPath: uri) ? AVURLAsset(url: URL(fileURLWithPath: uri)) : nil }
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [uri], options: nil).firstObject else { return nil }
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    return await withCheckedContinuation { continuation in
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in continuation.resume(returning: avAsset) }
    }
}

/// Reading recordings back out of Photos needs read access, not just the add-only access recording uses.
func requestPhotosReadAccess() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    return status == .authorized || status == .limited
}

/// Clips whose recording is still on this phone, paired with its asset, plus how many were dropped because it is gone.
func playableClips(_ clips: [Clip], _ segments: [RecordingSegment]) async -> ([(Clip, AVAsset)], Int) {
    var assets: [Int: AVAsset?] = [:]
    var usable: [(Clip, AVAsset)] = []
    for clip in clips {
        if assets[clip.segment] == nil {
            let uri = segments.first { $0.sequence == clip.segment }?.uri ?? ""
            assets[clip.segment] = uri.isEmpty ? nil : await recordingAsset(uri)
        }
        if let asset = assets[clip.segment] ?? nil { usable.append((clip, asset)) }
    }
    return (usable, clips.count - usable.count)
}

/// Joins the clips into one 720p mp4 (matching Android and the cloud cutter) and saves it to Photos.
func exportHighlight(_ clips: [(Clip, AVAsset)], skipped: Int, fileName: String, onProgress: @escaping @MainActor (Int) -> Void) async throws -> HighlightResult {
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw HighlightError.exportFailed(t("Highlight export failed: {message}", ["message": "video track"])) }
    let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    var cursor = CMTime.zero
    for (clip, asset) in clips {
        let range = CMTimeRange(start: CMTime(value: clip.startMs, timescale: 1000), end: CMTime(value: clip.endMs, timescale: 1000))
        if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first {
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }
        if let audio, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first { try audio.insertTimeRange(range, of: sourceAudio, at: cursor) }
        cursor = cursor + range.duration
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Highlights", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let out = folder.appendingPathComponent(fileName)
    try? FileManager.default.removeItem(at: out)
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720) else { throw HighlightError.exportFailed(t("Highlight export failed: {message}", ["message": "export session"])) }
    let poll = Task { @MainActor in
        while !Task.isCancelled { onProgress(Int(session.progress * 100)); try? await Task.sleep(for: .milliseconds(250)) }
    }
    defer { poll.cancel() }
    session.outputURL = out
    session.outputFileType = .mp4
    // moov first, so browsers start the uploaded video without fetching the whole file.
    session.shouldOptimizeForNetworkUse = true
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
    } onCancel: { session.cancelExport() }
    guard session.status == .completed else {
        try? FileManager.default.removeItem(at: out)
        if session.status == .cancelled { throw CancellationError() }
        throw HighlightError.exportFailed(t("Highlight export failed: {message}", ["message": session.error?.localizedDescription ?? ""]))
    }
    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out) }
    return HighlightResult(file: out, clips: clips.count, skipped: skipped, durationMs: clips.reduce(0) { $0 + $1.0.endMs - $1.0.startMs })
}
