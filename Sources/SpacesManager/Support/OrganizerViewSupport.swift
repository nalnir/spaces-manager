import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var systemUsedPercentage = 0

    private var refreshTimer: Timer?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func refresh() {
        systemUsedPercentage = currentSystemMemoryPercentage()
    }

    private func currentSystemMemoryPercentage() -> Int {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return 0 }
        return min(100, Int((usedBytes * 100) / totalBytes))
    }
}

enum OrganizerKeyboardFocus: Equatable {
    case header(selectedRowID: UUID?)
    case row(UUID, spaceID: String?)
}

enum RowEditAction: String {
    case rename
    case icon
    case color
}

struct RowEditRequest: Equatable {
    let rowID: UUID
    let action: RowEditAction
    let token = UUID()
}

struct RowPickerFocus: Equatable {
    let rowID: UUID
    let action: RowEditAction
}

@MainActor
final class HorizontalSpaceScroller: ObservableObject {
    weak var scrollView: NSScrollView?

    func scrollToSpace(at index: Int) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let cardStride: CGFloat = 172
        let visibleWidth = scrollView.contentView.bounds.width
        let maximumOffset = max(0, documentView.bounds.width - visibleWidth)
        let offset = min(max(0, CGFloat(index) * cardStride - (visibleWidth - 160) / 2), maximumOffset)
        scrollView.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollForDrag(at screenLocation: NSPoint) {
        guard let scrollView,
              let documentView = scrollView.documentView,
              let window = scrollView.window else { return }
        let location = scrollView.convert(window.convertPoint(fromScreen: screenLocation), from: nil)
        let edgeInset: CGFloat = 44
        let offset: CGFloat
        if location.x < edgeInset {
            offset = -24
        } else if location.x > scrollView.bounds.width - edgeInset {
            offset = 24
        } else {
            return
        }
        let currentOffset = scrollView.contentView.bounds.origin.x
        let maximumOffset = max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(max(0, currentOffset + offset), maximumOffset), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

struct HorizontalSpaceScrollBridge: NSViewRepresentable {
    let scroller: HorizontalSpaceScroller

    func makeNSView(context: Context) -> NSView {
        ScrollBridgeView(scroller: scroller)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ScrollBridgeView: NSView {
        private weak var scroller: HorizontalSpaceScroller?

        init(scroller: HorizontalSpaceScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.scroller?.scrollView = self?.scrollViewAncestor
            }
        }

        private var scrollViewAncestor: NSScrollView? {
            sequence(first: superview, next: { $0?.superview }).first { $0 is NSScrollView } as? NSScrollView
        }
    }
}

struct SpaceDropDelegate: DropDelegate {
    let performDrop: ([NSItemProvider]) -> Bool
    let updateDragPosition: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.spacesManagerSpace])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDragPosition()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        performDrop(info.itemProviders(for: [.spacesManagerSpace]))
    }
}

struct RowOrSpaceDropDelegate: DropDelegate {
    let performDrop: ([NSItemProvider]) -> Bool
    let updateDragPosition: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.spacesManagerRow, .spacesManagerSpace])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [.spacesManagerSpace]) {
            updateDragPosition()
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        performDrop(info.itemProviders(for: [.spacesManagerRow, .spacesManagerSpace]))
    }
}