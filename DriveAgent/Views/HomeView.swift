import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var controller: DriveController
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(controller.phase.rawValue)
                    .font(.largeTitle.bold())

                if !controller.heard.isEmpty {
                    LabeledText(title: "שמעתי", text: controller.heard)
                }
                if !controller.answer.isEmpty {
                    LabeledText(title: "תשובה", text: controller.answer)
                }
                if let error = controller.errorText {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Spacer()

                Button {
                    if controller.isDriving { controller.stop() } else { controller.start() }
                } label: {
                    Text(controller.isDriving ? "עצור מצב נהיגה" : "התחל מצב נהיגה")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 88)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isDriving ? .red : .green)
            }
            .padding()
            .navigationTitle("עוזר נהיגה")
            .toolbar {
                Button("הגדרות") { showSettings = true }
                    .disabled(controller.isDriving)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
    }
}

private struct LabeledText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
