import SwiftUI
import UIKit

// Popups and widgets of the landscape recorder, one for one with the Android composables: the
// in-app keyboard (the system keyboard never opens in landscape), the 0-99 number pad, the player
// pickers with their 6-per-row grid, the lineup/substitution toggle list, the free-throw trip, the
// rebound tabs, the Period/Time wheels, and the full-screen roster panel.

// MARK: - In-app input

/// Tappable field that shows its label until it holds a value; input comes from `RecorderKeyboard`.
struct RecorderInputField: View {
    let label: String
    let value: String
    let selected: Bool
    var height: CGFloat = 54
    var hideLabelWhenFilled = false
    var identifier = ""
    let onClick: () -> Void
    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                if value.isBlank {
                    Text(label).font(Fonts.bodyMedium).foregroundStyle(selected ? Theme.orange : Color(hex: 0x9298A1)).lineLimit(1)
                } else {
                    // A filled field speaks for itself; the caption only crowds a compact row.
                    if !hideLabelWhenFilled { Text(label).font(Fonts.labelSmall).foregroundStyle(selected ? Theme.orange : Theme.secondaryText) }
                    Text(value).font(Fonts.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.orange : Color(hex: 0x777D86), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// Application-controlled keyboard so the system IME is never summoned on the landscape screens.
struct RecorderKeyboard: View {
    let numeric: Bool
    var numericThreeByThree = false
    let onKey: (String) -> Void
    let onBackspace: () -> Void
    let onClear: () -> Void
    let onDone: () -> Void
    // Shift behaves like a phone keyboard: capital for the first letter of each word, lowercase after,
    // until the user pins a case with the ABC/abc key.
    @State private var autoUppercase = true
    @State private var pinned: Bool?
    private var uppercase: Bool { pinned ?? autoUppercase }
    private var rows: [[String]] {
        if numeric { return numericThreeByThree ? [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["0"]] : [["1", "2", "3", "4", "5"], ["6", "7", "8", "9", "0"]] }
        return [["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], ["A", "S", "D", "F", "G", "H", "J", "K", "L"], ["Z", "X", "C", "V", "B", "N", "M", "-", "'"]]
    }
    private var keyHeight: CGFloat { numeric ? 44 : 30 }
    private var keyFont: Font { numeric ? Fonts.titleLarge : Fonts.labelSmall }
    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, keys in
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { key in
                        MOutlinedButton(uppercase ? key : key.lowercased(), container: .white, content: Theme.ink, height: keyHeight, horizontalPadding: 0, fullWidth: true, font: keyFont) {
                            onKey(uppercase ? key : key.lowercased()); if pinned == nil { autoUppercase = false }
                        }
                    }
                }
            }
            WeightedRow(weights: numeric ? [1.2, 1] : [2.5, 1, 1.2, 1], spacing: 6) { index, _ in
                if numeric {
                    if index == 0 { MOutlinedButton(t("Delete"), content: Theme.orange, height: 40, horizontalPadding: 0, fullWidth: true, font: Fonts.titleMedium, action: onBackspace) }
                    else { MButton(t("Done"), height: 40, horizontalPadding: 4, fullWidth: true, action: onDone).font(Fonts.titleMedium).accessibilityIdentifier("keyboard-done") }
                } else {
                    switch index {
                    case 0: MOutlinedButton(t("Space"), container: .white, content: Theme.ink, height: 30, horizontalPadding: 0, fullWidth: true, font: Fonts.labelSmall) { onKey(" "); if pinned == nil { autoUppercase = true } }
                    case 1: MOutlinedButton(uppercase ? "ABC" : "abc", content: Theme.orange, height: 30, horizontalPadding: 0, fullWidth: true, font: Fonts.labelSmall) { pinned = !uppercase }
                    case 2: MOutlinedButton(t("Delete"), content: Theme.orange, height: 30, horizontalPadding: 0, fullWidth: true, font: Fonts.labelSmall, action: onBackspace)
                    default: MButton(t("Done"), height: 30, horizontalPadding: 4, fullWidth: true, action: onDone).font(Fonts.labelSmall).accessibilityIdentifier("keyboard-done")
                    }
                }
            }.frame(height: numeric ? 40 : 30)
        }
        .padding(4)
        .background(Theme.keyboard, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Number wheel (Android `NumberPicker`) with optional display labels.
struct TimeWheelPicker: UIViewRepresentable {
    @Binding var value: Int
    let min: Int
    let max: Int
    var labels: [String]? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return picker
    }
    func updateUIView(_ picker: UIPickerView, context: Context) {
        let reload = context.coordinator.parent.min != min || context.coordinator.parent.max != max || context.coordinator.parent.labels != labels
        context.coordinator.parent = self
        if reload { picker.reloadAllComponents() }
        let row = value - min
        if row >= 0 && row <= max - min && picker.selectedRow(inComponent: 0) != row { picker.selectRow(row, inComponent: 0, animated: false) }
    }
    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: TimeWheelPicker
        init(_ parent: TimeWheelPicker) { self.parent = parent }
        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { Swift.max(0, parent.max - parent.min + 1) }
        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { 30 }
        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = (view as? UILabel) ?? UILabel()
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 18)
            label.adjustsFontSizeToFitWidth = true
            label.text = parent.labels.flatMap { row < $0.count ? $0[row] : nil } ?? String(parent.min + row)
            return label
        }
        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) { parent.value = parent.min + row }
    }
}

// MARK: - Period / clock editor

struct ClockEditorDialog: View {
    let initialMs: Int64
    let maxMs: Int64
    let initialPeriod: Int
    let periodCount: Int
    let onDismiss: () -> Void
    let onConfirm: (Int, Int64) -> Void
    @State private var selectedPeriod: Int
    @State private var selectedMinute: Int
    @State private var selectedSecond: Int
    init(initialMs: Int64, maxMs: Int64, initialPeriod: Int, periodCount: Int, onDismiss: @escaping () -> Void, onConfirm: @escaping (Int, Int64) -> Void) {
        self.initialMs = initialMs; self.maxMs = maxMs; self.initialPeriod = initialPeriod; self.periodCount = periodCount; self.onDismiss = onDismiss; self.onConfirm = onConfirm
        _selectedPeriod = State(initialValue: initialPeriod)
        _selectedMinute = State(initialValue: Int(initialMs / 60000))
        _selectedSecond = State(initialValue: Int((initialMs / 1000) % 60))
    }
    private var valueMs: Int64 { (Int64(selectedMinute) * 60 + Int64(selectedSecond)) * 1000 }
    var body: some View {
        // The wheel reaches one period past the current one, so overtime periods stay selectable.
        let wheelMax = max(periodCount, initialPeriod + 1)
        ScreenDialog(onDismiss: onDismiss) {
            // Wheels-only editor: no titles or preview, just the pickers and Cancel/Save at the top right.
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Spacer()
                    MTextButton(t("Cancel"), action: onDismiss)
                    MButton(t("Save"), enabled: valueMs <= maxMs, horizontalPadding: 20) { onConfirm(selectedPeriod, valueMs) }
                }
                // A full button-height of air between the actions and the wheels, so a flick on a
                // wheel cannot end on Cancel or Save.
                Spacer().frame(height: 8)
                HStack(spacing: 8) {
                    TimeWheelPicker(value: $selectedPeriod, min: 1, max: wheelMax, labels: (1...wheelMax).map { $0 > periodCount ? t("OT {n}", ["n": $0 - periodCount]) : t("Period {n}", ["n": $0]) })
                        .onChange(of: selectedPeriod) { _, period in
                            // Moving to another period starts it fresh, so the clock snaps to the full
                            // duration; wheeling back to the current period restores its remaining time.
                            let resetMs = period == initialPeriod ? initialMs : maxMs
                            selectedMinute = Int(resetMs / 60000); selectedSecond = Int((resetMs / 1000) % 60)
                        }
                    TimeWheelPicker(value: $selectedMinute, min: 0, max: max(1, Int(maxMs / 60000)))
                    TimeWheelPicker(value: $selectedSecond, min: 0, max: 59)
                }.frame(height: 76)
            }
            .padding(20)
            .frame(maxWidth: 620)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Flow models

struct PlayerAction: Equatable { let teamId: Int64; let type: String; let value: Int; var points = 0; var needsAssist = false; var needsRebound = false }
struct FreeThrowFlow: Equatable { let teamId: Int64; var player: Player? = nil; var playerSkipped = false; var format = ""; var total = 2; var results: [Bool?] = [] }
struct FoulFlow: Equatable { let teamId: Int64; var player: Player? = nil; var playerSkipped = false }

// MARK: - Free throws

struct FreeThrowDialog: View {
    let flow: FreeThrowFlow
    let onUpdate: (FreeThrowFlow) -> Void
    let onSave: ([Bool]) -> Void
    let onDismiss: () -> Void
    var onBack: (() -> Void)? = nil

    // 1+1: the second shot only exists once the first one is made.
    private var oneAndOne: Bool { flow.format == "1+1" }
    private var shots: Int { oneAndOne ? ((flow.results.first ?? nil) == true ? 2 : 1) : flow.total }
    private var shooterChosen: Bool { flow.player != nil || flow.playerSkipped }
    private var complete: Bool { shooterChosen && flow.results.count >= shots && (0..<shots).allSatisfy { index in index < flow.results.count && flow.results[index] != nil } }
    private var recorded: [Bool] { flow.results.prefix(shots).compactMap { $0 } }
    private func record(_ index: Int, _ made: Bool) {
        var next = flow.results
        while next.count <= index { next.append(nil) }
        next[index] = made
        // A missed first shot in a 1+1 ends the trip; drop anything recorded for the bonus shot.
        var updated = flow; updated.results = (oneAndOne && index == 0 && !made) ? Array(next.prefix(1)) : next
        onUpdate(updated)
    }

    var body: some View {
        ScreenDialog(onDismiss: onDismiss) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.player?.label ?? (flow.playerSkipped ? t("Shooter: assign later") : t("Select shooter"))).font(Fonts.titleLarge).foregroundStyle(Theme.ink)
                        if shooterChosen { Text(oneAndOne ? t("Shooting foul · 1+1 bonus") : t("Shooting foul · {count} free throws", ["count": flow.total])).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let onBack { MTextButton(t("Previous"), action: onBack) }
                    MTextButton(t("Cancel"), action: onDismiss)
                    MButton(t("Next"), enabled: complete) { onSave(recorded) }
                }
                if shooterChosen {
                    Text(t("Number of free throws")).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach([("1 FT", "", 1), ("2 FTs", "", 2), ("3 FTs", "", 3), ("1+1", "1+1", 2)], id: \.0) { label, format, count in
                            let selected = flow.format == format && (format == "1+1" || flow.total == count)
                            MButton(t(label), container: selected ? Theme.orange : .gray, fullWidth: true) { var updated = flow; updated.format = format; updated.total = count; updated.results = []; onUpdate(updated) }
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<shots, id: \.self) { index in
                            let result: Bool? = index < flow.results.count ? flow.results[index] : nil
                            VStack(spacing: 5) {
                                Text(oneAndOne && index == 1 ? t("Bonus FT") : t("FT {n}", ["n": index + 1])).font(Fonts.bodyLarge).foregroundStyle(Theme.ink)
                                MButton(t("Miss"), container: result == false ? Theme.missRed : .gray, fullWidth: true) { record(index, false) }
                                MButton(t("Made +1"), container: result == true ? Theme.orange : .gray, fullWidth: true) { record(index, true) }
                            }.frame(maxWidth: .infinity)
                        }
                        ForEach(0..<max(0, (oneAndOne ? 2 : 3) - shots), id: \.self) { _ in Spacer().frame(maxWidth: .infinity) }
                    }
                    if oneAndOne && (flow.results.first ?? nil) == false { Text(t("Missed the first shot — the 1+1 is over")).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading) }
                    Text("\(t("Points from free throws"))  \(flow.results.prefix(shots).filter { $0 == true }.count)").font(Fonts.bodyLarge).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The trip is over as soon as the last attempt is recorded: a made last shot saves and closes,
        // a missed one hands off to the rebound dialog, so neither needs a separate confirmation tap.
        .onChange(of: flow) { _, _ in if complete { onSave(recorded) } }
    }
}

// MARK: - Lineup / substitution toggle list

struct StarterSelectionDialog: View {
    @EnvironmentObject private var store: AppStore
    let teamId: Int64
    let players: [Player]
    let initial: Set<Int64>
    let onConfirm: (Set<Int64>) -> Void
    let onDismiss: () -> Void
    var title = "Set Starting Lineup"
    var hint = "Tap players to switch starters and substitutes"
    var selectedLabel = "Starter"
    var unselectedLabel = "Substitute"
    var confirmLabel = "Confirm"
    @State private var selected: Set<Int64> = []
    @State private var localPlayers: [Player] = []
    @State private var otherNumber = ""
    @State private var otherFirstName = ""
    @State private var otherLastName = ""
    @State private var activeField: String?
    private func updateActive(_ transform: (String) -> String) {
        switch activeField {
        case "number": otherNumber = String(transform(otherNumber).filter(\.isNumber).prefix(3))
        case "last": otherLastName = String(transform(otherLastName).capitalizeInitial().prefix(24))
        case "first": otherFirstName = String(transform(otherFirstName).capitalizeInitial().prefix(24))
        default: break
        }
    }
    var body: some View {
        let rows = stride(from: 0, to: rosterOrder(localPlayers).count, by: 6).map { Array(rosterOrder(localPlayers)[$0..<min($0 + 6, rosterOrder(localPlayers).count)]) }
        ScreenDialog(onDismiss: onDismiss) {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t(title)).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                        Text("\(t(hint)) · \(t("{count}/5 selected", ["count": selected.count]))").font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        MTextButton(t("Cancel"), action: onDismiss)
                        MButton(t(confirmLabel), enabled: !selected.isEmpty) { onConfirm(selected) }
                    }
                }
                if localPlayers.isEmpty {
                    Text(t("This team has no players yet")).font(Fonts.bodyLarge).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowPlayers in
                                HStack(spacing: 8) {
                                    ForEach(rowPlayers) { player in
                                        let isStarter = selected.contains(player.id)
                                        Button {
                                            if isStarter { selected.remove(player.id) } else if selected.count < 5 { selected.insert(player.id) }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(playerSelectionLabel(player, among: localPlayers)).font(Fonts.titleSmall).foregroundStyle(Theme.ink).lineLimit(1)
                                                Text(t(isStarter ? selectedLabel : unselectedLabel)).font(Fonts.labelSmall).foregroundStyle(isStarter ? Color(hex: 0x9A4600) : Theme.secondaryText)
                                            }
                                            .padding(.horizontal, 12).padding(.vertical, 4)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                            .background(RoundedRectangle(cornerRadius: 12).fill(isStarter ? Color(hex: 0xFFE2C6) : Color(hex: 0xF0F1F3)))
                                        }.buttonStyle(.plain)
                                        .accessibilityIdentifier("lineup-player-\(player.number)-\(player.name)")
                                    }
                                    ForEach(0..<(6 - rowPlayers.count), id: \.self) { _ in Spacer().frame(maxWidth: .infinity) }
                                }.frame(height: 52)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(t("New Player")).font(Fonts.labelLarge).foregroundStyle(Theme.secondaryText)
                    WeightedRow(weights: [0.55, 1, 1], spacing: 8) { index, _ in
                        switch index {
                        case 0: RecorderInputField(label: t("Number"), value: otherNumber, selected: activeField == "number") { activeField = "number" }
                        case 1: RecorderInputField(label: t("First Name"), value: otherFirstName, selected: activeField == "first") { activeField = "first" }
                        default: RecorderInputField(label: t("Last Name"), value: otherLastName, selected: activeField == "last") { activeField = "last" }
                        }
                    }.frame(height: 54)
                    MButton(t("Add"), enabled: !otherNumber.isBlank || !otherLastName.isBlank || !otherFirstName.isBlank, horizontalPadding: 14) {
                        let name = fullName(otherFirstName, otherLastName)
                        let number = otherNumber.trimmed
                        let id = store.addPlayer(teamId, name: name, number: number)
                        let player = store.player(id) ?? Player(id: id, teamId: teamId, name: name, number: number)
                        if !localPlayers.contains(where: { $0.id == id }) { localPlayers.append(player) }
                        if !selected.contains(id) && selected.count < 5 { selected.insert(id) }
                        otherNumber = ""; otherFirstName = ""; otherLastName = ""
                    }
                }
                if let field = activeField {
                    RecorderKeyboard(numeric: field == "number", onKey: { key in updateActive { $0 + key } }, onBackspace: { updateActive { String($0.dropLast()) } }, onClear: { updateActive { _ in "" } }, onDone: { activeField = nil })
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
        }
        .onAppear { selected = initial; localPlayers = players }
    }
}

// MARK: - Player choice

struct PlayerChoiceDialog: View {
    @EnvironmentObject private var store: AppStore
    let teamId: Int64
    let title: String
    let players: [Player]
    let showNone: Bool
    let onPlayer: (Player) -> Void
    let onNone: () -> Void
    let onDismiss: () -> Void
    var noneLabel = "No assist"
    var context: String? = nil
    var highlighted: Set<Int64> = []
    var onBack: (() -> Void)? = nil
    @State private var otherNumber = ""
    @State private var otherFirstName = ""
    @State private var otherLastName = ""
    @State private var activeField: String?
    @State private var pickingNumber = false
    // The caller's list is a snapshot, so roster edits made through the number pad are tracked
    // here to show up in the grid immediately after the pad closes.
    @State private var extraPlayers: [Player] = []
    @State private var removedIds: Set<Int64> = []
    private var gridPlayers: [Player] { rosterOrder((players + extraPlayers.filter { extra in !players.contains { $0.id == extra.id } }).filter { !removedIds.contains($0.id) }) }
    private func updateActive(_ transform: (String) -> String) {
        switch activeField {
        case "number": otherNumber = String(transform(otherNumber).filter(\.isNumber).prefix(3))
        case "last": otherLastName = String(transform(otherLastName).capitalizeInitial().prefix(24))
        case "first": otherFirstName = String(transform(otherFirstName).capitalizeInitial().prefix(24))
        default: break
        }
    }

    var body: some View {
        if pickingNumber {
            // The number pad swaps in for this dialog entirely; Cancel returns to the player list.
            ScreenDialog(onDismiss: { pickingNumber = false }, marginFraction: numberPadMarginFraction) {
                NumberPickPanel(teamId: teamId, onAdded: { picked in
                    // A number selection is the final player-selection step, so save the play immediately.
                    removedIds.remove(picked.id)
                    if !gridPlayers.contains(where: { $0.id == picked.id }) { extraPlayers.append(picked) }
                    pickingNumber = false
                    onPlayer(picked)
                }, onRemoved: { id in removedIds.insert(id); extraPlayers.removeAll { $0.id == id } }, onCancel: { pickingNumber = false })
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            }
        } else {
            ScreenDialog(onDismiss: onDismiss) {
                VStack(spacing: 12) {
                    // Every header action lives on the right: Previous appears whenever this dialog is not the
                    // first step of the flow, next to Cancel. There is no Save: picking the player is the last
                    // thing the user has to say, so the tap records it instead of staging it.
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t(title)).font(Fonts.headlineSmall).foregroundStyle(Theme.ink)
                            if let context { Text(t(context)).font(Fonts.bodyMedium).foregroundStyle(Theme.secondaryText) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            if let onBack { MTextButton(t("Previous"), minSize: 48, action: onBack) }
                            MTextButton(t("Cancel"), minSize: 48, action: onDismiss)
                        }
                    }
                    let rowCount = max(1, (playerGridSlots(gridPlayers).count + (showNone ? 1 : 0) + 1 + 5) / 6)
                    ScrollView {
                        PlayerGrid(gap: 12, rowGap: rowCount > 1 ? 6 : 0) { buttonWidth in
                            // The "none" choice sits in the grid so it matches the player buttons in size.
                            if showNone { MOutlinedButton(t(noneLabel), content: Theme.secondaryText, height: 52, horizontalPadding: 8) { onNone() }.frame(width: buttonWidth) }
                            PlayerGridCells(players: gridPlayers, cellWidth: buttonWidth, gap: 12) { player, width in
                                let onCourt = highlighted.contains(player.id)
                                Button { onPlayer(player) } label: {
                                    HStack(spacing: 8) {
                                        if player.name.isBlank { Spacer(minLength: 0) }
                                        Text(player.number.isBlank ? "--" : player.number).font(Fonts.titleMedium).foregroundStyle(.white).frame(width: 32, height: 32).background(Circle().fill(Theme.orange))
                                        if !player.name.isBlank { Text(playerSelectionLabel(player, among: gridPlayers)).font(Fonts.titleSmall).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) } else { Spacer(minLength: 0) }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .frame(width: width, height: 52)
                                    .background(Capsule().fill(onCourt ? Theme.orange.opacity(0.22) : .clear))
                                    .overlay(Capsule().strokeBorder(onCourt ? Theme.orange : Theme.outline, lineWidth: onCourt ? 2 : 1))
                                }.buttonStyle(.plain)
                                .accessibilityIdentifier("dialog-player-\(player.number)-\(player.name)")
                            }
                            // The number pad is the escape hatch at the end of the list.
                            MOutlinedButton(t("Choose number"), content: Theme.orange, height: 52, horizontalPadding: 8) { pickingNumber = true }.frame(width: buttonWidth)
                        }
                        .frame(height: CGFloat(rowCount) * 52 + CGFloat(max(0, rowCount - 1)) * 6)
                    }
                    HStack(spacing: 8) {
                        Text(t("Other Player")).font(Fonts.labelLarge).foregroundStyle(Theme.secondaryText)
                        WeightedRow(weights: [0.55, 1, 1], spacing: 8) { index, _ in
                            switch index {
                            case 0: RecorderInputField(label: t("Number"), value: otherNumber, selected: activeField == "number") { activeField = "number" }
                            case 1: RecorderInputField(label: t("First Name"), value: otherFirstName, selected: activeField == "first") { activeField = "first" }
                            default: RecorderInputField(label: t("Last Name"), value: otherLastName, selected: activeField == "last") { activeField = "last" }
                            }
                        }.frame(height: 54)
                        MButton(t("Add"), enabled: !otherNumber.isBlank || !otherLastName.isBlank || !otherFirstName.isBlank, horizontalPadding: 12) {
                            let name = fullName(otherFirstName, otherLastName)
                            let number = otherNumber.trimmed
                            let id = store.addPlayer(teamId, name: name, number: number)
                            onPlayer(store.player(id) ?? Player(id: id, teamId: teamId, name: name, number: number))
                        }
                    }
                    if let field = activeField {
                        RecorderKeyboard(numeric: field == "number", onKey: { key in updateActive { $0 + key } }, onBackspace: { updateActive { String($0.dropLast()) } }, onClear: { updateActive { _ in "" } }, onDone: { activeField = nil })
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            }
        }
    }
}

/// Jersey-number pad filling 95% of the screen: nothing but the 0-99 grid, ten numbers per line.
/// The pad edits the team roster directly, so every player list of the team sees the change.
struct NumberPickPanel: View {
    @EnvironmentObject private var store: AppStore
    let teamId: Int64
    let onAdded: (Player) -> Void
    let onRemoved: (Int64) -> Void
    var onCancel: (() -> Void)? = nil
    var body: some View {
        let roster = store.players(teamId)
        let byNumber = Dictionary(roster.compactMap { player in Int(player.number.trimmed).map { ($0, player) } }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 4) {
            if let onCancel { HStack { Spacer(); MTextButton(t("Cancel"), action: onCancel) } }
            NumberGrid(byNumber: byNumber) { number, existing in
                if let existing {
                    if store.playerHasEvents(existing.id) { store.showToast(t("#{number} already has recorded stats", ["number": number])) }
                    else { store.deletePlayer(existing.id); onRemoved(existing.id) }
                } else {
                    let id = store.addPlayer(teamId, name: "", number: String(number))
                    onAdded(store.player(id) ?? Player(id: id, teamId: teamId, name: "", number: String(number)))
                }
            }
        }
        .padding(10)
    }
}

/// 0-99 grid, ten per row, highlighted numbers are players already on the roster.
struct NumberGrid: View {
    let byNumber: [Int: Player]
    let onTap: (Int, Player?) -> Void
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<10, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<10, id: \.self) { column in
                        let number = row * 10 + column
                        let existing = byNumber[number]
                        Button { onTap(number, existing) } label: {
                            Text(String(number)).font(Fonts.titleMedium).lineLimit(1)
                                .foregroundStyle(existing != nil ? .white : Theme.ink)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(RoundedRectangle(cornerRadius: 12).fill(existing != nil ? Theme.orange : Color(hex: 0x22111822)))
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("number-\(number)")
                    }
                }.frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Rebound

struct ReboundChoiceDialog: View {
    @EnvironmentObject private var store: AppStore
    let homeName: String
    let awayName: String
    let awayTeamId: Int64
    let shootingTeamId: Int64
    let homeTeamId: Int64
    let onPlayer: (Player) -> Void
    let onNone: () -> Void
    let onDismiss: () -> Void
    @State private var teamId: Int64 = 0
    @State private var number = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var activeField: String?
    @State private var pickingNumber = false
    private var currentTeam: Int64 { teamId == 0 ? shootingTeamId : teamId }
    private func updateActive(_ transform: (String) -> String) {
        switch activeField {
        case "number": number = String(transform(number).filter(\.isNumber).prefix(3))
        case "first": firstName = String(transform(firstName).prefix(24))
        case "last": lastName = String(transform(lastName).prefix(24))
        default: break
        }
    }
    var body: some View {
        let team = currentTeam
        let players = rosterOrder(store.players(team))
        if pickingNumber {
            // The pad takes over the whole popup. A newly selected number is the final rebounder choice.
            ScreenDialog(onDismiss: { pickingNumber = false }, marginFraction: numberPadMarginFraction) {
                NumberPickPanel(teamId: team, onAdded: { picked in pickingNumber = false; onPlayer(picked) }, onRemoved: { _ in }, onCancel: { pickingNumber = false })
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            }
        } else {
            ScreenDialog(onDismiss: onDismiss) {
                VStack(spacing: 8) {
                    // Picking a player (or "No rebound") saves and closes, so the header only needs Cancel.
                    HStack(spacing: 0) {
                        MTabRow(labels: ["\(homeName) · \(t(shootingTeamId == homeTeamId ? "Offensive rebound" : "Defensive rebound"))", "\(awayName) · \(t(shootingTeamId == awayTeamId ? "Offensive rebound" : "Defensive rebound"))"], selected: team == homeTeamId ? 0 : 1, containerColor: .clear) { index in teamId = index == 0 ? homeTeamId : awayTeamId; activeField = nil }
                        MTextButton(t("Cancel"), minSize: 48, action: onDismiss)
                    }
                    let rowCount = max(1, (playerGridSlots(players).count + 2 + 5) / 6)
                    ScrollView {
                        PlayerGrid(gap: 6) { buttonWidth in
                            MOutlinedButton(t("No rebound"), height: 52, horizontalPadding: 8) { onNone() }.frame(width: buttonWidth)
                            PlayerGridCells(players: players, cellWidth: buttonWidth, gap: 6) { player, width in
                                MOutlinedButton(playerSelectionLabel(player, among: players), height: 52, horizontalPadding: 8) { onPlayer(player) }.frame(width: width)
                                    .accessibilityIdentifier("dialog-player-\(player.number)-\(player.name)")
                            }
                            MOutlinedButton(t("Choose number"), content: Theme.orange, height: 52, horizontalPadding: 8) { pickingNumber = true }.frame(width: buttonWidth)
                        }
                        .frame(height: CGFloat(rowCount) * 58)
                    }
                    HStack(spacing: 8) {
                        Text(t("New Player")).font(Fonts.labelLarge).foregroundStyle(Theme.secondaryText)
                        WeightedRow(weights: [0.55, 1, 1], spacing: 8) { index, _ in
                            switch index {
                            case 0: RecorderInputField(label: t("Number"), value: number, selected: activeField == "number") { activeField = "number" }
                            case 1: RecorderInputField(label: t("First Name"), value: firstName, selected: activeField == "first") { activeField = "first" }
                            default: RecorderInputField(label: t("Last Name"), value: lastName, selected: activeField == "last") { activeField = "last" }
                            }
                        }.frame(height: 54)
                        MButton(t("Add"), enabled: !number.isBlank || !firstName.isBlank || !lastName.isBlank, horizontalPadding: 14) {
                            store.addPlayer(team, name: fullName(firstName, lastName), number: number.trimmed)
                            number = ""; firstName = ""; lastName = ""; activeField = nil
                        }
                    }
                    if let field = activeField {
                        RecorderKeyboard(numeric: field == "number", onKey: { key in updateActive { $0 + key } }, onBackspace: { updateActive { String($0.dropLast()) } }, onClear: { updateActive { _ in "" } }, onDone: { activeField = nil })
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            }
        }
    }
}

// MARK: - Team panel

struct TeamPanel: View {
    let score: Int
    let lineupCount: Int
    let fullStats: Bool
    let transparentAccents: Bool
    let onStarters: () -> Void
    let onAddPlayer: () -> Void
    let onPoints: (Int) -> Void
    let onMiss: (Int) -> Void
    let onFreeThrow: () -> Void
    let onFoul: () -> Void
    let onSubstitution: () -> Void
    let onStat: (String) -> Void
    let onAdjust: (Int) -> Void
    var teamName = ""

    // Over the camera preview the accent buttons are outlines so the video stays visible; in Score
    // mode there is no preview behind them, so they keep their solid colour.
    private func accent(_ title: String, _ color: Color, horizontalPadding: CGFloat, action: @escaping () -> Void) -> some View {
        MOutlinedButton(title, container: transparentAccents ? .clear : color, content: transparentAccents ? color : .white, border: transparentAccents ? color : .clear, borderWidth: transparentAccents ? 2 : 0, height: 40, horizontalPadding: horizontalPadding, fullWidth: true, action: action)
    }
    private func plain(_ title: String, horizontalPadding: CGFloat = 4, action: @escaping () -> Void) -> some View {
        MOutlinedButton(title, content: .white, height: 40, horizontalPadding: horizontalPadding, fullWidth: true, action: action)
    }
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                if fullStats {
                    MOutlinedButton(lineupCount == 5 ? t("Lineup 5") : t("⚠ Lineup {count}/5", ["count": lineupCount]), content: lineupCount == 5 ? .white : Color(hex: 0xFFC857), height: 40, horizontalPadding: 7, font: Fonts.labelSmall, action: onStarters)
                    MOutlinedButton(t("Sub"), height: 40, horizontalPadding: 7, font: Fonts.labelSmall, action: onSubstitution)
                }
                MOutlinedButton(t("Players"), height: 40, horizontalPadding: 7, font: Fonts.labelSmall, action: onAddPlayer)
            }
            // Each correction button sits midway between the enlarged score and the panel edge.
            HStack(spacing: 0) {
                Spacer()
                MOutlinedButton("-1", content: .white, height: 28, horizontalPadding: 0, font: Fonts.labelMedium) { onAdjust(-1) }.frame(width: 38)
                Spacer()
                Text("\(score)").font(Fonts.displayMedium).foregroundStyle(Theme.orange).lineLimit(1).minimumScaleFactor(0.6).accessibilityIdentifier("score-value-\(teamName)")
                Spacer()
                MOutlinedButton("+1", content: .white, height: 28, horizontalPadding: 0, font: Fonts.labelMedium) { onAdjust(1) }.frame(width: 38)
                Spacer()
            }
            HStack(spacing: 5) {
                accent("+2", Theme.madeGreen, horizontalPadding: 5) { onPoints(2) }.accessibilityIdentifier("score-2-\(teamName)")
                accent("+3", Theme.madeGreen, horizontalPadding: 5) { onPoints(3) }.accessibilityIdentifier("score-3-\(teamName)")
            }
            if fullStats {
                HStack(spacing: 5) {
                    accent(t("Miss 2"), Theme.missRed, horizontalPadding: 4) { onMiss(2) }
                    accent(t("Miss 3"), Theme.missRed, horizontalPadding: 4) { onMiss(3) }
                }
                accent(t("Free Throw"), Theme.freeThrowOrange, horizontalPadding: 12, action: onFreeThrow)
                HStack(spacing: 5) { plain(t("Rebound")) { onStat("REB") }; plain(t("Assist")) { onStat("AST") } }
                HStack(spacing: 5) { plain(t("Steal")) { onStat("STL") }; plain(t("Block")) { onStat("BLK") } }
            }
            // Foul is available in both Full Stats and Score + Record modes.
            HStack(spacing: 5) {
                if fullStats { plain(t("Turnover")) { onStat("TOV") } }
                plain(t("Foul"), action: onFoul)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.scoreboardBackground)
    }
}

// MARK: - Roster panel (Players)

/// Full-screen 0-99 number pad: highlighted numbers are players on the roster, tapping toggles them.
/// Every tap writes straight through to the roster, so Cancel replays the panel back to how it opened.
struct RosterNumbersOverlay: View {
    @EnvironmentObject private var store: AppStore
    let teamId: Int64
    let teamName: String
    let onDismiss: () -> Void
    @State private var nameMode = false
    @State private var opened: [Player] = []

    private var roster: [Player] {
        let current = store.players(teamId)
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return opened.compactMap { byId[$0.id] } + current.filter { player in !opened.contains { $0.id == player.id } }
    }
    private func cancel() {
        let current = store.players(teamId)
        current.filter { player in !opened.contains { $0.id == player.id } }.forEach { store.deletePlayer($0.id) }
        for before in opened {
            if let now = current.first(where: { $0.id == before.id }) {
                if now.name != before.name || now.number != before.number { store.updatePlayer(before.id, name: before.name, number: before.number) }
            } else { store.addPlayer(teamId, name: before.name, number: before.number) }
        }
        onDismiss()
    }
    var body: some View {
        let roster = roster
        let byNumber = Dictionary(roster.compactMap { player in Int(player.number.trimmed).map { ($0, player) } }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Players · {team}", ["team": teamName])).font(Fonts.titleLarge).foregroundStyle(Theme.ink)
                    Text(nameMode ? t("Edit numbers and names, or add a new player") : t("Tap a number to add or remove a player")).font(Fonts.bodySmall).foregroundStyle(Theme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
                // Numbers mode is the fast path during a game; Names mode is for fixing up the roster.
                HStack(spacing: 6) {
                    ForEach([(false, "Numbers"), (true, "Names")], id: \.1) { mode, label in
                        MButton(t(label), container: nameMode == mode ? Theme.orange : Color(hex: 0x22111822), content: nameMode == mode ? .white : Theme.ink, horizontalPadding: 14) { nameMode = mode }
                    }
                }
                Spacer().frame(width: 10)
                MOutlinedButton(t("Cancel"), horizontalPadding: 18) { cancel() }
                Spacer().frame(width: 6)
                MButton(t("Done"), horizontalPadding: 18, action: onDismiss)
            }
            if nameMode {
                RosterNameEditor(teamId: teamId, roster: roster).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NumberGrid(byNumber: byNumber) { number, player in
                    if let player {
                        if store.playerHasEvents(player.id) { store.showToast(t("#{number} already has recorded stats", ["number": number])) } else { store.deletePlayer(player.id) }
                    } else { store.addPlayer(teamId, name: "", number: String(number)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(dialogScreenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .onAppear { opened = rosterOrder(store.players(teamId)) }
    }
}

private struct RosterFocus: Equatable { let playerId: Int64?; let field: String }

/// Names mode: two compact columns to edit number, first and last name, with a new-player row at the
/// bottom. Edits write straight to the store, so recorded data stays attached to the same player.
struct RosterNameEditor: View {
    @EnvironmentObject private var store: AppStore
    let teamId: Int64
    let roster: [Player]
    @State private var focus: RosterFocus?
    @State private var newNumber = ""
    @State private var newFirst = ""
    @State private var newLast = ""

    private func valueOf(_ player: Player, _ field: String) -> String { field == "number" ? player.number : field == "first" ? firstNameOf(player.name) : lastNameOf(player.name) }
    private func setValue(_ player: Player, _ field: String, _ value: String) {
        switch field {
        case "number": store.updatePlayer(player.id, name: player.name, number: value)
        case "first": store.updatePlayer(player.id, name: fullName(value, lastNameOf(player.name)), number: player.number)
        default: store.updatePlayer(player.id, name: fullName(firstNameOf(player.name), value), number: player.number)
        }
    }
    private func draftValue(_ field: String) -> String { field == "number" ? newNumber : field == "first" ? newFirst : newLast }
    private func setDraft(_ field: String, _ value: String) { switch field { case "number": newNumber = value; case "first": newFirst = value; default: newLast = value } }
    private func addDraft() {
        let name = fullName(newFirst, newLast)
        // addPlayer reuses an existing jersey number, so set the name explicitly afterwards.
        let id = store.addPlayer(teamId, name: name, number: newNumber.trimmed)
        store.updatePlayer(id, name: name, number: newNumber.trimmed)
        newNumber = ""; newFirst = ""; newLast = ""; focus = nil
    }
    private func playerCell(_ player: Player) -> some View {
        HStack(spacing: 4) {
            RecorderInputField(label: "#", value: player.number, selected: focus == RosterFocus(playerId: player.id, field: "number"), height: 40, hideLabelWhenFilled: true, identifier: "roster-number-\(player.number)") { focus = RosterFocus(playerId: player.id, field: "number") }.frame(width: 58)
            RecorderInputField(label: t("First"), value: firstNameOf(player.name), selected: focus == RosterFocus(playerId: player.id, field: "first"), height: 40, hideLabelWhenFilled: true, identifier: "roster-first-\(player.number)") { focus = RosterFocus(playerId: player.id, field: "first") }
            RecorderInputField(label: t("Last"), value: lastNameOf(player.name), selected: focus == RosterFocus(playerId: player.id, field: "last"), height: 40, hideLabelWhenFilled: true, identifier: "roster-last-\(player.number)") { focus = RosterFocus(playerId: player.id, field: "last") }
            MTextButton("✕", font: Fonts.titleMedium, horizontalPadding: 6) {
                if store.playerHasEvents(player.id) { store.showToast(t("{player} already has recorded stats", ["player": player.label])) }
                else { if focus?.playerId == player.id { focus = nil }; store.deletePlayer(player.id) }
            }.frame(width: 44)
        }
    }
    var body: some View {
        let pairs = stride(from: 0, to: roster.count, by: 2).map { Array(roster[$0..<min($0 + 2, roster.count)]) }
        // The number keypad is an overlay so it never changes the panel's layout.
        VStack(spacing: 6) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 12) {
                                ForEach(pair) { player in playerCell(player).frame(maxWidth: .infinity) }
                                if pair.count == 1 { Spacer().frame(maxWidth: .infinity) }
                            }
                        }
                        HStack(spacing: 4) {
                            RecorderInputField(label: "#", value: newNumber, selected: focus == RosterFocus(playerId: nil, field: "number"), height: 40, hideLabelWhenFilled: true, identifier: "roster-new-number") { focus = RosterFocus(playerId: nil, field: "number") }.frame(width: 58)
                            RecorderInputField(label: t("First"), value: newFirst, selected: focus == RosterFocus(playerId: nil, field: "first"), height: 40, hideLabelWhenFilled: true, identifier: "roster-new-first") { focus = RosterFocus(playerId: nil, field: "first") }
                            RecorderInputField(label: t("Last"), value: newLast, selected: focus == RosterFocus(playerId: nil, field: "last"), height: 40, hideLabelWhenFilled: true, identifier: "roster-new-last") { focus = RosterFocus(playerId: nil, field: "last") }
                            MButton(t("Add player"), enabled: !newNumber.isBlank || !newFirst.isBlank || !newLast.isBlank, horizontalPadding: 12) { addDraft() }
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
                if let active = focus, active.field != "number" || active.playerId == nil {
                    let player = active.playerId.flatMap { id in roster.first { $0.id == id } }
                    if active.playerId == nil || player != nil {
                        let current = player.map { valueOf($0, active.field) } ?? draftValue(active.field)
                        let numeric = active.field == "number"
                        let apply: (String) -> Void = { value in if let player { setValue(player, active.field, value) } else { setDraft(active.field, value) } }
                        RecorderKeyboard(numeric: numeric, onKey: { key in apply(numeric ? String((current + key).filter(\.isNumber).prefix(3)) : String((current + key).prefix(24))) }, onBackspace: { apply(String(current.dropLast())) }, onClear: { apply("") }, onDone: { focus = nil })
                    }
                }
        }
        .overlay {
            if let active = focus, active.field == "number", let id = active.playerId, let player = roster.first(where: { $0.id == id }) {
                NumberInputDialog(initial: player.number, alignRight: (roster.firstIndex { $0.id == id } ?? 0) % 2 == 0, onCancel: { focus = nil }, onSave: { value in setValue(player, "number", value); focus = nil })
            }
        }
        .onChange(of: roster) { _, _ in if let id = focus?.playerId, !roster.contains(where: { $0.id == id }) { focus = nil } }
    }
}

/// Small number keypad popup for a single jersey number, shown beside the row being edited.
struct NumberInputDialog: View {
    let initial: String
    let alignRight: Bool
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var value: String
    init(initial: String, alignRight: Bool, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.initial = initial; self.alignRight = alignRight; self.onCancel = onCancel; self.onSave = onSave
        _value = State(initialValue: initial)
    }
    var body: some View {
        ZStack(alignment: alignRight ? .trailing : .leading) {
            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: onCancel)
            VStack(spacing: 4) {
                Text(t("Player number")).font(Fonts.titleMedium).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                Text(value.isBlank ? "—" : value).font(Fonts.headlineSmall).foregroundStyle(Theme.orange).frame(maxWidth: .infinity)
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["0"]], id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { key in MOutlinedButton(key, content: Theme.ink, height: 38, horizontalPadding: 0, fullWidth: true, font: Fonts.titleMedium) { value = String((value + key).prefix(3)) } }
                        ForEach(0..<(3 - row.count), id: \.self) { _ in Spacer().frame(maxWidth: .infinity) }
                    }
                }
                HStack(spacing: 6) {
                    MOutlinedButton(t("Cancel"), height: 36, fullWidth: true, action: onCancel).accessibilityIdentifier("number-cancel")
                    MOutlinedButton(t("Delete"), height: 36, fullWidth: true) { value = String(value.dropLast()) }
                    MButton(t("OK"), height: 36, fullWidth: true) { onSave(value) }.accessibilityIdentifier("number-ok")
                }
            }
            .padding(12)
            .frame(width: 320)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.2), radius: 12)
            .padding(20)
        }
    }
}
