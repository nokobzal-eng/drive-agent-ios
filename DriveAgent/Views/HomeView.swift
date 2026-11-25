import SwiftUI
import UIKit

/// The dashboard, laid out like the Android app's home screen.
struct HomeView: View {
    @EnvironmentObject private var controller: DriveController
    @StateObject private var systems = SystemsChecker()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var typed = ""
    @State private var settings = SettingsStore.load()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    GreetingView(owner: settings.ownerName)

                    AssistantControl(
                        name: settings.assistantName,
                        active: controller.isDriving,
                        phase: controller.phase,
                        action: toggleDrive
                    )

                    if controller.isDriving && (controller.phase == .speaking || controller.phase == .thinking) {
                        Button {
                            controller.interrupt()
                        } label: {
                            Text("הפסק לדבר")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .background(Theme.negative, in: RoundedRectangle(cornerRadius: Theme.corner))
                        }
                        .buttonStyle(.plain)
                    }

                    if let error = controller.errorText {
                        StatusChip(text: error, color: Theme.negative)
                    }

                    TodayTiles(
                        today: systems.today,
                        team: TeamStore.shared,
                        onToday: { controller.send("מה יש לי היום ביומן?") },
                        onTomorrow: { controller.send("מה יש לי מחר ביומן?") },
                        onTeam: { controller.showTeam = true }
                    )

                    ActionGrid(items: actions)

                    SystemsBar(lights: systems.lights, onTap: openFix)

                    conversation

                    chatPanel

                    if !controller.log.isEmpty {
                        logPanel
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("עוזר נהיגה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("הגדרות") { showSettings = true }
                    .disabled(controller.isDriving)
            }
            .sheet(isPresented: $showSettings, onDismiss: refresh) {
                SettingsView()
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .fullScreenCover(isPresented: $controller.showTeam) {
                TeamPage()
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .task { await systems.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refresh() }
        }
        .onChange(of: controller.isDriving) {
            refresh()
        }
    }

    // MARK: Sections

    private var actions: [ActionItem] {
        [
            ActionItem(label: "דבר") { controller.talkNow() },
            ActionItem(label: "צוות") { controller.showTeam = true },
            ActionItem(label: "+ משימה לצוות") { controller.send("אני רוצה להוסיף משימה לצוות. תשאל אותי מה, למי ומתי.") },
            ActionItem(label: "מה היום ביומן") { controller.send("מה יש לי היום ביומן?") },
            ActionItem(label: "מה השבוע") { controller.send("מה יש לי השבוע ביומן?") },
            ActionItem(label: "קבע אירוע") { controller.send("אני רוצה לקבוע אירוע ביומן. תשאל אותי מה ומתי.") },
            ActionItem(label: "התקשר") { controller.send("אני רוצה להתקשר למישהו. תשאל אותי למי.") },
            ActionItem(label: "הודעת וואטסאפ") { controller.send("אני רוצה לשלוח הודעת וואטסאפ. תשאל אותי למי ומה לכתוב.") },
            ActionItem(label: "חדשות") { controller.send("מה החדשות החשובות היום בישראל? בקצרה.") },
            ActionItem(label: "מזג אוויר") { controller.send("מה מזג האוויר היום? בקצרה.") },
            ActionItem(label: "בדיקת מערכות") { refresh() },
        ]
    }

    @ViewBuilder
    private var conversation: some View {
        if controller.isDriving && !controller.live.isEmpty {
            StatusChip(text: "שומע: \(controller.live)")
        }
        if !controller.heard.isEmpty {
            Bubble(who: "אתה", text: controller.heard, mine: true)
        }
        if !controller.answer.isEmpty {
            Bubble(who: settings.assistantName, text: controller.answer, mine: false)
        }
    }

    /// Typing instead of talking.
    private var chatPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("כתיבה ל\(settings.assistantName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                TextField("מה לעשות?", text: $typed, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .foregroundStyle(Theme.text)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Toggle(isOn: $controller.speakReplies) {
                    Text(controller.speakReplies ? "התשובות מוקראות בקול" : "התשובות מוצגות במסך בלבד")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .tint(Theme.positive)
                Button(action: sendTyped) {
                    Text("שלח")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.line : Theme.accent,
                            in: RoundedRectangle(cornerRadius: Theme.corner)
                        )
                }
                .buttonStyle(.plain)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var logPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("פקודות אחרונות")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                ForEach(controller.log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.request).font(.footnote).foregroundStyle(Theme.text)
                        if !entry.answer.isEmpty {
                            Text("← \(entry.answer)").font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func toggleDrive() {
        if controller.isDriving {
            controller.stop()
        } else {
            // Turning on with the big button always brings the voice back.
            controller.speakReplies = true
            controller.start()
        }
    }

    private func sendTyped() {
        let text = typed
        typed = ""
        controller.send(text)
    }

    private func refresh() {
        settings = SettingsStore.load()
        Task { await systems.refresh() }
    }

    /// Claude problems are fixed in the app's settings; permissions in the iPhone's settings.
    private func openFix(_ light: SystemLight) {
        if light.kind == .claude {
            if !controller.isDriving { showSettings = true }
            return
        }
        guard light.state == .error, let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
