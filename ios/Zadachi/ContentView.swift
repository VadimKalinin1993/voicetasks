import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(TaskStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var assistant = assistant
        NavigationStack {
            List {
                ForEach(store.sections) { section in
                    Section {
                        ForEach(section.items) { task in
                            TaskRow(task: task, fresh: store.freshIDs.contains(task.id))
                        }
                    } header: {
                        Text(section.title)
                            .foregroundStyle(section.overdue ? Color.red : Color.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("Пока пусто", systemImage: "checklist")
                    } description: {
                        Text("Нажми на микрофон и скажи, например:\n«Купить продукты завтра»")
                    }
                    .padding(.bottom, 120)
                }
            }
            .navigationTitle(store.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        assistant.settingsOpen = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                    }
                    .accessibilityLabel("Настройки")
                }
            }
            .safeAreaInset(edge: .bottom) { BottomBar() }
            .sheet(isPresented: $assistant.settingsOpen) { SettingsView() }
        }
        .onAppear { assistant.gemini.warmUp() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { assistant.gemini.warmUp() }
            if newPhase == .background { assistant.cancelAll() }
        }
    }
}

// MARK: - Строка задачи

struct TaskRow: View {
    let task: TaskItem
    let fresh: Bool
    @Environment(TaskStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @State private var done = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: complete) {
                Image(systemName: done ? "largecircle.fill.circle" : "circle")
                    .font(.title2)
                    .foregroundStyle(done ? Color.blue : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Выполнено")

            VStack(alignment: .leading, spacing: 6) {
                PriorityTag(priority: task.priority) {
                    withAnimation(.snappy) { store.setPriority(task.id, task.priority.next) }
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                Text(task.title)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .listRowBackground(fresh ? Color.blue.opacity(0.12) : Color(.secondarySystemGroupedBackground))
        .animation(.easeOut(duration: 0.8), value: fresh)
        .swipeActions(edge: .trailing) {
            Button {
                assistant.complete([task.id])
            } label: {
                Label("Готово", systemImage: "checkmark")
            }
            .tint(.blue)
        }
    }

    private func complete() {
        guard !done else { return }
        withAnimation(.snappy(duration: 0.2)) { done = true }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            assistant.complete([task.id])
        }
    }
}

struct PriorityTag: View {
    let priority: Priority
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(priority.color)
                    .frame(width: 6, height: 6)
                Text(priority.label)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(priority.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(priority.color.opacity(0.12), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Приоритет: \(priority.label)")
        .accessibilityHint("Нажми, чтобы сменить")
    }
}

// MARK: - Нижняя панель

struct BottomBar: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(spacing: 12) {
            if let bubble = assistant.bubble {
                BubbleView(bubble: bubble)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let toast = assistant.toast {
                ToastView(text: toast) { assistant.undo() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            MicButton(phase: assistant.phase, level: assistant.speech.level) {
                assistant.micTapped()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemGroupedBackground).opacity(0), location: 0),
                    .init(color: Color(.systemGroupedBackground), location: 0.35)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .animation(.snappy, value: assistant.bubble)
        .animation(.snappy, value: assistant.toast)
    }
}

struct BubbleView: View {
    let bubble: Assistant.Bubble
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let heard = bubble.heard, !heard.isEmpty {
                    Text("«\(heard)»")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(bubble.text)
            }
            Spacer(minLength: 0)
            Button {
                assistant.dismissBubble()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .accessibilityLabel("Закрыть")
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}

struct ToastView: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Вернуть", action: undo)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}
