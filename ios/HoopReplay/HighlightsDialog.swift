import SwiftUI
import UIKit

/// Where a highlight export stands inside `HighlightsDialog`.
private enum HighlightState {
    case picking
    case working(label: String, progress: Int)
    case done(label: String, result: HighlightResult)
    case failed(String)
}

/**
 Cuts a player's or a team's highlight video from this phone's recordings, the same dialog as
 Android's HighlightsDialog. Picking a target is the last step, so the tap starts the export; the
 same frame then shows progress and the result, and the finished video uploads to the Web.
 */
struct HighlightsDialog: View {
    @EnvironmentObject private var store: AppStore
    let game: Game
    let onDismiss: () -> Void

    @State private var state: HighlightState = .picking
    @State private var job: Task<Void, Never>?
    @State private var uploadMessage: String?
    @State private var retryUpload: (() -> Void)?
    @State private var footage: (Int, Int)?
    @State private var footageProgress: String?
    @State private var shareURL: ShareItem?

    private var teams: [(Int64, String, String)] { [(game.awayId, game.awayName, t("(Away)")), (game.homeId, game.homeName, t("(Home)"))] }
    private var events: [StatEvent] { store.events(game.id) }
    private var segments: [RecordingSegment] { store.segmentRows.filter { $0.gameId == game.id } }

    var body: some View {
        ScreenDialog(onDismiss: close, dismissOnScrim: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("Highlight Video")).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                    Spacer()
                    MTextButton(t("Cancel"), action: close)
                }
                switch state {
                case .picking: picker
                case .working(let label, let progress):
                    centered {
                        Text(t("Creating highlight for {target}", ["target": label])).font(Fonts.titleMedium).foregroundStyle(Theme.ink)
                        ProgressView(value: Double(progress), total: 100).tint(Theme.orange).frame(maxWidth: 320)
                        Text("\(progress)%").foregroundStyle(Theme.secondaryText)
                    }
                case .done(let label, let result):
                    centered {
                        Text(t("Highlight saved to Photos")).font(Fonts.titleMedium).foregroundStyle(Theme.ink)
                        Text(t("{target} · {count} clips · {length}", ["target": label, "count": result.clips, "length": formatClock(result.durationMs)])).foregroundStyle(Theme.secondaryText)
                        if result.skipped > 0 { Text(t("{count} clips skipped (recording not on this phone)", ["count": result.skipped])).foregroundStyle(Theme.orange) }
                        if let uploadMessage { Text(uploadMessage).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center) }
                        if let retryUpload { MOutlinedButton(t("Retry Upload"), action: retryUpload) }
                        MButton(t("Share")) { shareURL = ShareItem(url: result.file) }
                    }
                case .failed(let message):
                    centered {
                        Text(message).font(Fonts.titleMedium).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        MOutlinedButton(t("Back")) { state = .picking }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
        }
        .sheet(item: $shareURL) { ShareSheet(url: $0.url) }
        .task { if HoopSync.isSignedIn { footage = try? await VideoUpload.footageStatus(store, gameId: game.id) } }
        // The screen stays on while exporting so the export is not suspended with the app.
        .onChange(of: isWorking) { _, working in UIApplication.shared.isIdleTimerDisabled = working }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var isWorking: Bool { if case .working = state { true } else { false } }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 12) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One full-width row per team so long team names never wrap or clip.
            ForEach(teams, id: \.0) { teamId, name, side in
                MButton(t("{team} Scoring", ["team": "\(name) \(side)"]), height: 52, fullWidth: true) {
                    start(.team(teamId), label: "\(name) \(side)", key: "team:\(teamId)", tag: teamId == game.homeId ? "home" : "away")
                }.lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(teams, id: \.0) { teamId, name, side in
                        let players = rosterOrder(store.players(teamId).filter { p in events.contains { $0.playerId == p.id && !$0.reverted } })
                        if !players.isEmpty {
                            Text("\(name) \(side)").font(Fonts.titleSmall).foregroundStyle(Theme.secondaryText)
                            let rows = max(1, (players.count + 5) / 6)
                            PlayerGrid(gap: 6) { chipWidth in
                                PlayerGridCells(players: players, cellWidth: chipWidth, gap: 6) { player, width in
                                    Button { start(.player(player.id), label: player.label, key: "player:\(player.id)", tag: "p\(player.id)") } label: {
                                        Text(playerSelectionLabel(player, among: players)).font(Fonts.labelLarge).lineLimit(1).truncationMode(.tail).foregroundStyle(Theme.ink)
                                            .padding(.horizontal, 4).frame(width: width, height: 46)
                                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outline, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }
                            .frame(height: CGFloat(rows) * 46 + CGFloat(rows - 1) * 6)
                        }
                    }
                }
            }
            if HoopSync.isSignedIn {
                HStack(spacing: 12) {
                    Text(footageProgress ?? footage.map { t("Recordings in the cloud: {uploaded} of {total}", ["uploaded": $0.0, "total": $0.1]) } ?? t("Checking recordings…"))
                        .font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
                    MOutlinedButton(t("Upload Recordings"), enabled: footageProgress?.hasPrefix(t("Uploading recordings…")) != true && (footage.map { $0.0 < $0.1 } ?? false)) { uploadFootage() }
                        .lineLimit(1).fixedSize()
                }
            }
        }
    }

    private func start(_ target: HighlightTarget, label: String, key: String, tag: String) {
        let clips = highlightClips(events, segments, target)
        guard !clips.isEmpty else { state = .failed(t("No plays for this selection")); return }
        state = .working(label: label, progress: 0)
        job = Task {
            guard await requestPhotosReadAccess() else { state = .failed(HighlightError.photosDenied.localizedDescription); return }
            let (usable, skipped) = await playableClips(clips, segments)
            guard !usable.isEmpty else { state = .failed(t("None of these plays were recorded on this phone")); return }
            do {
                let name = "HoopReplay_\(game.id)_\(tag)_\(Int64(Date().timeIntervalSince1970 * 1000)).mp4"
                let result = try await exportHighlight(usable, skipped: skipped, fileName: name) { progress in
                    if case .working = state { state = .working(label: label, progress: progress) }
                }
                state = .done(label: label, result: result)
                upload(result, key: key, label: label)
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // Phase 2: a finished highlight uploads at once so the Web game page can play it.
    private func upload(_ result: HighlightResult, key: String, label: String) {
        guard HoopSync.isSignedIn else { uploadMessage = t("Sign in to share highlights on HoopReplay Web"); return }
        retryUpload = nil
        uploadMessage = t("Uploading to HoopReplay Web…")
        Task {
            do {
                try await VideoUpload.uploadHighlight(store, gameId: game.id, result: result, targetKey: key, label: label)
                uploadMessage = t("Uploaded to HoopReplay Web")
            } catch {
                uploadMessage = t("Upload failed: {message}", ["message": error.localizedDescription])
                retryUpload = { upload(result, key: key, label: label) }
            }
        }
    }

    // Phase 3: whole recordings upload so the Web can cut any highlight later.
    private func uploadFootage() {
        footageProgress = t("Uploading recordings…")
        job = Task {
            do {
                try await VideoUpload.uploadFootage(store, gameId: game.id) { sent, total in
                    footageProgress = t("Uploading recordings… {percent}%", ["percent": total > 0 ? sent * 100 / total : 0])
                }
                footageProgress = nil
            } catch is CancellationError {
            } catch {
                footageProgress = t("Upload failed: {message}", ["message": error.localizedDescription])
            }
            footage = try? await VideoUpload.footageStatus(store, gameId: game.id)
        }
    }

    private func close() { job?.cancel(); onDismiss() }
}
