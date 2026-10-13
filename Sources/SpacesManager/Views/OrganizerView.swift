import AppKit
import ApplicationServices
import Combine
import Carbon
import CoreGraphics
import Darwin
import SwiftUI
import UniformTypeIdentifiers
struct OrganizerView: View {
    @ObservedObject var store: SpaceOrganizationStore
    let onDismiss: () -> Void
    let onActivateSpace: (SpaceRecord) -> Void
    let onMoveToDesktop: (SpaceRecord) -> Void
    let onCloseSpace: (SpaceRecord) -> Void
    let onBeginCardDrag: () -> Void
    let onEndCardDrag: () -> Void
    @State private var draggedRowID: UUID?
    @State private var rowDragMouseUpMonitor: Any?
    @State private var focusedRowID: UUID?
    @State private var keyboardFocus: OrganizerKeyboardFocus = .header(selectedRowID: nil)
    @State private var rowEditRequest: RowEditRequest?
    @State private var activePicker: RowPickerFocus?
    @StateObject private var memoryUsage = MemoryUsageMonitor()

    var body: some View {
        VStack(spacing: 0) {
            header
            rows
        }
        .padding(.bottom, 24)
        .overlay {
            if let message = store.spaceSelectionWarning {
                ZStack {
                    Color.black.opacity(0.38)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Space Selection Unavailable")
                            .font(.title3.weight(.semibold))
                        Text(message)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                store.spaceSelectionWarning = nil
                            }
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 18)
                    .padding(32)
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerArrowNavigation), perform: handleArrowNavigation)
        .onReceive(NotificationCenter.default.publisher(for: .organizerHorizontalNavigation), perform: handleHorizontalNavigation)
        .onReceive(NotificationCenter.default.publisher(for: .organizerSpaceActivation), perform: handleSpaceActivation)
        .onReceive(NotificationCenter.default.publisher(for: .organizerHeaderFocus), perform: handleHeaderFocus)
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowReorder), perform: handleRowReorder)
        .onReceive(NotificationCenter.default.publisher(for: .organizerHorizontalReorder), perform: handleHorizontalReorder)
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowDeletion), perform: handleRowDeletion)
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowAddition), perform: handleRowAddition)
        .onReceive(NotificationCenter.default.publisher(for: .organizerSpaceMove), perform: handleSpaceMove)
        .onReceive(NotificationCenter.default.publisher(for: .organizerSpaceMinimize), perform: handleSpaceMinimize)
        .onReceive(NotificationCenter.default.publisher(for: .organizerSpaceExit), perform: handleSpaceExit)
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowEdit), perform: handleRowEdit)
    }

    private func notificationBooleanValue(_ notification: Notification, key: String) -> Bool {
        guard let userInfo = notification.userInfo else { return false }
        return userInfo[key] as? Bool ?? false
    }

    private func handleArrowNavigation(_ notification: Notification) {
        let isUp = notificationBooleanValue(notification, key: "isUpArrow")
        if activePicker != nil {
            navigatePicker(horizontal: false, backwards: isUp)
        } else {
            moveKeyboardFocus(up: isUp)
        }
    }

    private func handleHorizontalNavigation(_ notification: Notification) {
        let isLeft = notificationBooleanValue(notification, key: "isLeftArrow")
        if activePicker != nil {
            navigatePicker(horizontal: true, backwards: isLeft)
        } else {
            moveKeyboardSpaceFocus(left: isLeft)
        }
    }

    private func handleSpaceActivation(_ notification: Notification) {
        if let activePicker {
            NotificationCenter.default.post(
                name: .organizerPickerApply,
                object: nil,
                userInfo: ["rowID": activePicker.rowID, "action": activePicker.action.rawValue]
            )
            self.activePicker = nil
        } else {
            activateKeyboardFocusedSpace()
        }
    }

    private func handleHeaderFocus(_ notification: Notification) {
        keyboardFocus = .header(selectedRowID: nil)
    }

    private func handleRowReorder(_ notification: Notification) {
        moveKeyboardFocusedRow(up: notificationBooleanValue(notification, key: "isUp"))
    }

    private func handleHorizontalReorder(_ notification: Notification) {
        moveKeyboardFocusedItem(left: notificationBooleanValue(notification, key: "isLeft"))
    }

    private func handleRowDeletion(_ notification: Notification) {
        deleteKeyboardFocusedRow()
    }

    private func handleRowAddition(_ notification: Notification) {
        addRow()
    }

    private func handleSpaceMove(_ notification: Notification) {
        moveKeyboardFocusedSpace(up: notificationBooleanValue(notification, key: "isUp"))
    }

    private func handleSpaceMinimize(_ notification: Notification) {
        moveKeyboardFocusedSpaceToDesktop()
    }

    private func handleSpaceExit(_ notification: Notification) {
        closeKeyboardFocusedSpace()
    }

    private func handleRowEdit(_ notification: Notification) {
        guard let rowID = keyboardFocusedRowID,
              let actionName = notification.userInfo?["action"] as? String,
              let action = RowEditAction(rawValue: actionName) else { return }
        let pickerFocus = RowPickerFocus(rowID: rowID, action: action)
        if action == .rename {
            activePicker = nil
        } else if activePicker == pickerFocus {
            activePicker = nil
        } else {
            activePicker = pickerFocus
        }
        rowEditRequest = RowEditRequest(rowID: rowID, action: action)
    }

    private var header: some View {
        HStack {
            Text("Spaces Manager")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            Button(action: addRow) {
                Label("Add row", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canAddRow)
            Text("Memory \(memoryUsage.systemUsedPercentage)%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.white.opacity(0.14), in: Capsule())
            rowChips
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Spaces Manager")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(height: 1)
        }
        .overlay {
            if isKeyboardHeaderFocused {
                Rectangle().stroke(.white, lineWidth: 2)
            }
        }
    }

    private var rowChips: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                chipContent
                    .frame(minWidth: proxy.size.width, alignment: .trailing)
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            ForEach(Array(store.rows.dropFirst())) { row in
                Button {
                    focus(row.id)
                } label: {
                    HStack(spacing: 5) {
                        Text(row.emoji)
                        Text(chipName(for: row.name))
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color(hex: row.accentHex).opacity(0.78), in: Capsule())
                    .overlay {
                        Capsule().stroke(
                            chipStrokeColor(for: row.id),
                            lineWidth: chipStrokeWidth(for: row.id)
                        )
                    }
                }
                .buttonStyle(.plain)
                .help("Show \(row.name)")
                .onDrag {
                    onBeginCardDrag()
                    return rowChipDragProvider(for: row.id)
                }
                .onDrop(of: [.spacesManagerRow], isTargeted: nil) { providers in
                    moveRowFrom(providers, before: row.id)
                }
            }
        }
        .padding(.horizontal, 4)
        .onDrop(of: [.spacesManagerRow], isTargeted: nil) { providers in
            moveRowFrom(providers, before: nil)
        }
    }

    private func rowChipDragProvider(for rowID: UUID) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(RowDragItem(id: rowID))) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.spacesManagerRow.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func moveRowFrom(_ providers: [NSItemProvider], before targetRowID: UUID?) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.spacesManagerRow.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.spacesManagerRow.identifier) { data, _ in
            guard let data,
                  let item = try? JSONDecoder().decode(RowDragItem.self, from: data),
                  item.id != targetRowID else { return }
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if let targetRowID {
                        store.swapRows(item.id, targetRowID)
                    } else {
                        store.moveRow(item.id, before: nil)
                    }
                }
                onEndCardDrag()
            }
        }
        return true
    }

    private func chipName(for name: String) -> String {
        name.count > 15 ? String(name.prefix(15)) + "..." : name
    }

    private func chipStrokeColor(for rowID: UUID) -> Color {
        if keyboardFocusedHeaderChipID == rowID {
            return Color(hex: "73BCEB")
        }
        return focusedRowID == rowID ? .white : .white.opacity(0.22)
    }

    private func chipStrokeWidth(for rowID: UUID) -> CGFloat {
        keyboardFocusedHeaderChipID == rowID || focusedRowID == rowID ? 2 : 1
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(store.rows) { row in
                        RowView(
                            row: row,
                            selectedSpaceID: store.selectedSpaceID,
                            keyboardFocusedSpaceID: keyboardFocusedSpaceID(for: row.id),
                            editRequest: rowEditRequest,
                            isFocused: focusedRowID == row.id || keyboardFocusedRowID == row.id,
                            onRename: { store.renameRow(row.id, to: $0) },
                            onEmoji: { store.setEmoji(row.id, emoji: $0) },
                            onAccent: { store.setAccent(row.id, hex: $0) },
                            onSelect: onActivateSpace,
                            onMoveToDesktop: onMoveToDesktop,
                            onCloseSpace: onCloseSpace,
                            onBeginCardDrag: onBeginCardDrag,
                            onEndCardDrag: onEndCardDrag,
                            onMove: { store.move(spaceID: $0, to: row.id, before: $1) },
                            onDelete: { store.deleteRow(row.id) },
                            canDelete: store.canDeleteRow(row.id),
                            onSwapRows: { store.swapRows($0, row.id) },
                            draggedRowID: $draggedRowID,
                            memoryUsage: memoryUsage,
                            onBeginRowDrag: {
                                onBeginCardDrag()
                                beginRowDrag()
                            },
                            onEndRowDrag: {
                                endRowDrag()
                                onEndCardDrag()
                            }
                        )
                        .id(row.id)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 468)
            .frame(maxWidth: .infinity)
            .onChange(of: focusedRowID) { _, rowID in
                guard let rowID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
            .onChange(of: keyboardFocus) { _, focus in
                guard case let .row(rowID, _) = focus else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
            .onChange(of: store.rows.map(\.id)) { _, _ in
                guard let rowID = keyboardFocusedRowID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
        }
    }

    private func moveKeyboardFocus(up: Bool) {
        let rowIDs = store.rows.map(\.id)
        guard !rowIDs.isEmpty else {
            keyboardFocus = .header(selectedRowID: nil)
            return
        }

        switch keyboardFocus {
        case .header:
            if !up, let firstRow = store.rows.first {
                focusKeyboard(on: firstRow)
            }
        case let .row(currentRowID, _):
            guard let currentIndex = rowIDs.firstIndex(of: currentRowID) else {
                keyboardFocus = .header(selectedRowID: nil)
                return
            }
            if up {
                if currentIndex == 0 {
                    keyboardFocus = .header(selectedRowID: nil)
                } else {
                    focusKeyboard(on: store.rows[currentIndex - 1])
                }
            } else if currentIndex < rowIDs.count - 1 {
                focusKeyboard(on: store.rows[currentIndex + 1])
            }
        }
    }

    private var keyboardFocusedRowID: UUID? {
        guard case let .row(rowID, _) = keyboardFocus else { return nil }
        return rowID
    }

    private var isKeyboardHeaderFocused: Bool {
        guard case .header = keyboardFocus else { return false }
        return true
    }

    private var keyboardFocusedHeaderChipID: UUID? {
        guard case let .header(selectedRowID) = keyboardFocus else { return nil }
        return selectedRowID
    }

    private func keyboardFocusedSpaceID(for rowID: UUID) -> String? {
        guard case let .row(focusedRowID, spaceID) = keyboardFocus,
              focusedRowID == rowID else { return nil }
        return spaceID
    }

    private func focusKeyboard(on row: SpaceRow) {
        keyboardFocus = .row(row.id, spaceID: row.spaces.first?.id)
    }

    private func moveKeyboardSpaceFocus(left: Bool) {
        if case .header = keyboardFocus {
            moveKeyboardHeaderChipFocus(left: left)
            return
        }
        guard case let .row(rowID, focusedSpaceID) = keyboardFocus,
              let row = store.rows.first(where: { $0.id == rowID }),
              !row.spaces.isEmpty else { return }
        let currentIndex = focusedSpaceID.flatMap { spaceID in
            row.spaces.firstIndex(where: { $0.id == spaceID })
        } ?? 0
        let destinationIndex = left ? max(0, currentIndex - 1) : min(row.spaces.count - 1, currentIndex + 1)
        keyboardFocus = .row(row.id, spaceID: row.spaces[destinationIndex].id)
    }

    private func activateKeyboardFocusedSpace() {
        if case let .header(selectedRowID?) = keyboardFocus,
           let row = store.rows.first(where: { $0.id == selectedRowID }) {
            focusKeyboard(on: row)
            return
        }
        guard case let .row(rowID, spaceID?) = keyboardFocus,
              let row = store.rows.first(where: { $0.id == rowID }),
              let space = row.spaces.first(where: { $0.id == spaceID }) else { return }
        onActivateSpace(space)
    }

    private func moveKeyboardFocusedSpaceToDesktop() {
        guard case let .row(rowID, spaceID?) = keyboardFocus,
              let row = store.rows.first(where: { $0.id == rowID }),
              let space = row.spaces.first(where: { $0.id == spaceID }) else { return }
        onMoveToDesktop(space)
    }

    private func closeKeyboardFocusedSpace() {
        guard case let .row(rowID, spaceID?) = keyboardFocus,
              let row = store.rows.first(where: { $0.id == rowID }),
              let space = row.spaces.first(where: { $0.id == spaceID }) else { return }
        onCloseSpace(space)
    }

    private func moveKeyboardHeaderChipFocus(left: Bool) {
        let rows = Array(store.rows.dropFirst())
        guard !rows.isEmpty else { return }
        let currentIndex = keyboardFocusedHeaderChipID.flatMap { rowID in
            rows.firstIndex(where: { $0.id == rowID })
        }
        let destinationIndex: Int
        if let currentIndex {
            destinationIndex = left ? max(0, currentIndex - 1) : min(rows.count - 1, currentIndex + 1)
        } else {
            destinationIndex = left ? rows.count - 1 : 0
        }
        keyboardFocus = .header(selectedRowID: rows[destinationIndex].id)
    }

    private func moveKeyboardFocusedRow(up: Bool) {
        guard case let .row(rowID, _) = keyboardFocus,
              let currentIndex = store.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let destinationIndex = up ? currentIndex - 1 : currentIndex + 1
        guard destinationIndex > 0, destinationIndex < store.rows.count else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.swapRows(rowID, store.rows[destinationIndex].id)
        }
    }

    private func moveKeyboardFocusedItem(left: Bool) {
        if case let .header(selectedRowID?) = keyboardFocus {
            let rows = Array(store.rows.dropFirst())
            guard let currentIndex = rows.firstIndex(where: { $0.id == selectedRowID }) else { return }
            let destinationIndex = left ? currentIndex - 1 : currentIndex + 1
            guard rows.indices.contains(destinationIndex) else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.swapRows(selectedRowID, rows[destinationIndex].id)
            }
            return
        }

        guard case let .row(rowID, focusedSpaceID?) = keyboardFocus,
              let row = store.rows.first(where: { $0.id == rowID }),
              let currentIndex = row.spaces.firstIndex(where: { $0.id == focusedSpaceID }) else { return }
        let destinationIndex = left ? currentIndex - 1 : currentIndex + 1
        guard row.spaces.indices.contains(destinationIndex) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.swapSpaces(focusedSpaceID, row.spaces[destinationIndex].id)
        }
    }

    private func deleteKeyboardFocusedRow() {
        guard case let .row(rowID, _) = keyboardFocus,
              store.canDeleteRow(rowID),
              let rowIndex = store.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let nextRow = store.rows.indices.contains(rowIndex + 1) ? store.rows[rowIndex + 1] : nil
        let previousRow = rowIndex > 1 ? store.rows[rowIndex - 1] : nil
        withAnimation(.easeInOut(duration: 0.18)) {
            store.deleteRow(rowID)
        }
        if let nextRow {
            focusKeyboard(on: nextRow)
        } else if let previousRow {
            focusKeyboard(on: previousRow)
        } else {
            keyboardFocus = .header(selectedRowID: nil)
        }
    }

    private func moveKeyboardFocusedSpace(up: Bool) {
        guard case let .row(rowID, spaceID?) = keyboardFocus,
              let sourceIndex = store.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let destinationIndex = up ? sourceIndex - 1 : sourceIndex + 1
        guard store.rows.indices.contains(destinationIndex) else { return }
        let destinationRow = store.rows[destinationIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            store.move(spaceID: spaceID, to: destinationRow.id)
        }
        keyboardFocus = .row(destinationRow.id, spaceID: spaceID)
    }

    private func navigatePicker(horizontal: Bool, backwards: Bool) {
        guard let activePicker else { return }
        NotificationCenter.default.post(
            name: .organizerPickerNavigation,
            object: nil,
            userInfo: [
                "rowID": activePicker.rowID,
                "action": activePicker.action.rawValue,
                "offset": horizontal ? (backwards ? -1 : 1) : (backwards ? -5 : 5),
            ]
        )
    }

    private func focus(_ rowID: UUID) {
        focusedRowID = rowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            if focusedRowID == rowID {
                focusedRowID = nil
            }
        }
    }

    private func addRow() {
        guard let rowID = store.addRow() else { return }
        focus(rowID)
        keyboardFocus = .row(rowID, spaceID: nil)
        DispatchQueue.main.async {
            rowEditRequest = RowEditRequest(rowID: rowID, action: .rename)
        }
    }

    private func beginRowDrag() {
        endRowDrag()
        rowDragMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            DispatchQueue.main.async {
                endRowDrag()
            }
            return event
        }
    }

    private func endRowDrag() {
        if let rowDragMouseUpMonitor {
            NSEvent.removeMonitor(rowDragMouseUpMonitor)
            self.rowDragMouseUpMonitor = nil
        }
        draggedRowID = nil
    }

}

