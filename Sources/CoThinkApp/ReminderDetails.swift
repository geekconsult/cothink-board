import SwiftUI
import EventKit

enum ReminderPriority: Int, CaseIterable {
    case none = 0, high = 1, medium = 5, low = 9
    init(value: Int) {
        switch value {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    var label: String { String(describing: self).capitalized }
}

struct ReminderDetails: Equatable {
    var listID: String
    var priority: ReminderPriority
    var scheduled: Bool
    var date: Date

    init(item: EKReminder? = nil, defaultList: EKCalendar? = nil) {
        listID = (item?.calendar ?? defaultList)?.calendarIdentifier ?? ""
        priority = ReminderPriority(value: item?.priority ?? 0)
        let components = item?.dueDateComponents
        let due = components.flatMap { ($0.calendar ?? Calendar(identifier: .gregorian)).date(from: $0) }
        let alarm = item?.alarms?.first { $0.structuredLocation == nil }
        let alert = alarm.flatMap { alarm in alarm.absoluteDate ?? due?.addingTimeInterval(alarm.relativeOffset) }
        scheduled = alert != nil || (components?.hour != nil && due != nil)
        date = alert ?? due ?? Date().addingTimeInterval(3600)
    }

    func apply(to item: EKReminder, calendar: EKCalendar, original: ReminderDetails?) {
        if original?.listID != listID { item.calendar = calendar }
        if original?.priority != priority { item.priority = priority.rawValue }
        guard original?.scheduled != scheduled || (scheduled && original?.date != date) else { return }

        if let primary = item.alarms?.first(where: { $0.structuredLocation == nil }) { item.removeAlarm(primary) }
        if scheduled {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = .current
            let components = gregorian.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: date)
            item.dueDateComponents = components
            item.addAlarm(EKAlarm(absoluteDate: components.date ?? date))
        } else {
            item.dueDateComponents = nil
        }
    }
}

struct ReminderListPicker: View {
    let lists: [EKCalendar]
    @Binding var listID: String

    var body: some View {
        Picker("Apple Reminders list", selection: $listID) {
            if !lists.contains(where: { $0.calendarIdentifier == listID }) {
                Text("Select a list").tag(listID)
            }
            ForEach(lists, id: \.calendarIdentifier) { calendar in
                Text("\(calendar.title) · \(calendar.source.title)").tag(calendar.calendarIdentifier)
            }
        }
    }
}

struct ReminderFields<FlagControl: View>: View {
    let lists: [EKCalendar]
    @Binding var details: ReminderDetails
    var showsList = true
    @ViewBuilder var flagControl: () -> FlagControl

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                if showsList {
                    row("Apple Reminders list", icon: "list.bullet") {
                        ReminderListPicker(lists: lists, listID: $details.listID).labelsHidden()
                    }
                    Divider().padding(.leading, 40)
                }
                row("Remind me", icon: "bell") {
                    Toggle("Remind me", isOn: $details.scheduled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                if details.scheduled {
                    DatePicker("Reminder date and time", selection: $details.date,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().padding(.horizontal, 12).padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }.modifier(ReminderSurface())

            HStack(spacing: 10) {
                row("Priority", icon: "exclamationmark") {
                    Picker("Priority", selection: $details.priority) {
                        ForEach(ReminderPriority.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().fixedSize()
                }.modifier(ReminderSurface())
                row("Flagged", icon: "flag") { flagControl() }
                    .modifier(ReminderSurface())
            }
        }
    }

    private func row<Control: View>(_ title: String, icon: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                .accessibilityHidden(true)
            Text(title).font(.callout).accessibilityHidden(true)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12).frame(minHeight: 38)
    }
}

struct ReminderSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09))
                    .allowsHitTesting(false)
            }
    }
}

struct ReminderPanelMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).modifier(ReminderSurface())
    }
}

extension BoardReminder {
    static var writableLists: [EKCalendar] {
        store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }
}

/// Reminders exposes its flag through Apple Events. Pass identifiers as script
/// arguments so reminder content never becomes executable source.
enum AppleReminderFlag {
    static func access(id: String, listID: String, set value: Bool? = nil) async throws -> Bool {
        let script = """
        on run argv
            set reminderID to item 1 of argv
            set listID to item 2 of argv
            set operation to item 3 of argv
            tell application id "com.apple.reminders"
                set entry to reminder id reminderID of list id listID
                if operation is "on" then set flagged of entry to true
                if operation is "off" then set flagged of entry to false
                return flagged of entry
            end tell
        end run
        """
        return try await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script, "x-apple-reminder://" + id, listID,
                              value.map { $0 ? "on" : "off" } ?? "read"]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = output
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard task.terminationStatus == 0, let flag = Bool(text) else {
                throw NSError(domain: "CoThink.ReminderFlag", code: Int(task.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: text.contains("-1743")
                        ? "Allow CoThink Board to control Reminders in System Settings → Privacy & Security → Automation."
                        : "Apple Reminders could not access the flag. " + text
                ])
            }
            return flag
        }.value
    }
}

struct ReminderEditor: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var details = ReminderDetails()
    @State private var original: ReminderDetails?
    @State private var lists: [EKCalendar] = []
    @State private var title = ""
    @State private var originalFlag: Bool?
    @State private var flag = false
    @State private var flagLoading = true
    @State private var message: String?
    @State private var saving = false

    private func lookup() -> EKReminder? {
        BoardReminder.store.calendarItem(withIdentifier: id) as? EKReminder
    }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Edit Reminder", subtitle: title, icon: "pencil").padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if original != nil {
                    ReminderFields(lists: lists, details: $details) {
                        if flagLoading {
                            ProgressView().controlSize(.small).accessibilityLabel("Loading flag")
                        } else if originalFlag == nil {
                            Button("Retry") { Task { await loadFlag() } }
                                .accessibilityLabel("Retry loading flag")
                        } else {
                            Toggle("Flagged", isOn: $flag).labelsHidden()
                                .toggleStyle(.switch).controlSize(.mini)
                        }
                    }
                }
                if let message { ReminderPanelMessage(message: message) }
            }.padding(24)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving reminder") }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Changes") { Task { await save() } }
                    .modifier(AppPrimaryAction()).keyboardShortcut(.defaultAction)
                    .disabled(original == nil || !lists.contains { $0.calendarIdentifier == details.listID })
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 500).modifier(AppPanelBackground()).disabled(saving).interactiveDismissDisabled(saving)
        .task {
            guard let item = lookup() else { message = "This reminder is unavailable."; return }
            lists = BoardReminder.writableLists
            title = item.title ?? "Reminder"
            details = ReminderDetails(item: item)
            original = details
            await loadFlag()
        }
    }

    @MainActor private func loadFlag() async {
        guard let item = lookup() else { flagLoading = false; return }
        flagLoading = true
        defer { flagLoading = false }
        do {
            flag = try await BoardReminder.readFlag(for: item)
            originalFlag = flag
            message = nil
        } catch { message = error.localizedDescription }
    }

    @MainActor private func save() async {
        guard !saving, let original, let item = lookup(),
              let calendar = BoardReminder.writableLists.first(where: { $0.calendarIdentifier == details.listID })
        else { message = "The reminder or its list is unavailable."; return }
        saving = true
        defer { saving = false }
        do {
            if original != details {
                details.apply(to: item, calendar: calendar, original: original)
                try BoardReminder.store.save(item, commit: true)
                self.original = details
            }
            if let originalFlag, originalFlag != flag {
                _ = try await BoardReminder.readFlag(for: item, set: flag)
            }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
