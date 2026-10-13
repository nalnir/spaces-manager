import AppKit
import ApplicationServices
import Combine
import Carbon
import CoreGraphics
import Darwin
import SwiftUI
import UniformTypeIdentifiers
struct RowView: View {
    let row: SpaceRow
    let selectedSpaceID: String?
    let keyboardFocusedSpaceID: String?
    let editRequest: RowEditRequest?
    let isFocused: Bool
    let onRename: (String) -> Void
    let onEmoji: (String) -> Void
    let onAccent: (String) -> Void
    let onSelect: (SpaceRecord) -> Void
    let onMoveToDesktop: (SpaceRecord) -> Void
    let onCloseSpace: (SpaceRecord) -> Void
    let onBeginCardDrag: () -> Void
    let onEndCardDrag: () -> Void
    let onMove: (String, String?) -> Void
    let onDelete: () -> Void
    let canDelete: Bool
    let onSwapRows: (UUID) -> Void
    @Binding var draggedRowID: UUID?
    @ObservedObject var memoryUsage: MemoryUsageMonitor
    let onBeginRowDrag: () -> Void
    let onEndRowDrag: () -> Void
    @State private var name: String
    @State private var isEmojiPickerPresented = false
    @State private var isColorPickerPresented = false
    @State private var emojiSelectionIndex = 0
    @State private var colorSelectionIndex = 0
    @FocusState private var isNameFocused: Bool
    @StateObject private var horizontalSpaceScroller = HorizontalSpaceScroller()

    private let emojiOptions = [
        "🗂️", "📁", "💼", "📌", "📚", "📝", "✍️", "🎨",
        "💻", "⌨️", "🖥️", "📱", "🔧", "⚙️", "🔬", "🧪",
        "📈", "💰", "🛒", "📣", "🤝", "🧠", "🎓", "🌿",
        "🏠", "✈️", "🎵", "🎮", "📷", "🎬", "🏃", "☀️"
    ]

    init(
        row: SpaceRow,
        selectedSpaceID: String?,
        keyboardFocusedSpaceID: String?,
        editRequest: RowEditRequest?,
        isFocused: Bool,
        onRename: @escaping (String) -> Void,
        onEmoji: @escaping (String) -> Void,
        onAccent: @escaping (String) -> Void,
        onSelect: @escaping (SpaceRecord) -> Void,
        onMoveToDesktop: @escaping (SpaceRecord) -> Void,
        onCloseSpace: @escaping (SpaceRecord) -> Void,
        onBeginCardDrag: @escaping () -> Void,
        onEndCardDrag: @escaping () -> Void,
        onMove: @escaping (String, String?) -> Void,
        onDelete: @escaping () -> Void,
        canDelete: Bool,
        onSwapRows: @escaping (UUID) -> Void,
        draggedRowID: Binding<UUID?>,
        memoryUsage: MemoryUsageMonitor,
        onBeginRowDrag: @escaping () -> Void,
        onEndRowDrag: @escaping () -> Void
    ) {
        self.row = row
        self.selectedSpaceID = selectedSpaceID
        self.keyboardFocusedSpaceID = keyboardFocusedSpaceID
        self.editRequest = editRequest
        self.isFocused = isFocused
        self.onRename = onRename
        self.onEmoji = onEmoji
        self.onAccent = onAccent
        self.onSelect = onSelect
        self.onMoveToDesktop = onMoveToDesktop
        self.onCloseSpace = onCloseSpace
        self.onBeginCardDrag = onBeginCardDrag
        self.onEndCardDrag = onEndCardDrag
        self.onMove = onMove
        self.onDelete = onDelete
        self.canDelete = canDelete
        self.onSwapRows = onSwapRows
        _draggedRowID = draggedRowID
        self.memoryUsage = memoryUsage
        self.onBeginRowDrag = onBeginRowDrag
        self.onEndRowDrag = onEndRowDrag
        _name = State(initialValue: row.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { isEmojiPickerPresented.toggle() } label: {
                    Text(row.emoji)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .help("Change row icon")
                .popover(isPresented: $isEmojiPickerPresented, arrowEdge: .bottom) {
                    emojiPicker
                }

                Button { isColorPickerPresented.toggle() } label: {
                    Circle()
                        .fill(Color(hex: row.accentHex))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().stroke(.white.opacity(0.45), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Change row color")
                .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
                    colorPicker
                }

                TextField("Row name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .fixedSize()
                    .focused($isNameFocused)
                    .onSubmit(commitName)
                    .onChange(of: isNameFocused) { _, isFocused in
                        if !isFocused { commitName() }
                    }
                    .onChange(of: name) { _, newValue in
                        if newValue.count > 100 {
                            name = String(newValue.prefix(100))
                        }
                    }
                Text("\(row.spaces.count) spaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if canDelete {
                    if #available(macOS 26.0, *) {
                        rowDragHandle
                    } else {
                        legacyRowDragHandle
                    }
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(row.spaces.isEmpty ? "Delete row" : "Move Spaces to Unsorted and delete row")
                }
            }

            spaceScroller
        }
        .padding(14)
        .frame(height: 155)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(draggedRowID == row.id ? 0.42 : 1)
        .contentShape(Rectangle())
        .onDrop(of: [.spacesManagerRow], isTargeted: nil, perform: swapRowFrom)
        .background(.ultraThinMaterial)
        .overlay {
            Rectangle()
                .stroke(isFocused ? .white : .white.opacity(0.2), lineWidth: isFocused ? 2 : 1)
        }
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: row.accentHex)).frame(width: 4) }
        .onChange(of: editRequest) { _, request in
            guard request?.rowID == row.id else { return }
            switch request?.action {
            case .rename:
                isNameFocused = true
            case .icon:
                isEmojiPickerPresented.toggle()
                if isEmojiPickerPresented {
                    emojiSelectionIndex = 0
                }
            case .color:
                isColorPickerPresented.toggle()
                if isColorPickerPresented {
                    colorSelectionIndex = 0
                }
            case nil:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerPickerNavigation)) { notification in
            guard notification.userInfo?["rowID"] as? UUID == row.id,
                  let actionName = notification.userInfo?["action"] as? String,
                  let action = RowEditAction(rawValue: actionName),
                  let offset = notification.userInfo?["offset"] as? Int else { return }
            switch action {
            case .icon where isEmojiPickerPresented:
                emojiSelectionIndex = min(max(0, emojiSelectionIndex + offset), emojiOptions.count - 1)
            case .color where isColorPickerPresented:
                colorSelectionIndex = min(max(0, colorSelectionIndex + offset), ColorPalette.values.count - 1)
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerPickerApply)) { notification in
            guard notification.userInfo?["rowID"] as? UUID == row.id,
                  let actionName = notification.userInfo?["action"] as? String,
                  let action = RowEditAction(rawValue: actionName) else { return }
            switch action {
            case .icon where isEmojiPickerPresented:
                onEmoji(emojiOptions[emojiSelectionIndex])
                isEmojiPickerPresented = false
            case .color where isColorPickerPresented:
                onAccent(ColorPalette.values[colorSelectionIndex])
                isColorPickerPresented = false
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowNameCommit)) { _ in
            guard isNameFocused else { return }
            commitName()
            isNameFocused = false
        }
    }


    private var spaceScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 12) {
                    ForEach(row.spaces) { space in
                        spaceCard(space)
                            .id(space.id)
                    }
                }
                .padding(.vertical, 2)
                .background(HorizontalSpaceScrollBridge(scroller: horizontalSpaceScroller))
            }
            .onChange(of: keyboardFocusedSpaceID) { _, spaceID in
                scrollToKeyboardFocusedSpace(spaceID, with: proxy)
            }
            .onChange(of: row.spaces.map(\.id)) { _, _ in
                scrollToKeyboardFocusedSpace(keyboardFocusedSpaceID, with: proxy)
            }
        }
        .frame(height: 102, alignment: .top)
        .onDrop(
            of: [.spacesManagerRow, .spacesManagerSpace],
            delegate: RowOrSpaceDropDelegate(
                performDrop: moveRowOrSpaceFrom,
                updateDragPosition: updateDragScrollPosition
            )
        )
    }

    private func spaceCard(_ space: SpaceRecord) -> some View {
        ZStack(alignment: .topLeading) {
            SpaceCard(
                space: space,
                isSelected: space.id == selectedSpaceID,
                isKeyboardFocused: space.id == keyboardFocusedSpaceID
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                onSelect(space)
            }

            if space.kind == .fullScreenApp || space.kind == .splitView {
                Button { onMoveToDesktop(space) } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(.white, in: Circle())
                        .overlay { Circle().stroke(.black.opacity(0.12), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .help("Move to Desktop")
                .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if space.kind == .fullScreenApp || space.kind == .splitView {
                Button { onCloseSpace(space) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(.white, in: Circle())
                        .overlay { Circle().stroke(.black.opacity(0.12), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .help("Quit \(space.name)")
                .padding(6)
            }
        }
        .onDrop(
            of: [.spacesManagerRow, .spacesManagerSpace],
            delegate: RowOrSpaceDropDelegate(
                performDrop: { handleSpaceCardDrop($0, before: space.id) },
                updateDragPosition: updateDragScrollPosition
            )
        )
        .onDrag {
            onBeginCardDrag()
            return spaceDragProvider(space.id)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(space.name)")
    }

    private func handleSpaceCardDrop(_ providers: [NSItemProvider], before spaceID: String) -> Bool {
        if providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.spacesManagerRow.identifier)
        }) {
            return swapRowFrom(providers)
        }
        let accepted = moveFrom(providers: providers, before: spaceID)
        if accepted {
            onEndCardDrag()
        }
        return accepted
    }

    private func scrollToKeyboardFocusedSpace(_ spaceID: String?, with proxy: ScrollViewProxy) {
        guard let spaceID,
              let index = row.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(spaceID, anchor: .center)
            }
            horizontalSpaceScroller.scrollToSpace(at: index)
        }
    }

    private func updateDragScrollPosition() {
        horizontalSpaceScroller.scrollForDrag(at: NSEvent.mouseLocation)
    }
    private func commitName() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Unknown" : String(trimmedName.prefix(100))
        name = resolvedName
        onRename(resolvedName)
    }

    private var emojiPicker: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 5),
            spacing: 6
        ) {
            ForEach(Array(emojiOptions.enumerated()), id: \.element) { index, emoji in
                Button(emoji) {
                    onEmoji(emoji)
                    isEmojiPickerPresented = false
                }
                .buttonStyle(.plain)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(row.emoji == emoji ? .white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(index == emojiSelectionIndex ? Color(hex: "73BCEB") : .clear, lineWidth: 2)
                }
            }
        }
        .padding(10)
    }

    private var colorPicker: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5),
            spacing: 8
        ) {
            ForEach(Array(ColorPalette.values.enumerated()), id: \.element) { index, hex in
                Button {
                    onAccent(hex)
                    isColorPickerPresented = false
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle().stroke(
                                colorPickerStrokeColor(index: index, hex: hex),
                                lineWidth: colorPickerStrokeWidth(index: index, hex: hex)
                            )
                        }
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
        .padding(10)
    }

    private func colorPickerStrokeColor(index: Int, hex: String) -> Color {
        if index == colorSelectionIndex {
            return Color(hex: "73BCEB")
        }
        return row.accentHex == hex ? .white : .black.opacity(0.2)
    }

    private func colorPickerStrokeWidth(index: Int, hex: String) -> CGFloat {
        index == colorSelectionIndex || row.accentHex == hex ? 2 : 1
    }

    private var rowDragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onDrag {
                draggedRowID = row.id
                onBeginRowDrag()
                return rowDragProvider()
            } preview: {
                RowDragPreview(row: row)
            }
            .help("Drag to reorder row")
    }

    private var legacyRowDragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onDrag {
                draggedRowID = row.id
                onBeginRowDrag()
                return rowDragProvider()
            }
            .help("Drag to reorder row")
    }

    private func moveRowOrSpaceFrom(_ providers: [NSItemProvider]) -> Bool {
        if let rowProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.spacesManagerRow.identifier)
        }) {
            rowProvider.loadDataRepresentation(forTypeIdentifier: UTType.spacesManagerRow.identifier) { data, _ in
                guard let data,
                      let item = try? JSONDecoder().decode(RowDragItem.self, from: data) else { return }
                Task { @MainActor in
                    swapRow(item.id)
                }
            }
            return true
        }

        guard let spaceProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.spacesManagerSpace.identifier)
        }) else { return false }
        spaceProvider.loadDataRepresentation(forTypeIdentifier: UTType.spacesManagerSpace.identifier) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                onMove(id, nil)
                onEndCardDrag()
            }
        }
        return true
    }

    private func swapRowFrom(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.spacesManagerRow.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.spacesManagerRow.identifier) { data, _ in
            guard let data,
                  let item = try? JSONDecoder().decode(RowDragItem.self, from: data) else { return }
            Task { @MainActor in
                swapRow(item.id)
            }
        }
        return true
    }

    private func moveFrom(providers: [NSItemProvider], before targetSpaceID: String) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.spacesManagerSpace.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.spacesManagerSpace.identifier) { data, _ in
            guard let data,
                  let spaceID = String(data: data, encoding: .utf8),
                  spaceID != targetSpaceID else { return }
            Task { @MainActor in onMove(spaceID, targetSpaceID) }
        }
        return true
    }

    private func rowDragProvider() -> NSItemProvider {
        let data = (try? JSONEncoder().encode(RowDragItem(id: row.id))) ?? Data()
        return internalDragProvider(for: .spacesManagerRow, data: data)
    }

    private func spaceDragProvider(_ spaceID: String) -> NSItemProvider {
        internalDragProvider(for: .spacesManagerSpace, data: Data(spaceID.utf8))
    }

    private func internalDragProvider(for type: UTType, data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func swapRow(_ sourceRowID: UUID) {
        defer {
            draggedRowID = nil
            onEndRowDrag()
        }
        guard canDelete, sourceRowID != row.id else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            onSwapRows(sourceRowID)
        }
    }

}
