import AVFoundation
import Foundation
import Network
import Photos

/// When whole-game recordings upload to the cloud for cloud highlight cutting (Settings → Upload recordings).
enum UploadRecordings: String, CaseIterable {
    case off = "Off", wifiOnly = "Wi-Fi only", always = "Always"
}

/**
 Highlight and footage uploads to Cloudflare R2 through the Web API, the same flow as Android's
 VideoUpload.kt (spec: docs/superpowers/specs/2026-10-04-video-highlights-design.md). The phone
 never holds R2 credentials: every PUT goes to a presigned URL the API hands out after checking access.
 */
@MainActor
enum VideoUpload {
    private static let settingKey = "upload_recordings"

    static var uploadRecordings: UploadRecordings {
        get { UserDefaults.standard.string(forKey: settingKey).flatMap(UploadRecordings.init(rawValue:)) ?? .wifiOnly }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: settingKey) }
    }

    /// The game's cloud uuid after making sure the game and its events are synced.
    private static func syncedGameUuid(_ store: AppStore, _ gameId: Int64) async throws -> String {
        try await HoopSync.push(store)
        guard let uuid = try await HoopSync.gameUuid(gameId) else { throw HighlightError.exportFailed(t("Sync this game before uploading")) }
        return uuid
    }

    private static func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    /// Uploads a finished phone highlight so the Web game page can play it.
    static func uploadHighlight(_ store: AppStore, gameId: Int64, result: HighlightResult, targetKey: String, label: String) async throws {
        let uuid = try await syncedGameUuid(store, gameId)
        let start = json(try await HoopSync.webRequest("POST", "/api/highlights/upload", body: ["game_uuid": uuid]))
        guard let putURL = start["put_url"] as? String, let id = start["id"] as? String else { throw HighlightError.exportFailed(t("Upload failed: {message}", ["message": "no upload url"])) }
        _ = try await put(putURL, file: result.file)
        _ = try await HoopSync.webRequest("PUT", "/api/highlights/upload", body: [
            "game_uuid": uuid, "id": id, "target_key": targetKey, "target_label": label, "duration_ms": result.durationMs, "clip_count": result.clips,
        ])
    }

    /// Recording upload state for the game: (uploaded, total) over the recordings this phone holds.
    static func footageStatus(_ store: AppStore, gameId: Int64) async throws -> (Int, Int) {
        let local = store.segmentRows.filter { $0.gameId == gameId && $0.sequence > 0 && !$0.uri.isEmpty }
        guard let uuid = try await HoopSync.gameUuid(gameId) else { return (0, local.count) }
        let uploaded = try await uploadedSequences(uuid)
        return (local.filter { uploaded.contains($0.sequence) }.count, local.count)
    }

    private static func uploadedSequences(_ uuid: String) async throws -> Set<Int> {
        let rows = (try? JSONSerialization.jsonObject(with: try await HoopSync.webRequest("GET", "/api/footage?game_uuid=\(uuid)")) as? [[String: Any]]) ?? []
        return Set(rows.filter { $0["upload_status"] as? String == "uploaded" }.compactMap { $0["sequence"] as? Int })
    }

    /**
     Uploads every recording of the game that is on this phone and not in the cloud yet, as resumable
     multipart uploads: the upload id is kept until the recording completes, so a killed app or a lost
     connection continues where it stopped. `onProgress` gets bytes sent / total.
     */
    static func uploadFootage(_ store: AppStore, gameId: Int64, onProgress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws {
        let uuid = try await syncedGameUuid(store, gameId)
        let uploaded = try await uploadedSequences(uuid)
        var pending: [(RecordingSegment, URL, Int64)] = []
        for seg in store.segmentRows where seg.gameId == gameId && seg.sequence > 0 && !seg.uri.isEmpty && !uploaded.contains(seg.sequence) {
            if let file = await recordingFile(seg.uri), let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, size > 0 {
                pending.append((seg, file, size))
            }
        }
        let total = pending.reduce(0) { $0 + $1.2 }
        var sent: Int64 = 0
        for (seg, file, size) in pending {
            let key = "upload_\(uuid)_\(seg.sequence)"
            let start = json(try await HoopSync.webRequest("POST", "/api/footage", body: [
                "game_uuid": uuid, "sequence": seg.sequence, "size": size, "upload_id": UserDefaults.standard.string(forKey: key) ?? "",
            ]))
            guard let uploadId = start["upload_id"] as? String, let partSize = (start["part_size"] as? NSNumber)?.int64Value else { throw HighlightError.exportFailed(t("Upload failed: {message}", ["message": "no upload id"])) }
            UserDefaults.standard.set(uploadId, forKey: key)
            var etags: [Int: String] = [:]
            for part in start["done"] as? [[String: Any]] ?? [] { if let n = part["number"] as? Int, let e = part["etag"] as? String { etags[n] = e } }
            sent += etags.keys.reduce(0) { $0 + min(partSize, size - Int64($1 - 1) * partSize) }
            onProgress(sent, total)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            for part in start["parts"] as? [[String: Any]] ?? [] {
                guard let number = part["number"] as? Int, let url = part["url"] as? String else { continue }
                let offset = Int64(number - 1) * partSize
                try handle.seek(toOffset: UInt64(offset))
                let bytes = handle.readData(ofLength: Int(min(partSize, size - offset)))
                etags[number] = try await put(url, data: bytes)
                sent += Int64(bytes.count)
                onProgress(sent, total)
            }
            _ = try await HoopSync.webRequest("PUT", "/api/footage", body: [
                "game_uuid": uuid, "sequence": seg.sequence, "upload_id": uploadId,
                "parts": etags.map { ["number": $0.key, "etag": $0.value] },
            ])
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /**
     Starts a footage upload for the game when the Upload recordings setting allows it on the current
     network. iOS has no WorkManager: the upload runs while the app is open, and the next call (after
     the next recording, or from the Highlights dialog) resumes the multipart upload where it stopped.
     */
    // ponytail: foreground-only; move to a background URLSession if users close the app mid-upload.
    static func schedule(_ store: AppStore, gameId: Int64) {
        guard uploadRecordings != .off, HoopSync.isSignedIn, !running.contains(gameId) else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            monitor.cancel()
            let satisfied = path.status == .satisfied, expensive = path.isExpensive
            Task { @MainActor in
                guard satisfied, uploadRecordings == .always || !expensive, !running.contains(gameId) else { return }
                running.insert(gameId)
                defer { running.remove(gameId) }
                try? await uploadFootage(store, gameId: gameId)
            }
        }
        monitor.start(queue: .main)
    }
    private static var running: Set<Int64> = []

    /// A file URL for a recording: the path itself, or the Photos asset's underlying movie file.
    private static func recordingFile(_ uri: String) async -> URL? {
        if uri.hasPrefix("/") { return FileManager.default.fileExists(atPath: uri) ? URL(fileURLWithPath: uri) : nil }
        guard await requestPhotosReadAccess(), let asset = PHAsset.fetchAssets(withLocalIdentifiers: [uri], options: nil).firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in continuation.resume(returning: (avAsset as? AVURLAsset)?.url) }
        }
    }

    /// PUTs to a presigned R2 URL and returns the ETag R2 assigned.
    private static func put(_ url: String, data: Data? = nil, file: URL? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (body, response) = if let file { try await URLSession.shared.upload(for: request, fromFile: file) } else { try await URLSession.shared.upload(for: request, from: data ?? Data()) }
        let http = response as? HTTPURLResponse
        guard let http, 200..<300 ~= http.statusCode else {
            throw HighlightError.exportFailed(t("Upload failed ({code}): {text}", ["code": http?.statusCode ?? 0, "text": String((String(data: body, encoding: .utf8) ?? "").prefix(200))]))
        }
        return http.value(forHTTPHeaderField: "ETag") ?? ""
    }
}
