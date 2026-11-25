import SwiftUI

// MARK: - Greeting

struct GreetingView: View {
    let owner: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting(at: context.date))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(AgentBrain.formatted(context.date, "EEEE, d 'ב'MMMM · HH:mm"))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func greeting(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let base = switch hour {
        case 5...11: "בוקר טוב"
        case 12...16: "צהריים טובים"
        case 17...20: "ערב טוב"
        default: "לילה טוב"
        }
        let name = owner.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? base : "\(base), \(name)"
    }
}

// MARK: - The assistant's on/off control

/// One wide button, easy to hit while driving: starts or stops drive mode and shows its state.
struct AssistantControl: View {
    let name: String
    let active: Bool
    let phase: DriveController.Phase
    let action: () -> Void

    private var stateColor: Color {
        guard active else { return Theme.muted }
        return phase == .thinking ? Theme.caution : Theme.positive
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(active ? Theme.text : Theme.onAccent)
                    HStack(spacing: 6) {
                        if active { Light(color: stateColor) }
                        Text(active ? phase.rawValue : "מצב נהיגה כבוי")
                            .font(.footnote)
                            .foregroundStyle(active ? Theme.muted : Theme.onAccent)
                    }
                }
                Spacer()
                Text(active ? "עצור" : "הפעל")
                    .font(.headline)
                    .foregroundStyle(active ? Theme.text : Theme.onAccent)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(active ? Theme.surface : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(active ? stateColor : Theme.accent, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Today at a glance

struct TodayTiles: View {
    let today: TodaySummary
    @ObservedObject var team: TeamStore
    let onToday: () -> Void
    let onTomorrow: () -> Void
    let onTeam: () -> Void

    var body: some View {
        // Read so that the tiles redraw whenever the board changes.
        let _ = team.version
        let board = team.board
        let todays = board.tasks.filter { TeamStore.isTodays($0) }
        let working = board.employees.filter { TeamStore.worksToday($0) }.count
        let open = todays.filter { !TeamStore.isDoneNow($0) }.count
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Tile(
                    title: "האירוע הבא",
                    big: today.nextTime ?? (today.nextTitle == nil ? "—" : "כל היום"),
                    small: today.nextTitle ?? (today.calendarAllowed ? "אין עוד אירועים היום" : "היומן עוד לא מאושר"),
                    action: onToday
                )
                Tile(
                    title: "היום ביומן",
                    big: "\(today.eventsToday)",
                    small: "מחר: \(today.eventsTomorrow)",
                    action: onTomorrow
                )
            }
            HStack(spacing: 8) {
                Tile(
                    title: "צוות היום",
                    big: board.employees.isEmpty ? "—" : "\(working)/\(board.employees.count)",
                    small: board.employees.isEmpty ? "עוד אין עובדים" : "עובדים היום",
                    action: onTeam
                )
                Tile(
                    title: "משימות היום",
                    big: "\(open)",
                    small: "בוצעו: \(todays.count - open)",
                    action: onTeam
                )
            }
        }
    }
}

private struct Tile: View {
    let title: String
    let big: String
    let small: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                Text(big).font(.title.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(small).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Actions

struct ActionItem: Identifiable {
    let label: String
    let action: () -> Void
    var id: String { label }
}

struct ActionGrid: View {
    let items: [ActionItem]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                Button(action: item.action) {
                    Text(item.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .padding(.horizontal, 6)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Systems

/// One line when all is well; details when something needs attention.
struct SystemsBar: View {
    let lights: [SystemLight]
    let onTap: (SystemLight) -> Void
    @State private var open = false

    private var problems: [SystemLight] { lights.filter { $0.state == .error || $0.state == .offline } }
    private var checking: Bool { lights.isEmpty || lights.contains { $0.kind == .claude && $0.state == .unknown } }

    private var summaryColor: Color {
        if !problems.isEmpty { return Theme.negative }
        return checking ? Theme.muted : Theme.positive
    }

    private var summary: String {
        if !problems.isEmpty { return "צריך לטפל: " + problems.map(\.label).joined(separator: ", ") }
        if checking { return "בודק מערכות…" }
        return "כל המערכות תקינות"
    }

    var body: some View {
        Card(border: problems.isEmpty ? Theme.line : Theme.negative) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    open.toggle()
                } label: {
                    HStack {
                        Light(color: summaryColor)
                        Text(summary).font(.footnote).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(open ? "▴" : "▾").foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
                if open || !problems.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), alignment: .leading, spacing: 8) {
                        ForEach(lights) { light in
                            Button {
                                onTap(light)
                            } label: {
                                HStack(spacing: 5) {
                                    Light(color: Theme.color(light.state))
                                    Text(light.label).font(.caption).foregroundStyle(Theme.text).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Conversation

struct Bubble: View {
    let who: String
    let text: String
    let mine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(who).font(.caption2).foregroundStyle(Theme.muted)
            Text(text).font(.body).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(mine ? Theme.surfaceHigh : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.line, lineWidth: 1))
        .frame(maxWidth: 300, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .leading : .trailing)
    }
}

struct StatusChip: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.line, lineWidth: 1))
    }
}
