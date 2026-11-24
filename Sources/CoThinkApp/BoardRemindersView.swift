import SwiftUI
import EventKit
import BoardCore

/// EventKit owns these records. The board link survives renames and keeps
/// revisions, undo, and imported board copies independent of personal tasks.
struct BoardRemindersView: View {
    let board: Board
    let boxID: String?
    let place: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    private let store = BoardReminder.store
    @State private var reminders: [EKReminder] = []
    @State private var authorized = false
    @FocusState private var editingTitle: Bool
    @State private var title = ""
    @State private var details = ReminderDetails()
    @State private var lists: [EKCalendar] = []
    @State private var flagged = false
    @State private var showingOptions = false
    @State private var saving = false
    @State private var editing: ReminderEditorTarget?
    @State private var message: String?
    @State private var reloadID = UUID()

    @State private var loadedListID: String?

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: boxID == nil ? "Board Reminders" : "Add to Reminder Box",
                                subtitle: board.displayTitle, icon: "checklist", closeLabel: "Close reminders", close: { dismiss() })
                .padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if authorized {
                composer
                Divider()
                existingReminders
            } else {
                Text("Allow access to Apple Reminders to create and view this board’s reminders.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            if let message {
                ReminderPanelMessage(message: message).padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .frame(width: 520)
        .modifier(AppPanelBackground())
        .disabled(saving).interactiveDismissDisabled(saving)
        .sheet(item: $editing) { target in ReminderEditor(id: target.id) }
        .task {
            do {
                authorized = try await store.requestFullAccessToReminders()
                if authorized {
                    lists = BoardReminder.writableLists
                    let preferred = store.defaultCalendarForNewReminders()?.calendarIdentifier
                    details.listID = lists.first(where: { $0.calendarIdentifier == preferred })?.calendarIdentifier
                        ?? lists.first?.calendarIdentifier ?? ""
                }
                else { message = "Enable CoThink Board in System Settings → Privacy & Security → Reminders." }
            } catch { message = error.localizedDescription }
        }
        .task(id: details.listID) { if authorized { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)) { _ in
            if authorized { Task { await refresh() } }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("What should you remember?", text: $title)
                    .accessibilityLabel("Reminder title")
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($editingTitle).onSubmit(add)
                    .onAppear { editingTitle = true }
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Adding reminder") }
                Button(boxID == nil ? "Add to Board" : "Add to Box", action: add)
                    .modifier(AppPrimaryAction())
                    .disabled(trimmedTitle.isEmpty || !lists.contains { $0.calendarIdentifier == details.listID })
            }
            ReminderListPicker(lists: lists, listID: $details.listID)
            DisclosureGroup(isExpanded: $showingOptions) {
                ReminderFields(lists: lists, details: $details, showsList: false) {
                    Toggle("Flagged", isOn: $flagged).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }.padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text("Options").fontWeight(.medium)
                    Spacer()
                    if details.scheduled { Image(systemName: "bell.fill").accessibilityLabel("Scheduled") }
                    if flagged { Image(systemName: "flag.fill").accessibilityLabel("Flagged") }
                    if details.priority != .none { Text(details.priority.label) }
                }.font(.callout)
            }.padding(12).modifier(GlassFloatingSurface())
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var existingReminders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Existing reminders").font(.headline).accessibilityAddTraits(.isHeader)
            if loadedListID != details.listID && !details.listID.isEmpty {
                ProgressView("Loading reminders…").controlSize(.small)
            } else if reminders.isEmpty {
                Text("No reminders in this list")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(reminders, id: \.calendarItemIdentifier) { reminder in
                            reminderRow(reminder)
                            if reminder.calendarItemIdentifier != reminders.last?.calendarItemIdentifier {
                                Divider().padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .frame(height: min(162, CGFloat(reminders.count) * 55))
                .modifier(ReminderSurface())
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func reminderRow(_ reminder: EKReminder) -> some View {
        HStack(spacing: 10) {
            Button { toggle(reminder) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).frame(width: 24, height: 28)
            }.buttonStyle(.borderless)
                .accessibilityLabel(reminder.isCompleted ? "Mark incomplete" : "Mark complete")
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title ?? "").font(.callout.weight(.medium))
                    .strikethrough(reminder.isCompleted).lineLimit(1).help(reminder.title ?? "")
                HStack(spacing: 7) {
                    Text(reminder.calendar.title)
                    if let components = reminder.dueDateComponents,
                       let date = (components.calendar ?? Calendar(identifier: .gregorian)).date(from: components) {
                        Text(date.formatted(date: .abbreviated, time: components.hour == nil ? .omitted : .shortened))
                    }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { editing = ReminderEditorTarget(id: reminder.calendarItemIdentifier) } label: {
                Image(systemName: "pencil").frame(width: 25, height: 28)
            }.buttonStyle(.borderless).accessibilityLabel("Edit reminder").help("Edit reminder")
            if canPlace(reminder.calendarItemIdentifier) {
                Button(boxID == nil ? "Place on Board" : "Add to Box") { placeOnBoard(reminder) }
                    .controlSize(.small)
            }
        }.padding(.horizontal, 10).frame(height: 54)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    @MainActor private func refresh() async {
        lists = BoardReminder.writableLists
        let request = UUID()
        reloadID = request
        let listID = details.listID
        guard let calendar = lists.first(where: { $0.calendarIdentifier == listID }) else {
            reminders = []
            loadedListID = listID
            return
        }
        let predicate = store.predicateForReminders(in: [calendar])
        let result: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, reloadID == request, details.listID == listID else { return }
        loadedListID = listID
        guard let result else { reminders = []; message = "Could not read Apple Reminders."; return }
        reminders = BoardReminder.inList(listID, items: result)
    }

    private func add() {
        guard !saving, !trimmedTitle.isEmpty else { return }
        guard let calendar = BoardReminder.writableLists.first(where: { $0.calendarIdentifier == details.listID }) else {
            message = "Select a writable Apple Reminders list."
            return
        }
        let item = BoardReminder.make(in: store, calendar: calendar, boardID: board.id,
                                      title: trimmedTitle, due: nil)
        details.apply(to: item, calendar: calendar, original: nil)
        do { try store.save(item, commit: true) }
        catch { message = error.localizedDescription; return }
        title = ""
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                if flagged {
                    try await BoardReminder.readFlag(for: item, set: true)
                }
                placeOnBoard(item)
            } catch {
                let placed = place(item.calendarItemIdentifier, item.title ?? "Reminder")
                message = (placed ? "Reminder added to the board." : "Reminder saved to Apple Reminders.")
                    + " The flag was not saved. " + error.localizedDescription
            }
            await refresh()
        }
    }

    private func canPlace(_ id: String) -> Bool {
        let destinations = board.notes.filter { boxID == nil || $0.id == boxID }
        return !destinations.contains { $0.reminderItems.contains { $0.id == id } }
    }

    private func placeOnBoard(_ reminder: EKReminder) {
        if place(reminder.calendarItemIdentifier, reminder.title ?? "Reminder") {
            message = nil
            if boxID == nil { dismiss() } else { editingTitle = true }
        }
        else { message = "Reminder saved. Select it again to retry." }
    }

    private func toggle(_ reminder: EKReminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
              item.calendar.calendarIdentifier == details.listID else { Task { await refresh() }; return }
        item.isCompleted.toggle()
        do { try store.save(item, commit: true); message = nil }
        catch { message = error.localizedDescription }
        Task { await refresh() }
    }
}

enum BoardReminder {
    static let store = EKEventStore()
    @MainActor static var knownFlags: [String: Bool] = [:]

    @MainActor @discardableResult
    static func readFlag(for item: EKReminder, set value: Bool? = nil) async throws -> Bool {
        let id = item.calendarItemIdentifier
        let current = try await AppleReminderFlag.access(id: id, listID: item.calendar.calendarIdentifier, set: value)
        knownFlags[id] = current
        return current
    }

    static func link(for boardID: String) -> URL {
        URL(string: "cothink://board")!.appendingPathComponent(boardID)
    }

    static func inList(_ listID: String, items: [EKReminder]) -> [EKReminder] {
        return items.filter { $0.calendar?.calendarIdentifier == listID }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
    }

    static func make(in store: EKEventStore, calendar: EKCalendar, boardID: String,
                     title: String, due: Date?) -> EKReminder {
        let item = EKReminder(eventStore: store)
        item.calendar = calendar
        item.title = title
        item.url = link(for: boardID)
        if let due {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            item.dueDateComponents = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: due)
            item.addAlarm(EKAlarm(absoluteDate: due))
        }
        return item
    }
}

struct ReminderBoxContent: View {
    let note: Note
    var add: (() -> Void)?

    private static func displayDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label((note.reminderID == nil ? note.reminderSnapshots?.count : note.reminderItems.count) == 1 ? "Reminder" : "Reminders", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let add {
                    Button(action: add) { Image(systemName: "plus.circle").padding(3) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add reminder to this box")
                        .help("Add reminder to this box")
                }
            }
            if note.reminderID != nil {
                ForEach(note.reminderItems) { reference in
                    CanvasReminderContent(reminderID: reference.id, fallbackTitle: reference.title)
                }
            } else {
                let snapshots = note.reminderSnapshots ?? []
                ForEach(snapshots.indices, id: \.self) { index in
                    let row = snapshots[index]
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: row.completed == true ? "checkmark.circle.fill" : "circle")
                            .accessibilityLabel(row.completed == true ? "Complete" : "Open")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.headline).strikethrough(row.completed == true)
                            if let due = row.due { Text(Self.displayDate(due)).font(.caption) }
                            let priority = ReminderPriority(value: row.priority ?? 0)
                            if priority != .none { Text(priority.label + " priority").font(.caption) }
                        }
                        if row.flagged == true { Image(systemName: "flag.fill").accessibilityLabel("Flagged") }
                    }
                }
            }
        }
    }
}

private struct ReminderEditorTarget: Identifiable { let id: String }

private struct CanvasReminderContent: View {
    let reminderID: String
    let fallbackTitle: String
    @State private var title: String?
    @State private var editing = false
    @State private var priority = ReminderPriority.none
    @State private var completed = false
    @State private var due: String?
    @State private var error: String?

    private func lookup() -> EKReminder? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let item = BoardReminder.store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return nil }
        return item
    }

    private func reload() {
        let item = lookup()
        title = item?.title
        completed = item?.isCompleted ?? false
        priority = ReminderPriority(value: item?.priority ?? 0)
        due = item?.dueDateComponents.flatMap { components in
            let date = (components.calendar ?? Calendar(identifier: .gregorian)).date(from: components)
            return date?.formatted(date: .abbreviated, time: components.hour == nil ? .omitted : .shortened)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Button {
                    guard let item = lookup() else { reload(); return }
                    item.isCompleted = !completed
                    do { try BoardReminder.store.save(item, commit: true) }
                    catch { self.error = error.localizedDescription }
                    reload()
                } label: {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain).disabled(title == nil)
                .accessibilityLabel(completed ? "Mark incomplete" : "Mark complete")
                Text(title ?? fallbackTitle).font(.headline).strikethrough(completed)
                Spacer(minLength: 2)
                if title != nil {
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).accessibilityLabel("Edit reminder")
                        .help("Edit list, reminder time, flag, and priority")
                }
            }
            if title == nil { Text("Unavailable in Apple Reminders").font(.caption) }
            else {
                HStack {
                    if let due { Text(due) }
                    if priority != .none { Text(priority.label + " priority") }
                }.font(.caption)
            }
        }
        .sheet(isPresented: $editing, onDismiss: reload) { ReminderEditor(id: reminderID) }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: BoardReminder.store)) { _ in reload() }
        .alert("Could not update reminder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

extension BoardViewModel {
    func updateCloudReminderSnapshots() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let store else { return }
        let timestamp = ISO8601DateFormatter()
        var cache: [String: CloudReminderItem] = [:]
        var updates: [Board] = []
        for board in try store.list() {
            var edited = board
            for index in edited.notes.indices {
                var note = edited.notes[index]
                let references = note.reminderItems
                guard !references.isEmpty else { continue }
                let previous = note.reminderSnapshots ?? []
                note.reminderSnapshots = references.enumerated().map { offset, reference in
                    let old = previous.indices.contains(offset) ? previous[offset] : nil
                    if let snapshot = cache[reference.id] {
                        var result = snapshot
                        result.flagged = result.flagged ?? old?.flagged
                        return result
                    }
                    guard let item = BoardReminder.store.calendarItem(withIdentifier: reference.id) as? EKReminder
                    else { return old ?? CloudReminderItem(title: reference.title) }
                    let details = ReminderDetails(item: item)
                    let due: String?
                    if details.scheduled {
                        due = timestamp.string(from: details.date)
                    } else if let parts = item.dueDateComponents, let y = parts.year, let m = parts.month, let d = parts.day {
                        due = String(format: "%04d-%02d-%02d", y, m, d)
                    } else {
                        due = nil
                    }
                    let snapshot = CloudReminderItem(title: item.title ?? reference.title, completed: item.isCompleted,
                                                     due: due, priority: details.priority.rawValue,
                                                     flagged: BoardReminder.knownFlags[reference.id])
                    cache[reference.id] = snapshot
                    var result = snapshot
                    result.flagged = result.flagged ?? old?.flagged
                    return result
                }
                edited.notes[index] = note
            }
            if edited != board { updates.append(edited) }
        }
        try store.refreshReminderSnapshots(updates)
    }
}
