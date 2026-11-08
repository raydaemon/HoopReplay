import Foundation
import UIKit

// Game export/import and the two PDF reports, laid out exactly like the Android exports so a file
// from either platform reads the same. iOS hands the finished file to the share sheet, the
// platform's counterpart of Android's Downloads/HoopReplay folder.

enum GamePortabilityError: LocalizedError {
    case notAGameExport, unreadable
    var errorDescription: String? {
        switch self {
        case .notAGameExport: return t("Not a HoopReplay game export")
        case .unreadable: return t("The file could not be read")
        }
    }
}

/// Keeps a team name usable in a file name: every non-alphanumeric character is dropped.
private func fileNamePart(_ name: String) -> String {
    let cleaned = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map { Character($0) }
    return cleaned.isEmpty ? "Team" : String(cleaned)
}

/// Exports share one name: HoopReplay-Home-Away-yyyyMMdd-HHmmss.<extension>.
func exportFileName(_ game: Game, _ ext: String) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "HoopReplay-\(fileNamePart(game.homeName))-\(fileNamePart(game.awayName))-\(formatter.string(from: Date())).\(ext)"
}

private func exportURL(_ game: Game, _ ext: String) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HoopReplay", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(exportFileName(game, ext))
}

extension AppStore {
    /// Serializes one game so it can be re-imported on another device or as a new game.
    func exportGameJson(_ game: Game) -> [String: Any] {
        func roster(_ teamId: Int64) -> [[String: Any]] { players(teamId).map { ["number": $0.number, "name": $0.name] } }
        let byId = Dictionary(uniqueKeysWithValues: (players(game.homeId) + players(game.awayId)).map { ($0.id, $0) })
        return [
            "kind": gameExportKind,
            "schemaVersion": 1,
            "exportedAt": nowMs(),
            "game": [
                "title": game.title, "status": game.status, "scheduledAt": game.scheduledAt, "videoQuality": game.videoQuality,
                "periodCount": game.periodCount, "periodDurationMs": game.periodDurationMs,
                "currentPeriod": game.currentPeriod, "clockRemainingMs": game.clockRemainingMs,
                "homeScore": game.homeScore, "awayScore": game.awayScore,
            ] as [String: Any],
            "home": ["name": game.homeName, "players": roster(game.homeId)] as [String: Any],
            "away": ["name": game.awayName, "players": roster(game.awayId)] as [String: Any],
            "events": events(game.id).map { event -> [String: Any] in
                let player = event.playerId.flatMap { byId[$0] }
                return [
                    "side": event.teamId == game.homeId ? "HOME" : "AWAY",
                    "playerNumber": player?.number ?? "", "playerName": player?.name ?? "",
                    "type": event.type, "value": event.value,
                    "period": event.period, "gameClockMs": event.gameClockMs,
                    "segment": event.segment, "segmentTimeMs": event.segmentTimeMs, "finalVideoTimeMs": event.finalVideoTimeMs,
                    "reverted": event.reverted,
                ]
            },
        ]
    }

    func exportGameJsonFile(_ game: Game) throws -> URL {
        let url = exportURL(game, "json")
        try JSONSerialization.data(withJSONObject: exportGameJson(game), options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return url
    }

    /**
     Recreates an exported game as a new game. Teams are matched by name and players by jersey number
     (falling back to name for unnumbered players); anything missing is created. Video timestamps are
     dropped because the imported stats do not belong to the new game's recording.
     */
    @discardableResult
    func importGameJson(_ snapshot: [String: Any]) throws -> GameImport {
        guard snapshot["kind"] as? String == gameExportKind else { throw GamePortabilityError.notAGameExport }
        let meta = snapshot["game"] as? [String: Any] ?? [:]
        var createdTeams = 0
        var createdPlayers = 0
        func number(_ dict: [String: Any], _ key: String, _ fallback: Int64) -> Int64 { (dict[key] as? NSNumber)?.int64Value ?? fallback }
        func text(_ dict: [String: Any], _ key: String) -> String { (dict[key] as? String ?? "").trimmed }
        func resolveTeam(_ side: [String: Any]) -> Int64 {
            let rawName = text(side, "name")
            let name = (rawName.isEmpty ? "Unnamed" : rawName).capitalizeInitial()
            let teamId: Int64
            if let existing = teams().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { teamId = existing.id }
            else { teamId = addTeam(name); createdTeams += 1 }
            for entry in side["players"] as? [[String: Any]] ?? [] {
                let number = text(entry, "number"), playerName = text(entry, "name")
                if number.isEmpty && playerName.isEmpty { continue }
                if findPlayer(teamId, name: playerName, number: number) == nil { addPlayer(teamId, name: playerName, number: number); createdPlayers += 1 }
            }
            return teamId
        }
        let homeId = resolveTeam(snapshot["home"] as? [String: Any] ?? [:])
        let awayId = resolveTeam(snapshot["away"] as? [String: Any] ?? [:])
        let periodDurationMs = number(meta, "periodDurationMs", 480_000)
        let title = text(meta, "title")
        let quality = text(meta, "videoQuality")
        let gameId = addGame(title: title.isEmpty ? "Imported game" : title, home: homeId, away: awayId, scheduledAt: number(meta, "scheduledAt", nowMs()), videoQuality: quality.isEmpty ? "HIGHEST" : quality, periodCount: Int(number(meta, "periodCount", 4)), periodDurationMs: periodDurationMs)
        let status = text(meta, "status")
        updateImportedGame(gameId, homeScore: Int(number(meta, "homeScore", 0)), awayScore: Int(number(meta, "awayScore", 0)), status: status.isEmpty ? "READY" : status, currentPeriod: Int(number(meta, "currentPeriod", 1)), clockRemainingMs: number(meta, "clockRemainingMs", periodDurationMs))
        var importedEvents = 0
        for event in snapshot["events"] as? [[String: Any]] ?? [] {
            let teamId = (event["side"] as? String) == "AWAY" ? awayId : homeId
            let jersey = text(event, "playerNumber"), playerName = text(event, "playerName")
            var playerId: Int64?
            if !(jersey.isEmpty && playerName.isEmpty) {
                if let existing = findPlayer(teamId, name: playerName, number: jersey) { playerId = existing.id }
                else { playerId = addPlayer(teamId, name: playerName, number: jersey); createdPlayers += 1 }
            }
            let reverted = (event["reverted"] as? Bool) ?? (((event["reverted"] as? NSNumber)?.intValue ?? 0) != 0)
            let id = addEvent(gameId: gameId, teamId: teamId, playerId: playerId, type: event["type"] as? String ?? "", value: Int(number(event, "value", 0)), period: Int(number(event, "period", 1)), clock: number(event, "gameClockMs", 0), segment: 0, segmentMs: 0, videoMs: 0)
            if reverted { revertEvent(id) }
            importedEvents += 1
        }
        return GameImport(gameId: gameId, events: importedEvents, createdTeams: createdTeams, createdPlayers: createdPlayers)
    }

    func importGameJsonFile(_ url: URL) throws -> GameImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GamePortabilityError.unreadable }
        return try importGameJson(snapshot)
    }

    // MARK: - PDF exports

    private struct PdfStatRow { let player: String; let pts, twoMade, twoAttempts, threeMade, threeAttempts, ftMade, ftAttempts, reb, ast, stl, blk, tov, pf: Int }

    private func pdfStatRows(_ teamId: Int64, _ events: [StatEvent]) -> [PdfStatRow] {
        let teamEvents = events.filter { $0.teamId == teamId }
        func row(_ label: String, _ playerEvents: [StatEvent]) -> PdfStatRow {
            let (twoMade, twoAttempts, _) = fieldGoals(playerEvents, 2)
            let (threeMade, threeAttempts, _) = fieldGoals(playerEvents, 3)
            let (ftMade, ftAttempts, _) = freeThrows(playerEvents)
            func total(_ type: String) -> Int { playerEvents.filter { $0.type == type }.reduce(0) { $0 + $1.value } }
            return PdfStatRow(player: label, pts: playerEvents.filter { isScoringType($0.type) }.reduce(0) { $0 + $1.value }, twoMade: twoMade, twoAttempts: twoAttempts, threeMade: threeMade, threeAttempts: threeAttempts, ftMade: ftMade, ftAttempts: ftAttempts, reb: total("REB"), ast: total("AST"), stl: total("STL"), blk: total("BLK"), tov: total("TOV"), pf: total("FOUL"))
        }
        let unassigned = teamEvents.filter { $0.playerId == nil && $0.type != "VIDEO" }
        // Plays recorded with "Assign later" still belong to the team; list them so the rows add up to the total.
        return players(teamId).map { player in row(player.label, teamEvents.filter { $0.playerId == player.id }) } + (unassigned.isEmpty ? [] : [row(t("Unassigned"), unassigned)])
    }

    /// Draws text the way Android's Canvas.drawText does: `y` is the baseline.
    private func draw(_ text: String, x: CGFloat, baseline y: CGFloat, size: CGFloat, bold: Bool = false, color: UIColor, align: NSTextAlignment = .left) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        let originX = align == .left ? x : align == .center ? x - width / 2 : x - width
        (text as NSString).draw(at: CGPoint(x: originX, y: y - font.ascender), withAttributes: attributes)
    }
    private func fill(_ rect: CGRect, _ color: UIColor) { color.setFill(); UIBezierPath(rect: rect).fill() }
    private func drawLogo(_ left: CGFloat, _ top: CGFloat, _ size: CGFloat) {
        UIImage(named: "AppIcon")?.draw(in: CGRect(x: left, y: top, width: size, height: size))
    }
    private var orange: UIColor { UIColor(red: 1, green: 107 / 255, blue: 0, alpha: 1) }
    private var dark: UIColor { UIColor(red: 22 / 255, green: 24 / 255, blue: 29 / 255, alpha: 1) }

    /// Statistics export uses US Letter in landscape (792x612) and stacks both teams on one page.
    func exportStatsPdf(_ game: Game) throws -> URL {
        let events = activeEvents(game.id)
        let url = exportURL(game, "pdf")
        let pageWidth: CGFloat = 792, pageHeight: CGFloat = 612, leftEdge: CGFloat = 32, rightEdge: CGFloat = 760
        let xs: [CGFloat] = [36, 205, 239, 273, 307, 341, 375, 409, 443, 477, 511, 545, 579, 613, 647, 681, 715]
        let rowHeight: CGFloat = 15
        let sharedPageRows = 12
        func drawTeamBlock(_ top: CGFloat, _ teamName: String, _ rows: [PdfStatRow], _ partLabel: String, _ withTotal: Bool) -> CGFloat {
            draw(partLabel.isEmpty ? teamName : "\(teamName) \(partLabel)", x: 36, baseline: top, size: 15, bold: true, color: orange)
            fill(CGRect(x: leftEdge, y: top + 8, width: rightEdge - leftEdge, height: 22), UIColor(red: 45 / 255, green: 48 / 255, blue: 54 / 255, alpha: 1))
            for (i, label) in [t("Player"), "PTS", "2PM", "2PA", "2P%", "3PM", "3PA", "3P%", "FTM", "FTA", "FT%", "REB", "AST", "STL", "BLK", "TOV", "PF"].enumerated() { draw(label, x: xs[i], baseline: top + 24, size: 10, color: .white) }
            var y = top + 45
            for (index, row) in rows.enumerated() {
                if index % 2 == 1 { fill(CGRect(x: leftEdge, y: y - 11, width: rightEdge - leftEdge, height: 15), UIColor(red: 242 / 255, green: 243 / 255, blue: 245 / 255, alpha: 1)) }
                let values = [row.player, "\(row.pts)", "\(row.twoMade)", "\(row.twoAttempts)", shootingPercent(row.twoMade, row.twoAttempts), "\(row.threeMade)", "\(row.threeAttempts)", shootingPercent(row.threeMade, row.threeAttempts), "\(row.ftMade)", "\(row.ftAttempts)", shootingPercent(row.ftMade, row.ftAttempts), "\(row.reb)", "\(row.ast)", "\(row.stl)", "\(row.blk)", "\(row.tov)", "\(row.pf)"]
                for (i, value) in values.enumerated() { draw(String(value.prefix(i == 0 ? 24 : 4)), x: xs[i], baseline: y, size: 10, color: UIColor(red: 30 / 255, green: 32 / 255, blue: 36 / 255, alpha: 1)) }
                y += rowHeight
            }
            if withTotal {
                let twoMade = rows.reduce(0) { $0 + $1.twoMade }, twoAttempts = rows.reduce(0) { $0 + $1.twoAttempts }
                let threeMade = rows.reduce(0) { $0 + $1.threeMade }, threeAttempts = rows.reduce(0) { $0 + $1.threeAttempts }
                let ftMade = rows.reduce(0) { $0 + $1.ftMade }, ftAttempts = rows.reduce(0) { $0 + $1.ftAttempts }
                let values = [t("Team Total"), "\(rows.reduce(0) { $0 + $1.pts })", "\(twoMade)", "\(twoAttempts)", shootingPercent(twoMade, twoAttempts), "\(threeMade)", "\(threeAttempts)", shootingPercent(threeMade, threeAttempts), "\(ftMade)", "\(ftAttempts)", shootingPercent(ftMade, ftAttempts), "\(rows.reduce(0) { $0 + $1.reb })", "\(rows.reduce(0) { $0 + $1.ast })", "\(rows.reduce(0) { $0 + $1.stl })", "\(rows.reduce(0) { $0 + $1.blk })", "\(rows.reduce(0) { $0 + $1.tov })", "\(rows.reduce(0) { $0 + $1.pf })"]
                for (i, value) in values.enumerated() { draw(value, x: xs[i], baseline: y + 3, size: 10, bold: true, color: orange) }
                y += rowHeight + 3
            }
            return y
        }
        func drawHeader() {
            drawLogo(36, 24, 48)
            let textLeft: CGFloat = 96
            draw(t("HoopReplay Game Statistics"), x: textLeft, baseline: 42, size: 22, bold: true, color: dark)
            draw("\(game.title)  |  \(formatGameDateTime(game.scheduledAt))", x: textLeft, baseline: 63, size: 11, color: .darkGray)
            draw("\(game.homeName) \(game.homeScore) - \(game.awayScore) \(game.awayName)", x: textLeft, baseline: 80, size: 11, color: .darkGray)
        }
        func drawFooter() { draw(t("Generated by HoopReplay"), x: 36, baseline: pageHeight - 22, size: 9, color: .gray) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let teams = [(game.homeName, pdfStatRows(game.homeId, events)), (game.awayName, pdfStatRows(game.awayId, events))]
        let data = renderer.pdfData { context in
            context.beginPage()
            drawHeader()
            var y: CGFloat = 112
            var overflow: [(String, [PdfStatRow])] = []
            for (name, rows) in teams {
                let onThisPage = Array(rows.prefix(sharedPageRows))
                let rest = Array(rows.dropFirst(sharedPageRows))
                let label = rest.isEmpty ? "" : t("(1/{total})", ["total": (rows.count + sharedPageRows - 1) / sharedPageRows])
                y = drawTeamBlock(y, name, onThisPage, label, rest.isEmpty) + 26
                if !rest.isEmpty { overflow.append((name, rest)) }
            }
            drawFooter()
            // Only a roster longer than the shared page needs extra pages; both teams stay together otherwise.
            for (name, rest) in overflow {
                let chunks = stride(from: 0, to: rest.count, by: 24).map { Array(rest[$0..<min($0 + 24, rest.count)]) }
                for (index, chunk) in chunks.enumerated() {
                    context.beginPage()
                    drawHeader()
                    _ = drawTeamBlock(112, name, chunk, t("(continued {page})", ["page": index + 2]), index == chunks.count - 1)
                    drawFooter()
                }
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private struct PdfPlayRow { let period: Int; let clock, team, player, play, score: String; let scored: Bool }

    private func pdfPlayRows(_ game: Game, _ events: [StatEvent]) -> [PdfPlayRow] {
        let byId = Dictionary(uniqueKeysWithValues: (players(game.homeId) + players(game.awayId)).map { ($0.id, $0) })
        let ordered = events.sorted { ($0.period, -$0.gameClockMs, $0.id) < ($1.period, -$1.gameClockMs, $1.id) }
        var homeScore = 0, awayScore = 0
        return ordered.map { event in
            let scored = isScoringType(event.type)
            if scored && event.teamId == game.homeId { homeScore += event.value }
            if scored && event.teamId == game.awayId { awayScore += event.value }
            return PdfPlayRow(period: event.period, clock: formatClock(event.gameClockMs), team: event.teamId == game.homeId ? game.homeName : game.awayName, player: event.type == "ADJ" ? "" : (event.playerId.flatMap { byId[$0] }?.label ?? t("Unassigned")), play: t(eventLabel(event)), score: "\(awayScore) - \(homeScore)", scored: scored)
        }
    }

    /// Play-by-play export mirrors the on-screen timeline: the clock runs down the middle, the away
    /// team is on the left and the home team on the right, so the PDF reads like the app.
    func exportPlaysPdf(_ game: Game) throws -> URL {
        let rows = pdfPlayRows(game, activeEvents(game.id))
        let url = exportURL(game, "pdf")
        let awayColumnRight: CGFloat = 372, centerLeft: CGFloat = 384, centerRight: CGFloat = 458, homeColumnLeft: CGFloat = 470
        let gray = UIColor(red: 90 / 255, green: 94 / 255, blue: 100 / 255, alpha: 1)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 595))
        let pages: [[PdfPlayRow]] = rows.isEmpty ? [[]] : stride(from: 0, to: rows.count, by: 11).map { Array(rows[$0..<min($0 + 11, rows.count)]) }
        let data = renderer.pdfData { context in
            for (partIndex, pageRows) in pages.enumerated() {
                context.beginPage()
                drawLogo(36, 26, 52)
                let headerTextLeft: CGFloat = 100
                draw(t("HoopReplay Play-by-Play"), x: headerTextLeft, baseline: 44, size: 24, bold: true, color: dark)
                draw("\(game.title)  |  \(formatGameDateTime(game.scheduledAt))", x: headerTextLeft, baseline: 70, size: 13, color: .darkGray)
                draw("\(game.homeName) \(game.homeScore) - \(game.awayScore) \(game.awayName)", x: headerTextLeft, baseline: 91, size: 13, color: .darkGray)
                // Column headers name the side each half of the page belongs to, like the app's timeline.
                draw(String(t("{team} (Away)", ["team": game.awayName]).prefix(46)), x: (36 + awayColumnRight) / 2, baseline: 123, size: 12, bold: true, color: orange, align: .center)
                draw(pages.count > 1 ? t("Time ({page}/{total})", ["page": partIndex + 1, "total": pages.count]) : t("Time"), x: (centerLeft + centerRight) / 2, baseline: 123, size: 12, bold: true, color: orange, align: .center)
                draw(String(t("{team} (Home)", ["team": game.homeName]).prefix(46)), x: (homeColumnLeft + 806) / 2, baseline: 123, size: 12, bold: true, color: orange, align: .center)
                fill(CGRect(x: 32, y: 132, width: 778, height: 1), UIColor(red: 220 / 255, green: 222 / 255, blue: 226 / 255, alpha: 1))
                var y: CGFloat = 160
                for row in pageRows {
                    let isHome = row.team == game.homeName
                    if row.scored { fill(CGRect(x: 32, y: y - 18, width: 778, height: 40), UIColor(red: 248 / 255, green: 249 / 255, blue: 250 / 255, alpha: 1)) }
                    // The clock column stays centered between the two sides.
                    draw(periodShortLabel(row.period, game.periodCount), x: (centerLeft + centerRight) / 2, baseline: y - 6, size: 10, bold: true, color: orange, align: .center)
                    draw(row.clock, x: (centerLeft + centerRight) / 2, baseline: y + 12, size: 14, bold: true, color: dark, align: .center)
                    if row.scored { draw(row.score, x: (centerLeft + centerRight) / 2, baseline: y + 26, size: 10, color: gray, align: .center) }
                    // Away plays hug the middle from the left, home plays from the right.
                    let x = isHome ? homeColumnLeft : awayColumnRight
                    let align: NSTextAlignment = isHome ? .left : .right
                    draw(String(row.player.prefix(34)), x: x, baseline: y - 2, size: 12, bold: true, color: dark, align: align)
                    draw(String(row.play.prefix(38)), x: x, baseline: y + 14, size: 11, color: gray, align: align)
                    y += 40
                }
                draw(t("Generated by HoopReplay"), x: 36, baseline: 570, size: 9, color: .gray)
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
