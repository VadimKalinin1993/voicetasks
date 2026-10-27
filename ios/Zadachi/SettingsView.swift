import SwiftUI

struct SettingsView: View {
    @Environment(Assistant.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    @State private var key = Keychain.get("apiKey") ?? ""
    @State private var checking = false
    @State private var status: String?
    @State private var details: String?
    @AppStorage("autoListen") private var autoListen = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Ключ API", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Проверить ключ")
                            Spacer()
                            if checking {
                                ProgressView()
                            } else if let status {
                                Text(status).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(key.isEmpty || checking)
                } header: {
                    Text("Gemini")
                } footer: {
                    if let details {
                        Text(details)
                    } else {
                        Text("Ключ из Google AI Studio. Хранится только на этом телефоне.")
                    }
                }

                Section {
                    Toggle("Сразу слушать ответ", isOn: $autoListen)
                } footer: {
                    Text("Если срок задачи не назван, приложение спросит его и сразу начнёт слушать ответ. Вслух вопросы звучат только при включённом VoiceOver.")
                }

                if let t = assistant.timing {
                    Section("Последний запрос") {
                        LabeledContent("Модель", value: t.model)
                        LabeledContent("Запись", value: seconds(t.speech))
                        LabeledContent("Ответ Gemini", value: seconds(t.ai))
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        save()
                        dismiss()
                    }
                }
            }
            .onDisappear { save() }
        }
    }

    private func seconds(_ s: Double) -> String {
        String(format: "%.1f с", s)
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (Keychain.get("apiKey") ?? "") {
            Keychain.set(trimmed, for: "apiKey")
            assistant.gemini.resetModels()
        }
    }

    private func check() async {
        save()
        checking = true
        details = nil
        defer { checking = false }
        do {
            let r = try await assistant.gemini.test()
            status = "Работает ✓ " + seconds(Double(r.ms) / 1000)
            details = "Модель: \(r.model)"
        } catch let e as GeminiError {
            status = e.isKey ? "Ключ не подошёл" : "Ошибка"
            details = e.message
        } catch {
            status = "Нет связи"
            details = error.localizedDescription
        }
    }
}
