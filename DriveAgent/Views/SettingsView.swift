import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SettingsStore.load()

    private let models = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]

    var body: some View {
        NavigationStack {
            Form {
                Section("בעלים") {
                    TextField("שם המשתמש", text: $settings.ownerName)
                }
                Section {
                    TextField("שם העוזר", text: $settings.assistantName)
                } header: {
                    Text("שם העוזר ומילת ההפעלה")
                } footer: {
                    Text("אומרים את השם הזה כדי להפעיל את העוזר. כדאי לבחור שם שלא נאמר הרבה בשיחה רגילה.")
                }
                Section("Claude") {
                    SecureField("מפתח API", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("מודל", selection: $settings.model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("הודעות וואטסאפ נכנסות") {
                    Text("הקראת הודעות נעשית דרך סירי: הגדרות ← Siri ← הכרזת התראות, והפעלה עבור WhatsApp.")
                }
            }
            .navigationTitle("הגדרות")
            .toolbar {
                Button("שמור") {
                    if settings.assistantName.trimmingCharacters(in: .whitespaces).isEmpty {
                        settings.assistantName = SettingsStore.defaultAssistantName
                    }
                    SettingsStore.save(settings)
                    dismiss()
                }
            }
        }
    }
}
