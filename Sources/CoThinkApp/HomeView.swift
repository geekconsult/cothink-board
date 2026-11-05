import SwiftUI
import BoardCore

/// App home screen: every board as a card in a paged grid, 12 boards per page.
struct HomeView: View {
    static let pageSize = 12

    @ObservedObject var model: BoardViewModel
    @Binding var search: String
    let onOpenBoard: (String) -> Void
    let onNewBoard: () -> Void

    @State private var page = 0
    @State private var boardToDelete: Board?
    @State private var settingsBoard: Board?

    private var filteredBoards: [Board] {
        model.boards.filter { board in
            search.isEmpty
                || board.title.localizedCaseInsensitiveContains(search)
                || (board.tags ?? []).contains { $0.localizedCaseInsensitiveContains(search) }
                || board.notes.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    private var pageCount: Int { max(1, (filteredBoards.count + Self.pageSize - 1) / Self.pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var pageBoards: [Board] { Array(filteredBoards.dropFirst(currentPage * Self.pageSize).prefix(Self.pageSize)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 18) {
                    ForEach(pageBoards) { board in
                        BoardCard(board: board, isCurrent: model.board?.id == board.id) { onOpenBoard(board.id) }
                            .contextMenu {
                                Button("Open") { onOpenBoard(board.id) }
                                Button("Settings…") { settingsBoard = board }
                                Divider()
                                Button("Delete Board…", role: .destructive) { boardToDelete = board }
                            }
                    }
                    NewBoardCard(action: onNewBoard)
                }
                .padding(24)
                if filteredBoards.isEmpty && !search.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No boards match “\(search)”").font(.title3)
                        Text("Try another search.").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                }
            }
            Divider()
            pageBar
        }
        .confirmationDialog("Delete this board?", isPresented: Binding(get: { boardToDelete != nil }, set: { if !$0 { boardToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Board", role: .destructive) {
                if let board = boardToDelete { model.deleteBoard(id: board.id) }
                boardToDelete = nil
            }
            Button("Cancel", role: .cancel) { boardToDelete = nil }
        } message: {
            if let board = boardToDelete {
                Text("“\(board.title.isEmpty ? "Untitled board" : board.title)” and its history will be removed from this Mac.")
            }
        }
        .sheet(item: $settingsBoard) { board in
            BoardSettingsView(model: model, board: board).frame(width: 450)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MascotLogo().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("CoThink").font(.title3.bold())
                Text("\(model.boards.count) boards").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search boards", text: $search)
                    .textFieldStyle(.plain).accessibilityLabel("Search boards")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .frame(width: 220)
            Button("Import", systemImage: "square.and.arrow.down", action: model.importBoard)
                .buttonStyle(.plain).modifier(GlassControl()).help("Import board")
            Button(action: onNewBoard) { Label("New Board", systemImage: "plus") }
                .buttonStyle(.plain).modifier(GlassControl()).help("Create a board").accessibilityLabel("New board")
            if let current = model.board {
                Button { onOpenBoard(current.id) } label: { Label("Back to Board", systemImage: "arrow.backward.circle") }
                    .buttonStyle(.plain).modifier(GlassControl())
                    .help("Return to the open board (Esc)")
                    .accessibilityLabel("Back to board")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var pageBar: some View {
        HStack(spacing: 14) {
            Text("\(filteredBoards.count) boards").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { page = currentPage - 1 } label: { Image(systemName: "chevron.left").frame(width: 16, height: 16) }
                .buttonStyle(.plain).modifier(GlassControl())
                .disabled(currentPage == 0).help("Previous page")
                .accessibilityLabel("Previous page")
            Text("Page \(currentPage + 1) of \(pageCount)")
                .font(.callout.monospacedDigit()).frame(minWidth: 96)
                .accessibilityLabel("Page \(currentPage + 1) of \(pageCount)")
            Button { page = currentPage + 1 } label: { Image(systemName: "chevron.right").frame(width: 16, height: 16) }
                .buttonStyle(.plain).modifier(GlassControl())
                .disabled(currentPage >= pageCount - 1).help("Next page")
                .accessibilityLabel("Next page")
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct BoardCard: View {
    let board: Board
    let isCurrent: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Group {
                    if let icon = board.icon, !icon.isEmpty {
                        Text(icon).font(.system(size: 32))
                    } else {
                        Image(systemName: "square.grid.2x2").font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Color(hex: board.color ?? "#7A8BA8"))
                    }
                }
                Spacer()
                if board.flagged == true {
                    Image(systemName: "flag.fill").font(.caption).foregroundStyle(.secondary)
                        .help("Flagged")
                }
            }
            Spacer(minLength: 0)
            Text(board.title.isEmpty ? "Untitled board" : board.title)
                .font(.headline).lineLimit(2, reservesSpace: true)
            Text("\(board.notes.count) note\(board.notes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(Color(hex: board.color ?? "#7A8BA8").opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.8) : .primary.opacity(hovering ? 0.16 : 0.08),
                              lineWidth: isCurrent ? 2 : 1)
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.04), radius: hovering ? 8 : 3, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .animation(.snappy(duration: 0.15), value: hovering)
        .help("Open \(board.title.isEmpty ? "Untitled board" : board.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(board.title), \(board.notes.count) notes")
    }
}

struct NewBoardCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
            Text("New Board").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.05 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.primary.opacity(hovering ? 0.3 : 0.15))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.snappy(duration: 0.15), value: hovering)
        .help("Create a board")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("New board")
    }
}
