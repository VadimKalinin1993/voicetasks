import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(TaskStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @Environment(\.scenePhase) private var scenePhase
    /// Экран «Выполнено» — режим просмотра сделанного, без действий.
    @State private var showDone: Bool

    init(startInDone: Bool = false) {
        _showDone = State(initialValue: startInDone)
    }

    var body: some View {
        @Bindable var assistant = assistant
        NavigationStack {
            Group {
                if showDone { doneList } else { taskList }
            }
            .navigationTitle(showDone ? "Выполнено" : store.title)
            .navigationBarTitleDisplayMode(.inline)   // маленький заголовок сразу: главное на экране — задачи
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModeButton(showDone: showDone, pulse: store.done.count) {
                        if !showDone { assistant.cancelAll() }
                        withAnimation(.snappy) { showDone.toggle() }
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        assistant.settingsOpen = true
                    } label: {
                        ToolbarIcon(name: "gearshape")
                    }
                    .accessibilityLabel("Настройки")
                }
            }
            .sheet(isPresented: $assistant.settingsOpen) { SettingsView() }
        }
        .onAppear { assistant.gemini.warmUp() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                store.refreshDay()
                assistant.gemini.warmUp()
                // Фразы, которые не успели уйти (закрыли приложение, не было сети), отправляем снова.
                Task { await assistant.flushQueue() }
            }
            if newPhase == .background { assistant.cancelAll() }
        }
        // Полночь (и смена часового пояса): «Сегодня» становится «Просрочено», «Завтра» — «Сегодня».
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            store.refreshDay()
        }
    }

    // MARK: Главный список

    private var taskList: some View {
        List {
            ForEach(store.sections) { section in
                Section {
                    ForEach(section.items) { task in
                        TaskRow(task: task, fresh: store.freshIDs.contains(task.id))
                    }
                    .onMove { from, to in
                        withAnimation(.snappy) { store.move(section: section.id, from: from, to: to) }
                    }
                } header: {
                    Text(section.title)
                        .foregroundStyle(section.overdue ? Color.orange : Color.secondary)
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
        // Сообщения лежат поверх списка и не меняют высоту нижней панели —
        // поэтому за ними ничего не тянется и список не прыгает.
        .overlay(alignment: .bottom) { Messages() }
        .safeAreaInset(edge: .bottom) { BottomBar() }
    }

    // MARK: Выполнено

    private var doneList: some View {
        List {
            ForEach(store.doneSections) { section in
                Section {
                    ForEach(section.items) { task in
                        DoneRow(task: task)
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if store.done.isEmpty {
                ContentUnavailableView {
                    Label("Пока ничего не выполнено", systemImage: "checkmark.circle")
                } description: {
                    Text("Здесь будут задачи, которые ты закрыл.")
                }
            }
        }
    }
}

/// Левая кнопка в шапке — такая же системная иконка, как шестерёнка:
/// на главном экране «статистика», на экране «Выполнено» — микрофон.
/// Когда закрываешь задачу, за иконкой на долю секунды вспыхивает мягкий свет, как у кнопки записи.
struct ModeButton: View {
    let showDone: Bool
    let pulse: Int
    let action: () -> Void
    @State private var glow = false

    var body: some View {
        Button(action: action) {
            ToolbarIcon(name: showDone ? "mic" : "chart.bar")
                .contentTransition(.symbolEffect(.replace))
                .background {
                    Circle()
                        .fill(AngularGradient(
                            colors: [MicButton.blue, MicButton.cyan, MicButton.violet, MicButton.blue],
                            center: .center))
                        .frame(width: 34, height: 34)
                        .blur(radius: 8)
                        .scaleEffect(glow ? 1.1 : 0.5)
                        .opacity(glow ? 0.85 : 0)
                        .allowsHitTesting(false)
                }
        }
        .accessibilityLabel(showDone ? "Вернуться к задачам" : "Выполненные задачи")
        .onChange(of: pulse) { old, new in
            guard new > old, !showDone else { return }
            withAnimation(.easeOut(duration: 0.15)) { glow = true }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeIn(duration: 0.35)) { glow = false }
            }
        }
    }
}

/// Иконка в шапке: у всех кнопок одинаковый размер глифа и рамки,
/// поэтому стеклянные кружки шестерёнки и статистики совпадают.
struct ToolbarIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .frame(width: 22, height: 22)
            .frame(width: 30, height: 30)
    }
}

// MARK: - Строка задачи

struct TaskRow: View {
    /// Скругление карточек списка в iOS 26.
    static let cornerRadius: CGFloat = 26

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
                    withAnimation(.snappy) { _ = store.setPriority(task.id, task.priority.next) }
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                Text(task.title)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // Строка занимает всю ячейку: отступы те же, что ставит система (20 по бокам, 15 сверху и снизу),
        // только теперь они внутри строки. Тогда поднятая при перетаскивании ячейка
        // обрезается по скруглённой форме, как карточки списка, и тень идёт по ней же.
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .listRowInsets(EdgeInsets())
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: TaskRow.cornerRadius, style: .continuous))
        .listRowBackground(fresh ? Color.blue.opacity(0.12) : Color(.secondarySystemGroupedBackground))
        .animation(.easeOut(duration: 0.8), value: fresh)
        // Свайп влево — удалить совсем (кружок — в «Выполнено»).
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                assistant.delete(task.id)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
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

/// Строка в истории: выглядит как обычная задача, но отмечена выполненной и без действий.
struct DoneRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.blue)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                PriorityLabel(priority: task.priority)
                Text(task.title)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue("Выполнено")
    }
}

struct PriorityTag: View {
    let priority: Priority
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PriorityLabel(priority: priority)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Приоритет: \(priority.label)")
        .accessibilityHint("Нажми, чтобы сменить")
    }
}

/// Сам тег приоритета (без действия).
struct PriorityLabel: View {
    let priority: Priority

    var body: some View {
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
    }
}

// MARK: - Нижняя панель

/// Только кнопка микрофона и мягкий переход списка под неё. Высота постоянная.
struct BottomBar: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        MicButton(phase: assistant.phase, level: assistant.speech.level) {
            assistant.micTapped()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        // Лёгкая дымка только у самого низа: прячет край контента, но не съедает экран.
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemGroupedBackground).opacity(0), location: 0),
                    .init(color: Color(.systemGroupedBackground), location: 0.6)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 60)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

/// Сообщение или «Готово · Вернуть» над кнопкой микрофона — сами по себе, без подложки.
struct Messages: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack {
            if let bubble = assistant.bubble {
                BubbleView(bubble: bubble)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let toast = assistant.toast {
                ToastView(text: toast) { assistant.undo() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
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
        .glassCard(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .glassCard(Capsule())
    }
}

extension View {
    /// Подложка сообщений: Liquid Glass, как у кнопки микрофона (iOS 26+);
    /// на старых системах — системный материал с мягкой тенью.
    @ViewBuilder
    func glassCard<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        }
    }
}
