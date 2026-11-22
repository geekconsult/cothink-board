import SwiftUI
import BoardCore

enum HomeBoardScope: Hashable {
    case all
    case list(id: String)

    func boards(_ boards: [Board], lists: [BoardList], search: String) -> [Board] {
        boards.filter { board in
            if case .list(let id) = self {
                let memberIDs = lists.first(where: { $0.id == id })?.boardIDs ?? []
                if !memberIDs.contains(board.id) { return false }
            }
            return search.isEmpty
                || board.title.localizedCaseInsensitiveContains(search)
                || (board.tags ?? []).contains { $0.localizedCaseInsensitiveContains(search) }
                || board.notes.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }
}

enum HomeSort: String, CaseIterable {
    case recent, title

    var label: String { self == .recent ? "Recent" : "Title" }

    func sorted(_ boards: [Board], lastOpened: [String: Date]) -> [Board] {
        switch self {
        case .recent:
            return boards.enumerated().sorted { lhs, rhs in
                switch (lastOpened[lhs.element.id], lastOpened[rhs.element.id]) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }.map(\.element)
        case .title:
            return boards.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: BoardViewModel
    @Binding var search: String
    let onOpenBoard: (String) -> Void
    let onNewBoard: () -> Void

    @AppStorage("homeSort") private var sortRaw = HomeSort.recent.rawValue
    @AppStorage("homeCompactGrid") private var compactGrid = false
    @State private var boardToDelete: Board?
    @State private var settingsBoard: Board?
    @State private var scope: HomeBoardScope = .all

    private var sort: HomeSort {
        get { HomeSort(rawValue: sortRaw) ?? .recent }
        nonmutating set { sortRaw = newValue.rawValue }
    }

    private var effectiveScope: HomeBoardScope {
        if case .list(let id) = scope, !model.boardLists.contains(where: { $0.id == id }) { return .all }
        return scope
    }

    private var selectedList: BoardList? {
        guard case .list(let id) = effectiveScope else { return nil }
        return model.boardLists.first { $0.id == id }
    }

    private var sectionSubtitle: String {
        if !search.isEmpty { return "Boards, tags, and notes matching your search." }
        return selectedList == nil ? "A space for every idea." : "Boards in this list."
    }

    private var filteredBoards: [Board] {
        sort.sorted(effectiveScope.boards(model.boards, lists: model.boardLists, search: search), lastOpened: model.lastOpened)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            scopeToolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.boards.isEmpty {
                        emptyState
                    } else if filteredBoards.isEmpty {
                        if search.isEmpty, case .list = effectiveScope {
                            emptyListState
                        } else {
                            noResults
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(search.isEmpty ? (selectedList?.title ?? "Your boards") : "Search results")
                                    .font(.title2.weight(.semibold))
                                Text(sectionSubtitle)
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(filteredBoards.count) \(filteredBoards.count == 1 ? "board" : "boards")")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                        if search.isEmpty && effectiveScope == .all && !recentBoards.isEmpty {
                            recentlyOpened
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: compactGrid ? 150 : 205, maximum: compactGrid ? 240 : 320), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(filteredBoards) { board in
                                BoardCard(board: board, isCurrent: model.board?.id == board.id) { onOpenBoard(board.id) }
                                    .overlay(alignment: .topTrailing) {
                                        Menu {
                                            Button("Open") { onOpenBoard(board.id) }
                                            Button("Settings…") { settingsBoard = board }
                                            Divider()
                                            Button("Delete Board…", role: .destructive) { boardToDelete = board }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .frame(width: 30, height: 30)
                                                .background(.regularMaterial, in: Circle())
                                        }
                                        .menuStyle(.borderlessButton).fixedSize()
                                        .help("Actions for \(board.displayTitle)")
                                        .accessibilityLabel("Actions for \(board.displayTitle)")
                                        .padding(10)
                                    }
                                    .contextMenu {
                                        Button("Open") { onOpenBoard(board.id) }
                                        Button("Settings…") { settingsBoard = board }
                                        Divider()
                                        Button("Delete Board…", role: .destructive) { boardToDelete = board }
                                    }
                            }
                            if search.isEmpty && effectiveScope == .all { NewBoardCard(action: onNewBoard) }
                        }
                    }
                }
                .frame(maxWidth: 1320, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .confirmationDialog("Delete this board?", isPresented: Binding(get: { boardToDelete != nil }, set: { if !$0 { boardToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Board", role: .destructive) {
                if let board = boardToDelete { model.deleteBoard(id: board.id) }
                boardToDelete = nil
            }
            Button("Cancel", role: .cancel) { boardToDelete = nil }
        } message: {
            if let board = boardToDelete {
                Text("“\(board.displayTitle)” and its history will be removed from this Mac.")
            }
        }
        .sheet(item: $settingsBoard) { board in
            BoardSettingsView(model: model, board: board).frame(width: 450)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                brand
                Spacer(minLength: 20)
                searchField.frame(width: 220)
                headerActions
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { brand; Spacer(); headerActions }
                searchField
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.thinMaterial)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            MascotLogo().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("CoThink").font(.headline)
                Text("Your thinking space").font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search boards and notes", text: $search)
                .textFieldStyle(.plain).accessibilityLabel("Search boards and notes")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .font(.callout).padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button("Import", systemImage: "square.and.arrow.down", action: model.importBoard)
                .buttonStyle(.plain).modifier(GlassControl()).help("Import board")
            Button(action: onNewBoard) { Label("New Board", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .help("Create a board").accessibilityLabel("New board")
            if let current = model.board {
                Button { onOpenBoard(current.id) } label: { Image(systemName: "arrow.backward.circle") }
                    .buttonStyle(.plain).modifier(GlassControl())
                    .help("Return to the open board (Esc)")
                    .accessibilityLabel("Back to board")
            }
        }
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
                .frame(width: 68, height: 68)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Make space for your ideas").font(.title2.weight(.semibold))
            Text("Create a board to collect notes, connect ideas, and think together.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            Button("Create your first board", systemImage: "plus", action: onNewBoard)
                .buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No boards found").font(.title3.weight(.semibold))
            Text("Try a different search for “\(search)”.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Clear search") { search = "" }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private var emptyListState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No boards in this list").font(.title3.weight(.semibold))
            Text("Drag boards onto this list in the sidebar to collect them here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Show All Boards") { scope = .all }
                .buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private var scopeToolbar: some View {
        HStack(spacing: 10) {
            if !model.boardLists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        scopeChip(title: "All Boards", color: nil, active: effectiveScope == .all) { scope = .all }
                        ForEach(model.boardLists) { list in
                            scopeChip(title: list.title, color: list.color, active: effectiveScope == .list(id: list.id)) { scope = .list(id: list.id) }
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            SortMenu(sort: sort) { sort = $0 }
            Button {
                compactGrid.toggle()
            } label: {
                Image(systemName: compactGrid ? "square.grid.2x2" : "square.grid.2x3")
            }
            .buttonStyle(.plain).modifier(GlassControl())
            .help(compactGrid ? "Comfortable grid" : "Compact grid")
            .accessibilityLabel(compactGrid ? "Comfortable grid" : "Compact grid")
        }
        .padding(.horizontal, 28).padding(.top, 14)
    }

    private func scopeChip(title: String, color: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle().fill(Color(hex: color)).frame(width: 8, height: 8)
                }
                Text(title)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var recentBoards: [Board] {
        model.boards.compactMap { board in model.lastOpened[board.id].map { (board, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    private var recentlyOpened: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently opened").font(.headline)
            HStack(spacing: 12) {
                ForEach(recentBoards) { board in
                    RecentBoardCard(
                        board: board,
                        list: model.boardLists.first { $0.boardIDs.contains(board.id) },
                        timeText: model.lastOpened[board.id].map { Self.relativeFormatter.string(for: $0) ?? "" } ?? ""
                    ) { onOpenBoard(board.id) }
                }
            }
        }
    }
}

/// Isolated so the sort menu survives Home re-renders from the 1Hz board poll.
private struct SortMenu: View {
    let sort: HomeSort
    let onSelect: (HomeSort) -> Void

    var body: some View {
        Menu {
            ForEach(HomeSort.allCases, id: \.self) { candidate in
                Button(candidate.label) { onSelect(candidate) }
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort boards")
    }
}

private struct RecentBoardCard: View {
    let board: Board
    let list: BoardList?
    let timeText: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                BoardThumbnail(board: board)
                    .frame(width: 132, height: 76)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(board.displayTitle).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        if let list {
                            Text(list.title)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color(hex: list.color).opacity(0.16), in: Capsule())
                                .foregroundStyle(Color(hex: list.color))
                        }
                        Text(timeText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open \(board.displayTitle)")
    }
}

struct BoardCard: View {
    let board: Board
    let isCurrent: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    private var title: String { board.displayTitle }
    private var boardColor: Color { Color(hex: board.color ?? "#7A8BA8") }
    private var noteCount: String { "\(board.notes.count) \(board.notes.count == 1 ? "note" : "notes")" }
    private var connectionCount: String { "\(board.connections.count) \(board.connections.count == 1 ? "connection" : "connections")" }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                BoardThumbnail(board: board)
                    .frame(height: 104)
                    .overlay(alignment: .topLeading) {
                        if isCurrent {
                            Text("Open")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(10)
                        }
                    }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        if let icon = board.icon, !icon.isEmpty {
                            Text(icon).font(.body)
                        } else {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 13)).foregroundStyle(boardColor)
                        }
                        Text(title).font(.headline).lineLimit(1)
                        Spacer(minLength: 0)
                        if board.flagged == true {
                            Image(systemName: "flag.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(noteCount)
                        if !board.connections.isEmpty {
                            Text("·")
                            Text(connectionCount)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 13)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.55) : .primary.opacity(hovering ? 0.16 : 0.08), lineWidth: isCurrent ? 1.5 : 1))
            .shadow(color: .black.opacity(hovering ? 0.10 : 0.035), radius: hovering ? 12 : 5, y: hovering ? 5 : 2)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Open \(title)")
        .accessibilityLabel("\(title), \(noteCount), \(connectionCount)\(isCurrent ? ", open" : "")\(board.flagged == true ? ", flagged" : "")")
    }
}

/// A compact map of a board, derived from its visible note and group geometry.
private struct BoardThumbnail: View {
    let board: Board

    var body: some View {
        Canvas { context, size in
            let hidden = board.hiddenNoteIDs()
            let notes = board.notes.filter { !hidden.contains($0.id) }
            let groups = board.groups
            let rects = notes.map { CGRect(x: $0.x, y: $0.y, width: max($0.width, 1), height: max($0.height, 1)) }
                + groups.map { CGRect(x: $0.x, y: $0.y, width: max($0.width, 1), height: max($0.height, 1)) }
            guard let bounds = rects.reduce(nil as CGRect?, { result, rect in result.map { $0.union(rect) } ?? rect }),
                  bounds.width > 0, bounds.height > 0 else { return }
            let inset: CGFloat = 18
            let scale = min((size.width - 2 * inset) / bounds.width, (size.height - 2 * inset) / bounds.height)
            guard scale.isFinite, scale > 0 else { return }
            let offset = CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                 y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            func mapped(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y,
                       width: max(rect.width * scale, 1), height: max(rect.height * scale, 1))
            }
            for group in groups.prefix(30) {
                let frame = mapped(CGRect(x: group.x, y: group.y, width: group.width, height: group.height))
                context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Color(hex: group.color).opacity(0.4)))
            }
            let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for edge in board.connections.prefix(120) {
                guard let from = byID[edge.from], let to = byID[edge.to] else { continue }
                var line = Path()
                line.move(to: CGPoint(x: (from.x + from.width / 2) * scale + offset.x, y: (from.y + from.height / 2) * scale + offset.y))
                line.addLine(to: CGPoint(x: (to.x + to.width / 2) * scale + offset.x, y: (to.y + to.height / 2) * scale + offset.y))
                context.stroke(line, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
            }
            for note in notes.prefix(120) {
                let frame = mapped(CGRect(x: note.x, y: note.y, width: note.width, height: note.height))
                if note.shape == .line {
                    var line = Path()
                    line.move(to: CGPoint(x: frame.minX, y: note.lineFlipped == true ? frame.maxY : frame.minY))
                    line.addLine(to: CGPoint(x: frame.maxX, y: note.lineFlipped == true ? frame.minY : frame.maxY))
                    context.stroke(line, with: .color(Color(hex: note.strokeColor ?? "#6F7785")), lineWidth: 1)
                } else if note.shape == .text {
                    var textMark = Path()
                    textMark.move(to: CGPoint(x: frame.minX, y: frame.midY))
                    textMark.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                    context.stroke(textMark, with: .color(Color.secondary.opacity(0.7)), lineWidth: 1)
                } else {
                    var shape: Path
                    if note.shape == .ellipse {
                        shape = Path(ellipseIn: frame)
                    } else if note.shape == .diamond {
                        shape = Path()
                        shape.move(to: CGPoint(x: frame.midX, y: frame.minY))
                        shape.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                        shape.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
                        shape.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
                        shape.closeSubpath()
                    } else {
                        shape = Path(roundedRect: frame, cornerRadius: min(3, frame.height / 4))
                    }
                    context.fill(shape, with: .color(Color(hex: note.color)))
                    context.stroke(shape, with: .color(.black.opacity(0.16)), lineWidth: 0.5)
                }
            }
        }
        .background(Color(hex: board.wallpaperColor ?? "#F3F1EC").opacity(0.65))
        .overlay {
            if board.notes.isEmpty && board.groups.isEmpty {
                Label("Empty board", systemImage: "square.dashed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

struct NewBoardCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.primary.opacity(hovering ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text("New Board").font(.callout.weight(.medium))
                Text("Start with a blank space").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 165)
            .background(.primary.opacity(hovering ? 0.035 : 0.015), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(hovering ? 0.25 : 0.13), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Create a board")
        .accessibilityLabel("New board")
    }
}
