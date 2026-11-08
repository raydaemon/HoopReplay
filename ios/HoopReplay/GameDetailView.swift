import SwiftUI

// Game details, the play-by-play timeline with its edit panel, and the statistics table shared by
// the detail page and the recorder's Stats popup — the same layout and rules as the Android screens.

// MARK: - Game details

struct GameDetailScreen: View {
    @EnvironmentObject private var store: AppStore
    let initialGame: Game
    let onBack: () -> Void
    let onRecord: () -> Void
    let onScore: () -> Void
    let onDeleted: () -> Void
    let onEdit: () -> Void
    let onOpenTeam: (Int64) -> Void

    @State private var deleting = false
    @State private var ending = false
    @State private var exporting = false
    @State private var highlighting = false
    @State private var selectedTeam = 0
    @State private var detailTab = 0
    @State private var immersive = false
    @State private var showColumnPicker = false
    @State private var visibleColumns = Set(statColumns.map(\.key))
    // Tapping a stat header cycles descending → ascending → back to the default roster order.
    @State private var statSortKey: String?
    @State private var statSortAscending = false
    @State private var baseOrientation: UIInterfaceOrientationMask = .portrait
    @State private var editing: StatEvent?
    @State private var shareItem: ShareItem?

    private var game: Game { store.game(initialGame.id) ?? initialGame }
    private var events: [StatEvent] { store.activeEvents(game.id) }

    private func toggleStatSort(_ key: String) {
        if statSortKey != key { statSortKey = key; statSortAscending = false }
        else if !statSortAscending { statSortAscending = true }
        else { statSortKey = nil; statSortAscending = false }
    }
    // The orientation to return to is captured when full screen is entered, and only restored if
    // full screen is still active when the screen goes away.
    private func toggleFullscreen(_ enabled: Bool) {
        if enabled && !immersive { baseOrientation = AppDelegate.supportedOrientations }
        immersive = enabled
        setStatsFullscreen(enabled, baseOrientation)
    }
    private func recalculate() { store.recalculateScore(game.id); store.recalculatePlayerGameStats(game) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !immersive { MTopAppBar(title: t("Game details")) { BackButton(action: onBack) } actions: { EmptyView() } }
                VStack(alignment: .leading, spacing: 8) {
                    if !immersive {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(game.title).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                            Text("\(formatGameDateTime(game.scheduledAt)) · \(t(game.status.titleCased))").font(Fonts.bodyMedium).foregroundStyle(Theme.orange)
                        }
                        MCard {
                            HStack(spacing: 0) {
                                TeamNameLink(name: game.homeName, font: Fonts.titleLarge) { onOpenTeam(game.homeId) }
                                Text("\(game.homeScore)  :  \(game.awayScore)").font(Fonts.headlineMedium).foregroundStyle(Theme.orange).padding(.horizontal, 20).lineLimit(1).fixedSize()
                                TeamNameLink(name: game.awayName, font: Fonts.titleLarge) { onOpenTeam(game.awayId) }
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        MTabRow(labels: [t("Statistics"), t("Play-by-Play")], selected: detailTab) { detailTab = $0 }
                    }
                    if detailTab == 0 {
                        HStack(spacing: 0) {
                            // Both tab labels are orange, so the selected one also carries a tinted background.
                            MTabRow(labels: ["\(game.homeName) \(t("(H)"))", "\(game.awayName) \(t("(A)"))"], selected: selectedTeam, tintSelected: true, selectedFont: Fonts.titleMedium, unselectedFont: Fonts.bodyMedium, unselectedColor: Theme.secondaryText) { selectedTeam = $0 }
                            if immersive {
                                MTextButton(t("Select Column")) { showColumnPicker = true }
                                MTextButton("X") { toggleFullscreen(false) }
                            }
                        }
                        if !immersive {
                            HStack {
                                Text(t("Statistics")).font(Fonts.titleSmall).foregroundStyle(Theme.ink)
                                Spacer()
                                MTextButton(t("Select columns")) { showColumnPicker = true }
                                MTextButton(t("Full screen")) { toggleFullscreen(true) }
                            }
                        }
                        StatsHeader(visibleColumns: visibleColumns, sortKey: statSortKey, sortAscending: statSortAscending, onSort: toggleStatSort)
                        TeamStats(teamId: selectedTeam == 0 ? game.homeId : game.awayId, events: events, gameId: game.id, fitScreen: true, visibleColumns: visibleColumns, sortKey: statSortKey, sortAscending: statSortAscending)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EventTimeline(game: game, events: events, onOpenTeam: onOpenTeam, editable: true, onEdit: { editing = $0 })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Five actions share the row, so the padding shrinks and the labels never wrap.
                    if !immersive {
                        HStack(spacing: 6) {
                            MButton(t("Edit"), height: 48, horizontalPadding: 4, fullWidth: true, action: onEdit).font(Fonts.labelMedium)
                            MButton(t("Delete"), container: Theme.error, height: 48, horizontalPadding: 4, fullWidth: true) { deleting = true }.font(Fonts.labelMedium)
                            MOutlinedButton(t("Export"), height: 48, horizontalPadding: 4, fullWidth: true, font: Fonts.labelMedium) { exporting = true }
                            // A game can only be finished once; afterwards the button stays visible but inert.
                            MOutlinedButton(t("End"), enabled: game.status != "COMPLETED", height: 48, horizontalPadding: 4, fullWidth: true, font: Fonts.labelMedium) { ending = true }
                            MButton(t("Score"), height: 48, horizontalPadding: 4, fullWidth: true, action: onScore)
                            MButton(t("Record"), height: 48, horizontalPadding: 4, fullWidth: true, action: onRecord)
                        }
                    }
                }
                .padding(.horizontal, immersive ? 6 : 20).padding(.vertical, 8)
            }
            .background(Theme.appBackground)
            .statusBarHidden(immersive)
            if showColumnPicker { StatColumnDialog(selected: visibleColumns, onSave: { visibleColumns = $0; showColumnPicker = false }, onDismiss: { showColumnPicker = false }) }
            if let event = editing { editPanel(event) }
            if exporting {
                // Export covers two different readings of the same game, so ask which one before writing a file.
                AlertPanel(title: t("Export game"), onDismiss: { exporting = false }) {
                    VStack(spacing: 8) {
                        Text(t("Choose what to export for {title}.", ["title": game.title])).frame(maxWidth: .infinity, alignment: .leading)
                        MButton(t("Statistics (PDF)"), fullWidth: true) { export("Statistics PDF") { try store.exportStatsPdf(game) } }
                        MButton(t("Play-by-Play (PDF)"), fullWidth: true) { export("Play-by-play PDF") { try store.exportPlaysPdf(game) } }
                        MOutlinedButton(t("Game data (JSON)"), fullWidth: true) { export("JSON") { try store.exportGameJsonFile(game) } }
                        MButton(t("Highlight Video"), fullWidth: true) { exporting = false; highlighting = true }
                    }
                } buttons: { MTextButton(t("Cancel")) { exporting = false } }
            }
            if highlighting { HighlightsDialog(game: game) { highlighting = false } }
            if ending {
                AlertPanel(title: t("End game?"), onDismiss: { ending = false }) {
                    Text(t("{game} will be marked as completed. Scores and stats stay editable.", ["game": game.title]))
                } buttons: {
                    MButton(t("Cancel")) { ending = false }
                    MButton(t("End")) { store.status(game.id, "COMPLETED"); ending = false }
                }
            }
            if deleting {
                AlertPanel(title: t("Delete Game?"), onDismiss: { deleting = false }) {
                    Text(t("This will delete scores, stats, and recording segment records for {title}. This cannot be undone.", ["title": game.title]))
                } buttons: {
                    MButton(t("Cancel")) { deleting = false }
                    MButton(t("Delete"), container: Theme.error) { store.deleteGame(game.id); deleting = false; onDeleted() }
                }
            }
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .onAppear { recalculate() }
        .onChange(of: events) { _, _ in recalculate() }
        .onDisappear { if immersive { setStatsFullscreen(false, baseOrientation) } }
    }

    private func export(_ label: String, _ run: () throws -> URL) {
        exporting = false
        do { shareItem = ShareItem(url: try run()) } catch { store.showToast(t("{label} export failed: {error}", ["label": t(label), "error": error.localizedDescription])) }
    }

    private func editPanel(_ event: StatEvent) -> some View {
        ScreenDialog(onDismiss: { editing = nil }, dismissOnScrim: false) {
            EditPlayPanel(event: event, periodDurationMs: game.periodDurationMs, periodCount: game.periodCount, roster: store.players(event.teamId), onDismiss: { editing = nil }, onDelete: { deletePlay(event) }, onSave: { playerId, period, clockMs in savePlay(event, playerId, period, clockMs) })
        }
    }
    private func deletePlay(_ event: StatEvent) {
        store.revertEvent(event.id)
        let points = eventPoints(event.type, event.value)
        if points != 0 { store.score(game, homeDelta: event.teamId == game.homeId ? -points : 0, awayDelta: event.teamId == game.awayId ? -points : 0) }
        editing = nil
    }
    private func savePlay(_ event: StatEvent, _ playerId: Int64?, _ period: Int, _ clockMs: Int64) {
        savePlayEdit(store, event, playerId, period, clockMs)
        editing = nil
    }
}

/// Saves an edited play and, for a substitution, drags its adjacent partner to the same moment:
/// a substitution is one moment recorded as two adjacent events (Sub out then Sub in).
@MainActor func savePlayEdit(_ store: AppStore, _ event: StatEvent, _ playerId: Int64?, _ period: Int, _ clockMs: Int64) {
    store.updateEvent(event.id, playerId: playerId, type: event.type, value: event.value, period: period, gameClockMs: clockMs)
    if event.type == "SUB_OUT" || event.type == "SUB_IN" {
        let all = store.events(event.gameId)
        guard let idx = all.firstIndex(where: { $0.id == event.id }) else { return }
        let candidate: StatEvent? = event.type == "SUB_OUT" ? (idx + 1 < all.count && all[idx + 1].type == "SUB_IN" ? all[idx + 1] : nil) : (idx > 0 && all[idx - 1].type == "SUB_OUT" ? all[idx - 1] : nil)
        if let partner = candidate, partner.teamId == event.teamId, !partner.reverted {
            store.updateEvent(partner.id, playerId: partner.playerId, type: partner.type, value: partner.value, period: period, gameClockMs: clockMs)
        }
    }
}

/// Full-screen statistics rotate to landscape; leaving full screen restores the orientation the
/// host screen had before, so the live screens are never flipped back to portrait.
func setStatsFullscreen(_ enabled: Bool, _ baseOrientation: UIInterfaceOrientationMask) {
    if enabled { OrientationLock.set(.landscape, preferred: .landscapeRight) }
    else { OrientationLock.set(baseOrientation, preferred: baseOrientation == .portrait ? .portrait : .landscapeRight) }
}

// MARK: - Play-by-play timeline

/// Filters offered above the timeline, mirroring the play-list design.
enum PlayFilter: String, CaseIterable { case all = "All", scoring = "Scoring", fouls = "Fouls", away = "Away", home = "Home" }

private struct TimelineRow: Identifiable { let event: StatEvent; let awayScore: Int; let homeScore: Int; let scored: Bool; var id: Int64 { event.id } }

/// One play, written as a single compact line the way a printed play-by-play reads.
struct TimelinePlayLine: View {
    let event: StatEvent
    let player: Player?
    let isHome: Bool
    let points: Int
    var identifierPrefix = "play-event-"
    var onClick: (() -> Void)? = nil
    var body: some View {
        let line = HStack(spacing: 8) {
            if !isHome { Spacer(minLength: 0) }
            if isHome { badge; name; label } else { label; name; badge }
            if isHome { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        if let onClick { Button(action: onClick) { line }.buttonStyle(.plain).accessibilityIdentifier("\(identifierPrefix)\(event.id)") } else { line }
    }
    @ViewBuilder private var badge: some View {
        if points != 0 {
            Text(points > 0 ? "+\(points)" : "\(points)").font(Fonts.labelMedium).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(points > 0 ? Theme.orange : Theme.missRed))
        }
    }
    @ViewBuilder private var name: some View {
        // A manual adjustment belongs to the team, so no "Unassigned" placeholder for it. The name
        // gives way (with an ellipsis) so the action text always stays complete.
        if event.type != "ADJ" { Text(player?.label ?? t("Unassigned")).font(Fonts.titleSmall).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail).layoutPriority(-1) }
    }
    private var label: some View {
        Text(t(eventShortLabel(event))).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
    }
}

struct EventTimeline: View {
    @EnvironmentObject private var store: AppStore
    let game: Game
    let events: [StatEvent]
    var onOpenTeam: (Int64) -> Void = { _ in }
    var editable = false
    var autoScrollToLatest = false
    var showTeamHeader = true
    var filter: PlayFilter = .all
    /// Distinguishes the popup's rows from the live screen's timeline behind it in UI tests.
    var identifierPrefix = "play-event-"
    var onEdit: (StatEvent) -> Void = { _ in }
    @State private var collapsed: Set<Int> = []

    private var players: [Int64: Player] { Dictionary(uniqueKeysWithValues: (store.players(game.homeId) + store.players(game.awayId)).map { ($0.id, $0) }) }
    private var ordered: [StatEvent] { events.sorted { ($0.period, -$0.gameClockMs, $0.id) < ($1.period, -$1.gameClockMs, $1.id) } }
    private var rows: [TimelineRow] {
        var awayScore = 0, homeScore = 0
        return ordered.map { event in
            let scored = isScoringType(event.type)
            if scored && event.teamId == game.awayId { awayScore += event.value }
            if scored && event.teamId == game.homeId { homeScore += event.value }
            return TimelineRow(event: event, awayScore: awayScore, homeScore: homeScore, scored: scored)
        }
    }
    // Filtering keeps the running score computed above, so a filtered list still shows the real score.
    private var visible: [TimelineRow] {
        rows.filter { row in
            switch filter {
            case .all: return true
            case .scoring: return row.scored
            case .fouls: return row.event.type == "FOUL" || row.event.type == "FOULED" || row.event.type.hasPrefix("FT_")
            case .away: return row.event.teamId == game.awayId
            case .home: return row.event.teamId == game.homeId
            }
        }
    }

    var body: some View {
        if ordered.isEmpty {
            Text(t("No play-by-play events yet")).font(Fonts.bodyLarge).foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let players = players
            let visible = visible
            let grouped = Dictionary(grouping: visible, by: \.event.period).sorted { $0.key < $1.key }
            VStack(spacing: 0) {
                // The live scoring screen already names both sides in its top bar, so the timeline there repeats nothing.
                if showTeamHeader {
                    HStack(spacing: 0) {
                        TeamNameLink(name: t("{team} (Away)", ["team": game.awayName]), font: Fonts.titleSmall, maxLines: 1) { onOpenTeam(game.awayId) }
                        Text(t("Time")).font(Fonts.labelSmall).foregroundStyle(Theme.orange).frame(width: 82)
                        TeamNameLink(name: t("{team} (Home)", ["team": game.homeName]), font: Fonts.titleSmall, maxLines: 1) { onOpenTeam(game.homeId) }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        // A plain stack: every row is laid out up front, so scrolling to the newest play lands exactly.
                        VStack(spacing: 0) {
                            ForEach(grouped, id: \.key) { period, periodRows in
                                // Plays are grouped by period, each group headed by its play count and closing score.
                                Button { if collapsed.contains(period) { collapsed.remove(period) } else { collapsed.insert(period) } } label: {
                                    HStack(spacing: 8) {
                                        Text(periodShortLabel(period, game.periodCount)).font(Fonts.titleSmall).foregroundStyle(Theme.ink)
                                        Text(t("{count} plays · ends {away} - {home}", ["count": periodRows.count, "away": periodRows.last!.awayScore, "home": periodRows.last!.homeScore])).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(collapsed.contains(period) ? t("Expand ▾") : t("Collapse ▴")).font(Fonts.labelMedium).foregroundStyle(Theme.orange)
                                    }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if !collapsed.contains(period) {
                                    ForEach(periodRows) { row in playRow(row, players).id(row.id) }
                                }
                            }
                        }
                    }
                    // Keep the newest play visible while scoring: the timeline is oldest-first, so a new play
                    // lands at the bottom and would otherwise stay off screen.
                    .onChange(of: visible.count, initial: true) { _, _ in
                        guard autoScrollToLatest, let last = visible.last else { return }
                        // Let the new row lay out first, otherwise the scroll lands short of the bottom.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            .background(Color.white)
        }
    }

    private func playRow(_ row: TimelineRow, _ players: [Int64: Player]) -> some View {
        let event = row.event
        let isHome = event.teamId == game.homeId
        let points = eventPoints(event.type, event.value)
        let player = event.playerId.flatMap { players[$0] }
        return HStack(spacing: 0) {
            // A thin orange edge marks which side scored, like the design's accent bar.
            Rectangle().fill(row.scored && !isHome ? Theme.orange : .clear).frame(width: 3, height: 44)
            ZStack { if !isHome { TimelinePlayLine(event: event, player: player, isHome: false, points: points, identifierPrefix: identifierPrefix, onClick: editable ? { onEdit(event) } : nil) } }.frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                Text(formatClock(event.gameClockMs)).font(Fonts.titleSmall).foregroundStyle(Theme.ink)
                if row.scored { Text("\(row.awayScore) - \(row.homeScore)").font(Fonts.labelSmall).foregroundStyle(Theme.orange) }
            }.frame(width: 82)
            ZStack { if isHome { TimelinePlayLine(event: event, player: player, isHome: true, points: points, identifierPrefix: identifierPrefix, onClick: editable ? { onEdit(event) } : nil) } }.frame(maxWidth: .infinity)
            Rectangle().fill(row.scored && isHome ? Theme.orange : .clear).frame(width: 3, height: 44)
        }
        .frame(minHeight: 44)
        .background(row.scored ? Theme.orange.opacity(0.10) : .clear)
    }
}

// MARK: - Edit play

struct EditPlayPanel: View {
    @EnvironmentObject private var store: AppStore
    let event: StatEvent
    let periodDurationMs: Int64
    let periodCount: Int
    let roster: [Player]
    let onDismiss: () -> Void
    let onDelete: () -> Void
    let onSave: (Int64?, Int, Int64) -> Void
    @State private var playerId: Int64?
    @State private var selectedPeriod: Int
    @State private var selectedMinute: Int
    @State private var selectedSecond: Int
    @State private var localRoster: [Player]
    @State private var newNumber = ""
    @State private var newFirst = ""
    @State private var newLast = ""
    @State private var activeField: String?
    @State private var confirmDelete = false

    init(event: StatEvent, periodDurationMs: Int64, periodCount: Int, roster: [Player], onDismiss: @escaping () -> Void, onDelete: @escaping () -> Void, onSave: @escaping (Int64?, Int, Int64) -> Void) {
        self.event = event; self.periodDurationMs = periodDurationMs; self.periodCount = periodCount; self.roster = roster
        self.onDismiss = onDismiss; self.onDelete = onDelete; self.onSave = onSave
        _playerId = State(initialValue: event.playerId)
        _selectedPeriod = State(initialValue: event.period)
        _selectedMinute = State(initialValue: Int(event.gameClockMs / 60000))
        _selectedSecond = State(initialValue: Int((event.gameClockMs / 1000) % 60))
        _localRoster = State(initialValue: roster)
    }

    private func apply(_ transform: (String) -> String) {
        switch activeField {
        case "number": newNumber = String(transform(newNumber).filter(\.isNumber).prefix(3))
        case "first": newFirst = String(transform(newFirst).capitalizeInitial().prefix(24))
        case "last": newLast = String(transform(newLast).capitalizeInitial().prefix(24))
        default: break
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                // Delete/Cancel/Save live in the header so the short landscape height goes to the content.
                HStack(spacing: 8) {
                    Text(t("Edit play")).font(Fonts.titleLarge).foregroundStyle(Theme.ink)
                    Text("\(periodShortLabel(event.period, periodCount))  \(formatClock(event.gameClockMs))").font(Fonts.labelLarge).foregroundStyle(Theme.orange).frame(maxWidth: .infinity, alignment: .leading)
                    MTextButton(t("Delete"), color: Theme.error) { confirmDelete = true }
                    MTextButton(t("Cancel"), action: onDismiss)
                    MButton(t("Save")) { onSave(playerId, selectedPeriod, Int64(selectedMinute) * 60000 + Int64(selectedSecond) * 1000) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // The play type shares the clock row so the short landscape height goes to the player grid.
                        let wheelMax = max(periodCount, event.period)
                        WeightedRow(weights: [1.2, 1, 1, 1]) { index, _ in
                            switch index {
                            case 0: VStack(alignment: .leading) { Text(t(eventLabel(event))).font(Fonts.bodyLarge).foregroundStyle(Theme.ink); Text(t("Game clock remaining")).font(Fonts.labelMedium).foregroundStyle(Theme.secondaryText) }
                            case 1: TimeWheelPicker(value: $selectedPeriod, min: 1, max: wheelMax, labels: (1...wheelMax).map { $0 > periodCount ? t("OT {n}", ["n": $0 - periodCount]) : t("Period {n}", ["n": $0]) })
                            case 2: TimeWheelPicker(value: $selectedMinute, min: 0, max: max(1, Int(periodDurationMs / 60000)))
                            default: TimeWheelPicker(value: $selectedSecond, min: 0, max: 59)
                            }
                        }.frame(height: 64)
                        Text(t("Player")).font(Fonts.titleSmall).foregroundStyle(Theme.ink)
                        let chipRows = max(1, (playerGridSlots(rosterOrder(localRoster)).count + 1 + 5) / 6)
                        PlayerGrid(gap: 6) { chipWidth in
                            // "Assign it later" leads the grid, like the "none" choice in the other pickers.
                            playerChip(t("Assign it later"), selected: playerId == nil, width: chipWidth) { playerId = nil }
                            PlayerGridCells(players: rosterOrder(localRoster), cellWidth: chipWidth, gap: 6) { player, width in
                                playerChip(playerId == player.id ? "✓ \(playerSelectionLabel(player, among: localRoster))" : playerSelectionLabel(player, among: localRoster), selected: playerId == player.id, width: width) { playerId = player.id }
                            }
                        }
                        .frame(height: CGFloat(chipRows) * 46 + CGFloat(chipRows - 1) * 6)
                        HStack(spacing: 6) {
                            RecorderInputField(label: t("Number"), value: newNumber, selected: activeField == "number") { activeField = "number" }.frame(maxWidth: 90)
                            RecorderInputField(label: t("First Name"), value: newFirst, selected: activeField == "first") { activeField = "first" }
                            RecorderInputField(label: t("Last Name"), value: newLast, selected: activeField == "last") { activeField = "last" }
                            MButton(t("Add player"), enabled: !newNumber.isBlank || !newFirst.isBlank || !newLast.isBlank, horizontalPadding: 14) {
                                let name = fullName(newFirst, newLast)
                                let id = store.addPlayer(event.teamId, name: name, number: newNumber.trimmed)
                                if !localRoster.contains(where: { $0.id == id }) { localRoster.append(store.player(id) ?? Player(id: id, teamId: event.teamId, name: name, number: newNumber.trimmed)) }
                                playerId = id; newFirst = ""; newLast = ""; newNumber = ""; activeField = nil
                            }
                        }
                    }
                }
                if let field = activeField {
                    RecorderKeyboard(numeric: field == "number", onKey: { key in apply { $0 + key } }, onBackspace: { apply { String($0.dropLast()) } }, onClear: { apply { _ in "" } }, onDone: { activeField = nil })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            if confirmDelete {
                AlertPanel(title: t("Delete play?"), onDismiss: { confirmDelete = false }) {
                    Text(t("This removes the play and updates the score if it was a made shot."))
                } buttons: {
                    MButton(t("Cancel")) { confirmDelete = false }
                    MButton(t("Delete"), container: Theme.error) { confirmDelete = false; onDelete() }
                }
            }
        }
    }

    private func playerChip(_ label: String, selected: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Fonts.labelLarge).lineLimit(1).truncationMode(.tail).foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .frame(width: width, height: 46)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.orange.opacity(0.2) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? .clear : Theme.outline, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - Player grid helpers (6 equal-width cells per row)

func playerGridSlots(_ players: [Player]) -> [[Player]] {
    players.map { [$0] }
}

/// A wrapping 6-column grid whose cell width follows the available width so exactly 6 fit per row.
struct PlayerGrid<Content: View>: View {
    var gap: CGFloat = 12
    var rowGap: CGFloat? = nil
    @ViewBuilder var content: (CGFloat) -> Content
    var body: some View {
        GeometryReader { proxy in
            let cellWidth = (proxy.size.width - gap * 5) / 6 - 1
            FlowLayout(spacing: gap, rowSpacing: rowGap ?? gap) { content(cellWidth) }
        }
    }
}

/// Emits one grid cell per slot; `content` draws a single player button with the width it must use.
struct PlayerGridCells<Content: View>: View {
    let players: [Player]
    let cellWidth: CGFloat
    let gap: CGFloat
    @ViewBuilder var content: (Player, CGFloat) -> Content
    var body: some View {
        ForEach(Array(playerGridSlots(players).enumerated()), id: \.offset) { _, slot in
            content(slot[0], cellWidth)
        }
    }
}

/// Compose `FlowRow`: children wrap onto new rows, left aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + rowSpacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Statistics table

struct StatColumn: Hashable { let key: String; let label: String }
let statColumns: [StatColumn] = ["MIN", "PTS", "+/-", "FGM", "FGA", "FG%", "3PM", "3PA", "3P%", "FTM", "FTA", "FT%", "OREB", "DREB", "REB", "AST", "STL", "BLK", "TO", "PF"].map { StatColumn(key: $0, label: $0) }
let statsRowHeight: CGFloat = 22

struct StatColumnDialog: View {
    let selected: Set<String>
    let onSave: (Set<String>) -> Void
    let onDismiss: () -> Void
    @State private var draft: Set<String>
    init(selected: Set<String>, onSave: @escaping (Set<String>) -> Void, onDismiss: @escaping () -> Void) {
        self.selected = selected; self.onSave = onSave; self.onDismiss = onDismiss
        _draft = State(initialValue: selected)
    }
    var body: some View {
        AlertPanel(title: t("Select columns"), onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(statColumns, id: \.key) { column in
                        Button { if draft.contains(column.key) { draft.remove(column.key) } else { draft.insert(column.key) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: draft.contains(column.key) ? "checkmark.square.fill" : "square").font(.system(size: 22)).foregroundStyle(draft.contains(column.key) ? Theme.orange : Theme.secondaryText)
                                Text(column.label).font(Fonts.bodyLarge).foregroundStyle(Theme.ink)
                                Spacer()
                            }.frame(height: 44)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 360)
        } buttons: {
            MTextButton(t("Cancel"), action: onDismiss)
            MTextButton(t("Apply"), enabled: !draft.isEmpty) { onSave(draft) }
        }
    }
}

/// One table cell with a proportional width: the text scales down to fit instead of being clipped.
struct StatCell: View {
    let value: String
    var weight: CGFloat = 1
    var alignment: Alignment = .center
    var color: Color = Theme.ink
    var fontSize: CGFloat = 9
    var totalWeight: CGFloat
    var width: CGFloat
    var onClick: (() -> Void)? = nil
    var body: some View {
        let cell = Text(value).font(.system(size: fontSize, weight: .medium)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 1)
            .frame(width: width * weight / totalWeight, alignment: alignment)
        if let onClick { Button(action: onClick) { cell }.buttonStyle(.plain) } else { cell }
    }
}

struct StatsHeader: View {
    var visibleColumns: Set<String> = Set(statColumns.map(\.key))
    var sortKey: String? = nil
    var sortAscending = false
    var onSort: ((String) -> Void)? = nil
    var body: some View {
        GeometryReader { proxy in
            let columns = statColumns.filter { visibleColumns.contains($0.key) }
            let total = 2 + CGFloat(columns.count)
            HStack(spacing: 0) {
                StatCell(value: t("Player"), weight: 2, alignment: .leading, totalWeight: total, width: proxy.size.width)
                ForEach(columns, id: \.key) { column in
                    // The active sort column carries its direction arrow right in the header label.
                    StatCell(value: column.key == sortKey ? "\(column.label)\(sortAscending ? "▲" : "▼")" : column.label, totalWeight: total, width: proxy.size.width, onClick: onSort.map { sort in { sort(column.key) } })
                }
            }
        }
        .frame(height: 20)
        .padding(.vertical, 2)
        .background(Theme.orange)
    }
}

struct TeamStats: View {
    @EnvironmentObject private var store: AppStore
    let teamId: Int64
    let events: [StatEvent]
    let gameId: Int64
    var fitScreen = false
    var contentColor: Color = Theme.ink
    var visibleColumns: Set<String> = Set(statColumns.map(\.key))
    var sortKey: String? = nil
    var sortAscending = false

    private struct Line: Identifiable { let id: Int64; let label: String; let display: [String: String]; let numeric: [String: Double] }

    private func lines() -> [Line] {
        let teamEvents = events.filter { $0.teamId == teamId && !$0.reverted }
        // Match Web: include the complete roster, even when a player has no recorded action.
        let players = rosterOrder(store.players(teamId))
        let persisted = store.playerGameStats(gameId)
        // Percentages with no attempts rank below 0% instead of above 100%.
        func percentValue(_ made: Int, _ attempts: Int) -> Double { attempts == 0 ? -1 : Double(made) * 100 / Double(attempts) }
        func line(_ id: Int64, _ label: String, _ playerEvents: [StatEvent], _ saved: (Int64, Int)?) -> Line {
            func total(_ types: String...) -> Int { playerEvents.filter { types.contains($0.type) }.reduce(0) { $0 + $1.value } }
            // Includes manual +1/-1 adjustments (team plays) so the points column adds up to the scoreboard.
            let points = playerEvents.filter { isScoringType($0.type) }.reduce(0) { $0 + $1.value }
            let (twoMade, twoAttempts, _) = fieldGoals(playerEvents, 2)
            let (threeMade, threeAttempts, threePercent) = fieldGoals(playerEvents, 3)
            let (ftMade, ftAttempts, ftPercent) = freeThrows(playerEvents)
            let fgm = twoMade + threeMade, fga = twoAttempts + threeAttempts
            let display: [String: String] = ["MIN": saved.map { formatClock($0.0) } ?? "—", "FGM": "\(fgm)", "FGA": "\(fga)", "FG%": shootingPercent(fgm, fga), "3PM": "\(threeMade)", "3PA": "\(threeAttempts)", "3P%": threePercent, "FTM": "\(ftMade)", "FTA": "\(ftAttempts)", "FT%": ftPercent, "OREB": "\(total("OREB"))", "DREB": "\(total("DREB"))", "REB": "\(total("REB"))", "AST": "\(total("AST"))", "STL": "\(total("STL"))", "BLK": "\(total("BLK"))", "TO": "\(total("TOV"))", "PF": "\(total("FOUL"))", "PTS": "\(points)", "+/-": saved.map { "\($0.1)" } ?? "—"]
            let numeric: [String: Double] = ["MIN": Double(saved?.0 ?? 0), "FGM": Double(fgm), "FGA": Double(fga), "FG%": percentValue(fgm, fga), "3PM": Double(threeMade), "3PA": Double(threeAttempts), "3P%": percentValue(threeMade, threeAttempts), "FTM": Double(ftMade), "FTA": Double(ftAttempts), "FT%": percentValue(ftMade, ftAttempts), "OREB": Double(total("OREB")), "DREB": Double(total("DREB")), "REB": Double(total("REB")), "AST": Double(total("AST")), "STL": Double(total("STL")), "BLK": Double(total("BLK")), "TO": Double(total("TOV")), "PF": Double(total("FOUL")), "PTS": Double(points), "+/-": Double(saved?.1 ?? 0)]
            return Line(id: id, label: label, display: display, numeric: numeric)
        }
        let unassigned = teamEvents.filter { $0.playerId == nil && $0.type != "VIDEO" }
        // Plays recorded with "Assign later" still belong to the team; list them so the rows add up to the total.
        return players.map { player in line(player.id, player.label, teamEvents.filter { $0.playerId == player.id }, persisted[player.id] ?? (0, 0)) } + (unassigned.isEmpty ? [] : [line(-1, t("Unassigned"), unassigned, nil)])
    }

    private func totals() -> [String: String] {
        let teamEvents = events.filter { $0.teamId == teamId && !$0.reverted }
        func teamTotal(_ type: String) -> Int { teamEvents.filter { $0.type == type }.reduce(0) { $0 + $1.value } }
        // Includes manual +1/-1 adjustments so the team total always matches the scoreboard.
        let points = teamEvents.filter { isScoringType($0.type) }.reduce(0) { $0 + $1.value }
        let (teamTwoMade, teamTwoAttempts, _) = fieldGoals(teamEvents, 2)
        let (teamThreeMade, teamThreeAttempts, teamThreePercent) = fieldGoals(teamEvents, 3)
        let (teamFtMade, teamFtAttempts, teamFtPercent) = freeThrows(teamEvents)
        let teamFgm = teamTwoMade + teamThreeMade, teamFga = teamTwoAttempts + teamThreeAttempts
        // Box-score convention: the team total is five man-minutes per elapsed game minute, not the
        // sum of the per-player attribution, which under-counts whenever the lineup was never recorded.
        let liveGame = store.game(gameId)
        let gameElapsedMs = liveGame.map { Int64(max(0, $0.currentPeriod - 1)) * $0.periodDurationMs + max(0, $0.periodDurationMs - $0.clockRemainingMs) } ?? 0
        let scoring = events.filter { !$0.reverted && isScoringType($0.type) }
        let teamPm = scoring.filter { $0.teamId == teamId }.reduce(0) { $0 + $1.value } - scoring.filter { $0.teamId != teamId }.reduce(0) { $0 + $1.value }
        return ["MIN": formatClock(gameElapsedMs * 5), "FGM": "\(teamFgm)", "FGA": "\(teamFga)", "FG%": shootingPercent(teamFgm, teamFga), "3PM": "\(teamThreeMade)", "3PA": "\(teamThreeAttempts)", "3P%": teamThreePercent, "FTM": "\(teamFtMade)", "FTA": "\(teamFtAttempts)", "FT%": teamFtPercent, "OREB": "\(teamTotal("OREB"))", "DREB": "\(teamTotal("DREB"))", "REB": "\(teamTotal("REB"))", "AST": "\(teamTotal("AST"))", "STL": "\(teamTotal("STL"))", "BLK": "\(teamTotal("BLK"))", "TO": "\(teamTotal("TOV"))", "PF": "\(teamTotal("FOUL"))", "PTS": "\(points)", "+/-": "\(teamPm)"]
    }

    var body: some View {
        let lines = lines()
        // Sorting is stable, so equal values keep the roster order as a tie-break.
        let ordered: [Line] = {
            guard let sortKey else { return lines }
            let keyed = lines.enumerated().map { ($0.offset, $0.element) }
            return keyed.sorted { a, b in
                let av = a.1.numeric[sortKey] ?? 0, bv = b.1.numeric[sortKey] ?? 0
                if av == bv { return a.0 < b.0 }
                return sortAscending ? av < bv : av > bv
            }.map(\.1)
        }()
        let columns = statColumns.filter { visibleColumns.contains($0.key) }
        let total = 2 + CGFloat(columns.count)
        let totalRow = totals()
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 0) {
                // Rows keep a fixed height that fits their text; the list scrolls instead of squeezing.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(ordered) { line in
                            HStack(spacing: 0) {
                                StatCell(value: line.label, weight: 2, alignment: .leading, color: contentColor, fontSize: 8, totalWeight: total, width: width)
                                ForEach(columns, id: \.key) { column in StatCell(value: line.display[column.key] ?? "", color: contentColor, totalWeight: total, width: width) }
                            }.frame(height: statsRowHeight)
                            Rectangle().fill(Color(hex: 0xD0D3D8)).frame(height: 1)
                        }
                        if lines.isEmpty { Text(t("No stats recorded yet.")).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText).frame(height: statsRowHeight) }
                    }
                }
                // In screen-filling tables only player rows scroll; the total remains visible at the bottom.
                HStack(spacing: 0) {
                    StatCell(value: t("Team Total"), weight: 2, alignment: .leading, color: contentColor, fontSize: 8, totalWeight: total, width: width)
                    ForEach(columns, id: \.key) { column in StatCell(value: totalRow[column.key] ?? "", color: contentColor, totalWeight: total, width: width) }
                }.frame(height: statsRowHeight).background(Color(hex: 0xE2E4E8))
            }
        }
    }
}

/// Full-screen statistics popup opened from the recorder.
struct GameStatsDialog: View {
    @EnvironmentObject private var store: AppStore
    let game: Game
    let onDismiss: () -> Void
    @State private var selectedTeam = 0
    @State private var immersive = false
    @State private var showColumnPicker = false
    @State private var visibleColumns = Set(statColumns.map(\.key))
    @State private var statSortKey: String?
    @State private var statSortAscending = false
    @State private var baseOrientation: UIInterfaceOrientationMask = .landscape
    private func toggleStatSort(_ key: String) {
        if statSortKey != key { statSortKey = key; statSortAscending = false } else if !statSortAscending { statSortAscending = true } else { statSortKey = nil; statSortAscending = false }
    }
    private func toggleFullscreen(_ enabled: Bool) {
        if enabled && !immersive { baseOrientation = AppDelegate.supportedOrientations }
        immersive = enabled
        setStatsFullscreen(enabled, baseOrientation)
    }
    var body: some View {
        let events = store.activeEvents(game.id)
        ScreenDialog(onDismiss: onDismiss, fullScreen: true) {
            VStack(spacing: 2) {
                // The close control shares the team-tab row, at the same size as the team names.
                HStack(spacing: 0) {
                    MTabRow(labels: ["\(game.homeName) \(t("(H)"))", "\(game.awayName) \(t("(A)"))"], selected: selectedTeam, tintSelected: true, selectedFont: Fonts.labelLarge, unselectedFont: Fonts.labelLarge, unselectedColor: Theme.secondaryText, height: 30) { selectedTeam = $0 }
                    MTextButton(immersive ? "X" : t("Full screen"), font: Fonts.labelSmall, minSize: 30, horizontalPadding: 8) { toggleFullscreen(!immersive) }
                    MTextButton("X", font: Fonts.labelLarge, minSize: 30, horizontalPadding: 8, action: onDismiss)
                }.frame(height: 30)
                HStack {
                    Text(t("Statistics")).font(Fonts.titleSmall).foregroundStyle(Theme.ink)
                    Spacer()
                    MTextButton(t("Select columns"), minSize: 32) { showColumnPicker = true }
                }
                StatsHeader(visibleColumns: visibleColumns, sortKey: statSortKey, sortAscending: statSortAscending, onSort: toggleStatSort)
                TeamStats(teamId: selectedTeam == 0 ? game.homeId : game.awayId, events: events, gameId: game.id, fitScreen: true, visibleColumns: visibleColumns, sortKey: statSortKey, sortAscending: statSortAscending)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .safeAreaPadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card)
            .overlay { if showColumnPicker { StatColumnDialog(selected: visibleColumns, onSave: { visibleColumns = $0; showColumnPicker = false }, onDismiss: { showColumnPicker = false }) } }
        }
        .statusBarHidden(immersive)
        .onDisappear { if immersive { setStatsFullscreen(false, baseOrientation) } }
    }
}

/// Play-by-play popup opened from the recorder's Plays button.
struct PlaysDialog: View {
    let game: Game
    let events: [StatEvent]
    let onDismiss: () -> Void
    let onEdit: (StatEvent) -> Void
    @State private var filter: PlayFilter = .all
    var body: some View {
        ScreenDialog(onDismiss: onDismiss) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(t("{count} recorded actions", ["count": events.count])).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(PlayFilter.allCases, id: \.self) { option in MFilterChip(label: t(option.rawValue), selected: filter == option) { filter = option } }
                    MTextButton("×", font: Fonts.headlineSmall, minSize: 48, action: onDismiss)
                }
                EventTimeline(game: game, events: events, editable: true, autoScrollToLatest: true, filter: filter, identifierPrefix: "dialog-play-event-", onEdit: onEdit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
        }
    }
}
