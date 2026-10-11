import AppKit
import Combine
import Carbon
import CoreGraphics
import Darwin
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let missionControlRow = UTType(exportedAs: "com.lukasstateczny.mission-control-ultra.row-reorder", conformingTo: .data)
    static let missionControlSpace = UTType(exportedAs: "com.lukasstateczny.mission-control-ultra.space-reorder", conformingTo: .data)
}

private struct RowDragItem: Codable, Identifiable {
    let id: UUID
}

enum SpaceKind: String, Codable, CaseIterable, Identifiable {
    case desktop = "Desktop"
    case window = "Window"
    case fullScreenApp = "Full Screen"
    case splitView = "Split View"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .desktop: "rectangle.on.rectangle"
        case .window: "macwindow"
        case .fullScreenApp: "arrow.up.left.and.arrow.down.right"
        case .splitView: "rectangle.split.2x1"
        }
    }
}

struct SpaceRecord: Identifiable {
    let id: String
    var name: String
    var kind: SpaceKind
    var applications: [String]
    var thumbnail: CGImage?
    var isActive: Bool
    var displayIdentifier: String?
    var applicationProcessIdentifiers: [pid_t]

    init(
        id: String,
        name: String,
        kind: SpaceKind,
        applications: [String],
        thumbnail: CGImage? = nil,
        isActive: Bool = false,
        displayIdentifier: String? = nil,
        applicationProcessIdentifiers: [pid_t] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.applications = applications
        self.thumbnail = thumbnail
        self.isActive = isActive
        self.displayIdentifier = displayIdentifier
        self.applicationProcessIdentifiers = applicationProcessIdentifiers
    }
}

struct SpaceRow: Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var accentHex: String
    var spaces: [SpaceRecord]

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        accentHex: String,
        spaces: [SpaceRecord] = []
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.accentHex = accentHex
        self.spaces = spaces
    }
}

/// The only component allowed to interpret native Spaces. The UI and store stay
/// independent from private APIs, Accessibility, and WindowServer details.
protocol NativeSpaceDiscovering {
    func currentSpaces() async -> [SpaceRecord]
}

/// Reads the same WindowServer inventory that backs Mission Control. SkyLight
/// is private and unsupported, so this stays isolated behind the protocol.
struct SkyLightSpaceDiscovery: NativeSpaceDiscovering {
    private typealias ConnectionID = UInt32
    private typealias MainConnectionFunction = @convention(c) () -> ConnectionID
    private typealias CopyManagedSpacesFunction = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?

    private let fallback = WindowServerDiscovery()
    private let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    static func currentActiveSpaceID() -> String? {
        SkyLightSpaceDiscovery().managedSpaces()?.activeSpaceIDs.first
    }

    fileprivate static func navigation(to nativeSpaceID: String, on displayIdentifier: String) -> SpaceNavigation? {
        guard let snapshot = SkyLightSpaceDiscovery().managedSpaces(),
              let spaceIDs = snapshot.spaceIDsByDisplayIdentifier[displayIdentifier],
              let currentSpaceID = snapshot.activeSpaceIDsByDisplayIdentifier[displayIdentifier],
              let currentIndex = spaceIDs.firstIndex(of: currentSpaceID),
              let targetIndex = spaceIDs.firstIndex(of: nativeSpaceID) else {
            return nil
        }
        let offset = targetIndex - currentIndex
        if offset == 0 { return SpaceNavigation(direction: .right, count: 0) }
        return SpaceNavigation(direction: offset > 0 ? .right : .left, count: abs(offset))
    }

    func currentSpaces() async -> [SpaceRecord] {
        guard let snapshot = managedSpaces(), !snapshot.spaces.isEmpty else {
            NSLog("Mission Control Ultra could not read the SkyLight Space inventory; using the public fallback.")
            return await fallback.currentSpaces()
        }

        let visibleSpaces = await fallback.currentSpaces()
        let visibleAppThumbnails: [String: CGImage] = Dictionary(
            uniqueKeysWithValues: visibleSpaces.compactMap { space -> (String, CGImage)? in
                guard space.id.hasPrefix("app-"), let thumbnail = space.thumbnail else { return nil }
                return (String(space.id.dropFirst(4)), thumbnail)
            }
        )
        let desktopThumbnail = visibleSpaces.first(where: { $0.kind == .desktop })?.thumbnail
        var desktopCount = 0

        let records = snapshot.spaces.map { space -> SpaceRecord in
            let identifier = space["ManagedSpaceID"] as? NSNumber
            let spaceID = identifier?.stringValue ?? UUID().uuidString
            let isActive = snapshot.activeSpaceIDs.contains(spaceID)
            let processIdentifiers = processIdentifiers(in: space)
            let applicationNames = processIdentifiers.compactMap(applicationName(for:))
            let tileSpaces = ((space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]]) ?? []
            let kind: SpaceKind

            if (space["type"] as? NSNumber)?.intValue == 0 {
                kind = .desktop
                desktopCount += 1
            } else if tileSpaces.count > 1 {
                kind = .splitView
            } else {
                kind = .fullScreenApp
            }

            let name: String
            switch kind {
            case .desktop:
                name = desktopCount == 1 ? "Desktop" : "Desktop \(desktopCount)"
            case .splitView:
                name = applicationNames.joined(separator: " + ")
            default:
                name = applicationNames.first ?? "Full Screen App"
            }

            let thumbnail: CGImage?
            if kind == .desktop && isActive {
                thumbnail = desktopThumbnail
            } else if isActive {
                thumbnail = processIdentifiers.lazy.compactMap { visibleAppThumbnails[String($0)] }.first
            } else {
                thumbnail = nil
            }

            return SpaceRecord(
                id: "space-\(spaceID)",
                name: name,
                kind: kind,
                applications: applicationNames,
                thumbnail: thumbnail,
                isActive: isActive,
                displayIdentifier: snapshot.displayIdentifiersBySpaceID[spaceID],
                applicationProcessIdentifiers: processIdentifiers
            )
        }
        NSLog("Mission Control Ultra read \(records.count) native Spaces from SkyLight.")
        return records
    }

    private func managedSpaces() -> (
        spaces: [[String: Any]],
        activeSpaceIDs: Set<String>,
        displayIdentifiersBySpaceID: [String: String],
        spaceIDsByDisplayIdentifier: [String: [String]],
        activeSpaceIDsByDisplayIdentifier: [String: String]
    )? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let mainConnectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let copyManagedSpacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            return nil
        }
        defer { dlclose(handle) }

        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: MainConnectionFunction.self)
        let copyManagedSpaces = unsafeBitCast(copyManagedSpacesSymbol, to: CopyManagedSpacesFunction.self)
        guard let displays = copyManagedSpaces(mainConnection())?.takeRetainedValue() else {
            return nil
        }
        let displayDictionaries: [[String: Any]] = (0..<CFArrayGetCount(displays)).compactMap { index in
            let value = CFArrayGetValueAtIndex(displays, index)
            let object = unsafeBitCast(value, to: AnyObject.self)
            return object as? [String: Any]
        }
        let activeSpaceIDs = Set(displayDictionaries.compactMap { display in
            (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
        }.map(\.stringValue))
        var displayIdentifiersBySpaceID: [String: String] = [:]
        var spaceIDsByDisplayIdentifier: [String: [String]] = [:]
        var activeSpaceIDsByDisplayIdentifier: [String: String] = [:]
        for display in displayDictionaries {
            guard let displayIdentifier = display["Display Identifier"] as? String else { continue }
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            spaceIDsByDisplayIdentifier[displayIdentifier] = spaces.compactMap {
                ($0["ManagedSpaceID"] as? NSNumber)?.stringValue
            }
            activeSpaceIDsByDisplayIdentifier[displayIdentifier] = (
                (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            )?.stringValue
            for space in spaces {
                guard let spaceID = (space["ManagedSpaceID"] as? NSNumber)?.stringValue else { continue }
                displayIdentifiersBySpaceID[spaceID] = displayIdentifier
            }
        }
        return (
            displayDictionaries.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] },
            activeSpaceIDs,
            displayIdentifiersBySpaceID,
            spaceIDsByDisplayIdentifier,
            activeSpaceIDsByDisplayIdentifier
        )
    }

    private func processIdentifiers(in space: [String: Any]) -> [pid_t] {
        let tiles = ((space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]]) ?? [space]
        return tiles.compactMap { ($0["pid"] as? NSNumber).map { pid_t($0.intValue) } }
            .reduce(into: []) { identifiers, processIdentifier in
                if !identifiers.contains(processIdentifier) {
                    identifiers.append(processIdentifier)
                }
            }
    }

    private func applicationName(for processIdentifier: pid_t) -> String? {
        NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
    }
}

fileprivate enum SpaceNavigationDirection {
    case left
    case right

    var keyCode: CGKeyCode {
        switch self {
        case .left: CGKeyCode(kVK_LeftArrow)
        case .right: CGKeyCode(kVK_RightArrow)
        }
    }
}

fileprivate struct SpaceNavigation {
    let direction: SpaceNavigationDirection
    let count: Int
}

struct WindowServerDiscovery: NativeSpaceDiscovering {
    func currentSpaces() async -> [SpaceRecord] {
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("Mission Control Ultra needs Screen Recording permission before it can discover Spaces.")
            return []
        }
        let ownProcessID = Int(ProcessInfo.processInfo.processIdentifier)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            NSLog("Mission Control Ultra could not enumerate shareable windows: \(error.localizedDescription)")
            return []
        }
        NSLog(
            "Mission Control Ultra found \(content.displays.count) displays and \(content.windows.count) shareable windows."
        )

        let ownWindows = content.windows.filter { window in
            window.owningApplication.map { Int($0.processID) } == ownProcessID
        }
        let displayWidth = CGFloat(content.displays.first?.width ?? 0)
        let displayHeight = CGFloat(content.displays.first?.height ?? 0)
        let ignoredBundleIdentifiers: Set<String> = [
            "com.apple.dock",
            "com.apple.finder",
            "com.apple.WindowManager",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
        ]
        let appWindows: [SCWindow] = content.windows.filter { window in
            guard let application = window.owningApplication else { return false }
            let processID = Int(application.processID)
            let frame = window.frame
            let isDisplaySized = frame.width >= displayWidth * 0.7
                && frame.height >= displayHeight * 0.7
            return processID != ownProcessID
                && !ignoredBundleIdentifiers.contains(application.bundleIdentifier)
                && !application.bundleIdentifier.hasPrefix("com.apple.")
                && isDisplaySized
        }
        let windowsByProcess: [pid_t: [SCWindow]] = Dictionary(grouping: appWindows) { window in
            window.owningApplication!.processID
        }
        let largestWindowByProcess: [SCWindow] = windowsByProcess.values.compactMap { windows in
            windows.max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
        }
        NSLog(
            "Mission Control Ultra retained \(appWindows.count) app windows across \(largestWindowByProcess.count) applications."
        )

        var discovered: [SpaceRecord] = []
        if let display = content.displays.first {
            let config = SCStreamConfiguration()
            config.width = 480
            config.height = 270
            config.showsCursor = false
            let desktopThumbnail = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: ownWindows),
                configuration: config
            )
            discovered.append(
                SpaceRecord(
                    id: "desktop-\(display.displayID)",
                    name: "Desktop",
                    kind: .desktop,
                    applications: [],
                    thumbnail: desktopThumbnail
                )
            )
        }

        for window in largestWindowByProcess {
            guard let application = window.owningApplication else { continue }
            let owner = application.applicationName
            let config = SCStreamConfiguration()
            config.width = 480
            config.height = 270
            config.showsCursor = false
            let thumbnail = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
            discovered.append(
                SpaceRecord(
                    id: "app-\(application.processID)",
                    name: owner,
                    kind: .fullScreenApp,
                    applications: [owner],
                    thumbnail: thumbnail,
                    applicationProcessIdentifiers: [application.processID]
                )
            )
        }
        NSLog("Mission Control Ultra created \(discovered.count) Space cards.")
        return discovered.sorted { lhs, rhs in
            lhs.kind == .desktop ? false : rhs.kind == .desktop ? true : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

@MainActor
final class SpaceOrganizationStore: ObservableObject {
    fileprivate struct PersistedRow: Codable {
        let id: UUID
        let name: String
        let emoji: String
        let accentHex: String
    }

    @Published private(set) var rows: [SpaceRow]
    @Published var selectedSpaceID: String?

    private let unsortedRowID: UUID
    private var storedAssignments: [String: UUID]
    private var storedSpaceOrder: [String]
    private let persistenceKey = "MissionControlUltra.rowOrganization"
    private let maximumUserRows = 7

    init() {
        let persisted = Self.loadOrganization()
        if let firstRow = persisted?.rows.first {
            unsortedRowID = firstRow.id
            rows = persisted!.rows.map {
                SpaceRow(id: $0.id, name: $0.name, emoji: $0.emoji, accentHex: $0.accentHex)
            }
            storedAssignments = persisted!.assignments
            storedSpaceOrder = persisted!.spaceOrder
        } else {
            let unsorted = SpaceRow(name: "Unsorted", emoji: "🗂️", accentHex: "858C98")
            unsortedRowID = unsorted.id
            rows = [unsorted]
            storedAssignments = [:]
            storedSpaceOrder = []
        }
    }

    /// Reconciles a fresh native snapshot without ever inventing a second source
    /// of truth for Spaces. Missing Spaces disappear; new ones enter Unsorted.
    func reconcile(discovered spaces: [SpaceRecord]) {
        var assignments = storedAssignments
        let visibleAssignments = Dictionary(
            uniqueKeysWithValues: rows.flatMap { row in
                row.spaces.map { ($0.id, row.id) }
            }
        )
        assignments.merge(visibleAssignments) { _, current in current }
        var nextSpaces = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, [SpaceRecord]()) })
        var orderIndex = Dictionary(uniqueKeysWithValues: storedSpaceOrder.enumerated().map { ($0.element, $0.offset) })
        let cachedThumbnails = Dictionary(
            uniqueKeysWithValues: rows.flatMap { row in
                row.spaces.compactMap { space -> (String, CGImage)? in
                    guard let thumbnail = space.thumbnail else { return nil }
                    return (space.id, thumbnail)
                }
            }
        )

        for var space in spaces {
            if space.thumbnail == nil {
                space.thumbnail = cachedThumbnails[space.id] ?? ThumbnailCache.load(spaceID: space.id)
            } else {
                ThumbnailCache.save(space.thumbnail, spaceID: space.id)
            }
            let rowID = assignments[space.id] ?? unsortedRowID
            nextSpaces[rowID, default: []].append(space)
            storedAssignments[space.id] = rowID
            if orderIndex[space.id] == nil {
                storedSpaceOrder.append(space.id)
                orderIndex[space.id] = storedSpaceOrder.count - 1
            }
        }

        for index in rows.indices {
            rows[index].spaces = nextSpaces[rows[index].id, default: []].sorted {
                (orderIndex[$0.id] ?? .max) < (orderIndex[$1.id] ?? .max)
            }
        }
        selectedSpaceID = spaces.first(where: \ .isActive)?.id ?? selectedSpaceID.flatMap { id in
            spaces.contains(where: { $0.id == id }) ? id : spaces.first?.id
        } ?? spaces.first?.id
        persistOrganization()
    }

    func addRow() {
        guard canAddRow else { return }
        rows.append(SpaceRow(name: "Untitled Row", emoji: "📁", accentHex: "85D4C7"))
        persistOrganization()
    }

    var canAddRow: Bool {
        rows.count - 1 < maximumUserRows
    }

    func renameRow(_ rowID: UUID, to name: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        rows[index].name = trimmedName.isEmpty ? "Unknown" : String(trimmedName.prefix(100))
        persistOrganization()
    }

    func setEmoji(_ rowID: UUID, emoji: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].emoji = emoji
        persistOrganization()
    }

    func setAccent(_ rowID: UUID, hex: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].accentHex = hex
        persistOrganization()
    }

    func move(spaceID: String, to destinationRowID: UUID, before targetSpaceID: String? = nil) {
        guard let sourceIndex = rows.firstIndex(where: { $0.spaces.contains(where: { $0.id == spaceID }) }),
              let spaceIndex = rows[sourceIndex].spaces.firstIndex(where: { $0.id == spaceID }),
              let destinationIndex = rows.firstIndex(where: { $0.id == destinationRowID }) else { return }
        let space = rows[sourceIndex].spaces.remove(at: spaceIndex)
        rows[destinationIndex].spaces.append(space)
        storedAssignments[spaceID] = destinationRowID
        storedSpaceOrder.removeAll { $0 == spaceID }
        if let targetSpaceID,
           let targetIndex = storedSpaceOrder.firstIndex(of: targetSpaceID) {
            storedSpaceOrder.insert(spaceID, at: targetIndex)
        } else {
            storedSpaceOrder.append(spaceID)
        }
        persistOrganization()
    }

    func deleteRow(_ rowID: UUID) {
        guard rowID != unsortedRowID,
              let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let spaces = rows[index].spaces
        if let unsortedIndex = rows.firstIndex(where: { $0.id == unsortedRowID }) {
            rows[unsortedIndex].spaces.append(contentsOf: spaces)
            for space in spaces {
                storedAssignments[space.id] = unsortedRowID
            }
        }
        rows.remove(at: index)
          persistOrganization()
    }

    func canDeleteRow(_ rowID: UUID) -> Bool {
        rowID != unsortedRowID
    }

    func moveRow(_ rowID: UUID, before targetRowID: UUID?) {
        guard rowID != unsortedRowID,
              targetRowID != unsortedRowID,
              let sourceIndex = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let row = rows.remove(at: sourceIndex)
        let destinationIndex: Int
        if let targetRowID,
           targetRowID != unsortedRowID,
           let targetIndex = rows.firstIndex(where: { $0.id == targetRowID }) {
            destinationIndex = targetIndex
        } else {
            destinationIndex = rows.count
        }
        rows.insert(row, at: destinationIndex)
        persistOrganization()
    }

    func swapRows(_ firstRowID: UUID, _ secondRowID: UUID) {
        guard firstRowID != unsortedRowID,
              secondRowID != unsortedRowID,
              firstRowID != secondRowID,
              let firstIndex = rows.firstIndex(where: { $0.id == firstRowID }),
              let secondIndex = rows.firstIndex(where: { $0.id == secondRowID }) else { return }
        rows.swapAt(firstIndex, secondIndex)
        persistOrganization()
    }

    func swapSpaces(_ firstSpaceID: String, _ secondSpaceID: String) {
        guard firstSpaceID != secondSpaceID,
              let rowIndex = rows.firstIndex(where: { row in
                  row.spaces.contains(where: { $0.id == firstSpaceID })
                      && row.spaces.contains(where: { $0.id == secondSpaceID })
              }),
              let firstIndex = rows[rowIndex].spaces.firstIndex(where: { $0.id == firstSpaceID }),
              let secondIndex = rows[rowIndex].spaces.firstIndex(where: { $0.id == secondSpaceID }) else { return }
        rows[rowIndex].spaces.swapAt(firstIndex, secondIndex)
        if let firstOrderIndex = storedSpaceOrder.firstIndex(of: firstSpaceID),
           let secondOrderIndex = storedSpaceOrder.firstIndex(of: secondSpaceID) {
            storedSpaceOrder.swapAt(firstOrderIndex, secondOrderIndex)
        }
        persistOrganization()
    }

    func selectActiveSpace(nativeID: String) {
        let spaceID = "space-\(nativeID)"
        guard rows.contains(where: { row in row.spaces.contains(where: { $0.id == spaceID }) }) else { return }
        selectedSpaceID = spaceID
    }

    private func persistOrganization() {
        let persistedRows = rows.map {
            PersistedRow(id: $0.id, name: $0.name, emoji: $0.emoji, accentHex: $0.accentHex)
        }
        guard let data = try? JSONEncoder().encode(
            PersistedOrganization(rows: persistedRows, assignments: storedAssignments, spaceOrder: storedSpaceOrder)
        ) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private static func loadOrganization() -> PersistedOrganization? {
        guard let data = UserDefaults.standard.data(forKey: "MissionControlUltra.rowOrganization") else { return nil }
        return try? JSONDecoder().decode(PersistedOrganization.self, from: data)
    }
}

private struct PersistedOrganization: Codable {
    let rows: [SpaceOrganizationStore.PersistedRow]
    let assignments: [String: UUID]
    let spaceOrder: [String]

    private enum CodingKeys: String, CodingKey {
        case rows
        case assignments
        case spaceOrder
    }

    init(rows: [SpaceOrganizationStore.PersistedRow], assignments: [String: UUID], spaceOrder: [String] = []) {
        self.rows = rows
        self.assignments = assignments
        self.spaceOrder = spaceOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([SpaceOrganizationStore.PersistedRow].self, forKey: .rows)
        assignments = try container.decode([String: UUID].self, forKey: .assignments)
        spaceOrder = try container.decodeIfPresent([String].self, forKey: .spaceOrder) ?? []
    }
}

private enum ThumbnailCache {
    private static let directory: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("Mission Control Ultra", isDirectory: true)
            .appendingPathComponent("Space Thumbnails", isDirectory: true)
    }()

    static func load(spaceID: String) -> CGImage? {
        guard let image = NSImage(contentsOf: fileURL(for: spaceID)) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func save(_ image: CGImage?, spaceID: String) {
        guard let image,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: spaceID), options: .atomic)
    }

    private static func fileURL(for spaceID: String) -> URL {
        let filename = spaceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? spaceID
        return directory.appendingPathComponent("\(filename).png")
    }
}

@main
struct MissionControlUltraApp: App {
    @NSApplicationDelegateAdaptor(OverlayController.self) private var overlayController

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension Notification.Name {
    static let organizerArrowNavigation = Notification.Name("MissionControlUltra.organizerArrowNavigation")
    static let organizerHorizontalNavigation = Notification.Name("MissionControlUltra.organizerHorizontalNavigation")
    static let organizerSpaceActivation = Notification.Name("MissionControlUltra.organizerSpaceActivation")
    static let organizerHeaderFocus = Notification.Name("MissionControlUltra.organizerHeaderFocus")
    static let organizerRowReorder = Notification.Name("MissionControlUltra.organizerRowReorder")
    static let organizerHorizontalReorder = Notification.Name("MissionControlUltra.organizerHorizontalReorder")
    static let organizerRowDeletion = Notification.Name("MissionControlUltra.organizerRowDeletion")
    static let organizerSpaceMove = Notification.Name("MissionControlUltra.organizerSpaceMove")
    static let organizerRowEdit = Notification.Name("MissionControlUltra.organizerRowEdit")
    static let organizerPickerNavigation = Notification.Name("MissionControlUltra.organizerPickerNavigation")
    static let organizerPickerApply = Notification.Name("MissionControlUltra.organizerPickerApply")
}

@MainActor
final class OverlayController: NSObject, NSApplicationDelegate {
    private let store = SpaceOrganizationStore()
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var navigateUpHotKey: EventHotKeyRef?
    private var navigateDownHotKey: EventHotKeyRef?
    private var navigateLeftHotKey: EventHotKeyRef?
    private var navigateRightHotKey: EventHotKeyRef?
    private var activateSpaceHotKey: EventHotKeyRef?
    private var focusHeaderHotKey: EventHotKeyRef?
    private var moveRowUpHotKey: EventHotKeyRef?
    private var moveRowDownHotKey: EventHotKeyRef?
    private var moveItemLeftHotKey: EventHotKeyRef?
    private var moveItemRightHotKey: EventHotKeyRef?
    private var deleteRowHotKey: EventHotKeyRef?
    private var addRowHotKey: EventHotKeyRef?
    private var moveSpaceUpHotKey: EventHotKeyRef?
    private var moveSpaceDownHotKey: EventHotKeyRef?
    private var renameRowHotKey: EventHotKeyRef?
    private var pickIconHotKey: EventHotKeyRef?
    private var pickColorHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var activeSpaceObserver: NSObjectProtocol?
    private var activeSpacePollTimer: Timer?
    private var lastObservedActiveSpaceID: String?
    private var isOverlayPresented = false
    private var dragReleaseMonitor: Any?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installInvocationHotKey()
        observeActiveSpaceChanges()
        NSLog("Mission Control Ultra can post Space navigation events: \(CGPreflightPostEventAccess())")
        requestEventPostingAccessIfNeeded()
        showOverlay()
        requestScreenCaptureAccessIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let navigateUpHotKey { UnregisterEventHotKey(navigateUpHotKey) }
        if let navigateDownHotKey { UnregisterEventHotKey(navigateDownHotKey) }
        if let navigateLeftHotKey { UnregisterEventHotKey(navigateLeftHotKey) }
        if let navigateRightHotKey { UnregisterEventHotKey(navigateRightHotKey) }
        if let activateSpaceHotKey { UnregisterEventHotKey(activateSpaceHotKey) }
        if let focusHeaderHotKey { UnregisterEventHotKey(focusHeaderHotKey) }
        if let moveRowUpHotKey { UnregisterEventHotKey(moveRowUpHotKey) }
        if let moveRowDownHotKey { UnregisterEventHotKey(moveRowDownHotKey) }
        if let moveItemLeftHotKey { UnregisterEventHotKey(moveItemLeftHotKey) }
        if let moveItemRightHotKey { UnregisterEventHotKey(moveItemRightHotKey) }
        if let deleteRowHotKey { UnregisterEventHotKey(deleteRowHotKey) }
        if let addRowHotKey { UnregisterEventHotKey(addRowHotKey) }
        if let moveSpaceUpHotKey { UnregisterEventHotKey(moveSpaceUpHotKey) }
        if let moveSpaceDownHotKey { UnregisterEventHotKey(moveSpaceDownHotKey) }
        if let renameRowHotKey { UnregisterEventHotKey(renameRowHotKey) }
        if let pickIconHotKey { UnregisterEventHotKey(pickIconHotKey) }
        if let pickColorHotKey { UnregisterEventHotKey(pickColorHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let activeSpaceObserver { NotificationCenter.default.removeObserver(activeSpaceObserver) }
        if let dragReleaseMonitor { NSEvent.removeMonitor(dragReleaseMonitor) }
        activeSpacePollTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func requestScreenCaptureAccessIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        CGRequestScreenCaptureAccess()
    }

    private func requestEventPostingAccessIfNeeded() {
        guard !CGPreflightPostEventAccess() else { return }
        CGRequestPostEventAccess()
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            }
            button.setAccessibilityLabel("Spaces Manager")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        self.statusItem = statusItem
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        let toggleItem = menu.addItem(withTitle: isOverlayPresented ? "Hide Spaces Manager" : "Show Spaces Manager", action: #selector(toggleOverlayFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(.separator())

        let screenRecordingEnabled = CGPreflightScreenCaptureAccess()
        let screenRecordingItem = menu.addItem(
            withTitle: screenRecordingEnabled ? "Screen Recording: Enabled" : "Grant Screen Recording Permission...",
            action: screenRecordingEnabled ? nil : #selector(requestScreenRecordingPermission),
            keyEquivalent: ""
        )
        screenRecordingItem.target = self
        let accessibilityEnabled = CGPreflightPostEventAccess()
        let accessibilityItem = menu.addItem(
            withTitle: accessibilityEnabled ? "Accessibility: Enabled" : "Open Accessibility Settings...",
            action: accessibilityEnabled ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(.separator())
        let aboutItem = menu.addItem(withTitle: "About Spaces Manager", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Spaces Manager", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
    }

    @objc private func toggleOverlayFromMenu() {
        toggleOverlay()
    }

    @objc private func requestScreenRecordingPermission() {
        requestScreenCaptureAccessIfNeeded()
    }

    @objc private func openAccessibilitySettings() {
        requestEventPostingAccessIfNeeded()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spaces Manager"
        alert.informativeText = "Organize, reorder, and navigate your macOS Spaces."
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 96, height: 96)
            alert.icon = image
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func observeActiveSpaceChanges() {
        activeSpaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOverlayPresented else { return }
                self.refreshDiscoveredSpaces()
            }
        }
    }

    private func startActiveSpacePolling() {
        activeSpacePollTimer?.invalidate()
        activeSpacePollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOverlayPresented,
                      let nativeSpaceID = SkyLightSpaceDiscovery.currentActiveSpaceID() else { return }
                self.store.selectActiveSpace(nativeID: nativeSpaceID)
                if self.lastObservedActiveSpaceID != nativeSpaceID {
                    self.lastObservedActiveSpaceID = nativeSpaceID
                    self.refreshDiscoveredSpaces()
                }
            }
        }
    }

    private func stopActiveSpacePolling() {
        activeSpacePollTimer?.invalidate()
        activeSpacePollTimer = nil
        lastObservedActiveSpaceID = nil
    }

    private func installInvocationHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<OverlayController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var identifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard parameterStatus == noErr else { return noErr }
                Task { @MainActor in
                    switch identifier.id {
                    case 1:
                        controller.toggleOverlay()
                    case 2 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerArrowNavigation,
                            object: nil,
                            userInfo: ["isUpArrow": true]
                        )
                    case 3 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerArrowNavigation,
                            object: nil,
                            userInfo: ["isUpArrow": false]
                        )
                    case 4 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerHorizontalNavigation,
                            object: nil,
                            userInfo: ["isLeftArrow": true]
                        )
                    case 5 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerHorizontalNavigation,
                            object: nil,
                            userInfo: ["isLeftArrow": false]
                        )
                    case 6 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerSpaceActivation, object: nil)
                    case 7 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerHeaderFocus, object: nil)
                    case 8 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerRowReorder,
                            object: nil,
                            userInfo: ["isUp": true]
                        )
                    case 9 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerRowReorder,
                            object: nil,
                            userInfo: ["isUp": false]
                        )
                    case 10 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerHorizontalReorder,
                            object: nil,
                            userInfo: ["isLeft": true]
                        )
                    case 11 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerHorizontalReorder,
                            object: nil,
                            userInfo: ["isLeft": false]
                        )
                    case 12 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerRowDeletion, object: nil)
                    case 13 where controller.isOverlayPresented:
                        controller.store.addRow()
                    case 14 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerSpaceMove,
                            object: nil,
                            userInfo: ["isUp": true]
                        )
                    case 15 where controller.isOverlayPresented:
                        NotificationCenter.default.post(
                            name: .organizerSpaceMove,
                            object: nil,
                            userInfo: ["isUp": false]
                        )
                    case 16 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerRowEdit, object: nil, userInfo: ["action": "rename"])
                    case 17 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerRowEdit, object: nil, userInfo: ["action": "icon"])
                    case 18 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerRowEdit, object: nil, userInfo: ["action": "color"])
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        guard status == noErr else {
            NSLog("Mission Control Ultra could not install its hotkey handler: \(status)")
            return
        }

        let identifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 1)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(controlKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if registrationStatus == noErr {
            NSLog("Mission Control Ultra registered Control-Shift-Up")
        } else {
            NSLog("Mission Control Ultra could not register Control-Shift-Up: \(registrationStatus)")
        }

        let upNavigationIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 2)
        let upNavigationStatus = RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(cmdKey),
            upNavigationIdentifier,
            GetApplicationEventTarget(),
            0,
            &navigateUpHotKey
        )
        let downNavigationIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 3)
        let downNavigationStatus = RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(cmdKey),
            downNavigationIdentifier,
            GetApplicationEventTarget(),
            0,
            &navigateDownHotKey
        )
        if upNavigationStatus == noErr, downNavigationStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Up and Command-Down")
        } else {
            NSLog("Mission Control Ultra could not register Command arrow navigation: \(upNavigationStatus), \(downNavigationStatus)")
        }

        let leftNavigationIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 4)
        let leftNavigationStatus = RegisterEventHotKey(
            UInt32(kVK_LeftArrow),
            UInt32(cmdKey),
            leftNavigationIdentifier,
            GetApplicationEventTarget(),
            0,
            &navigateLeftHotKey
        )
        let rightNavigationIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 5)
        let rightNavigationStatus = RegisterEventHotKey(
            UInt32(kVK_RightArrow),
            UInt32(cmdKey),
            rightNavigationIdentifier,
            GetApplicationEventTarget(),
            0,
            &navigateRightHotKey
        )
        let activateSpaceIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 6)
        let activateSpaceStatus = RegisterEventHotKey(
            UInt32(kVK_Return),
            UInt32(cmdKey),
            activateSpaceIdentifier,
            GetApplicationEventTarget(),
            0,
            &activateSpaceHotKey
        )
        if leftNavigationStatus == noErr, rightNavigationStatus == noErr, activateSpaceStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Left, Command-Right, and Command-Return")
        } else {
            NSLog("Mission Control Ultra could not register Command space navigation: \(leftNavigationStatus), \(rightNavigationStatus), \(activateSpaceStatus)")
        }

        let headerFocusIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 7)
        let headerFocusStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Z),
            UInt32(cmdKey | controlKey),
            headerFocusIdentifier,
            GetApplicationEventTarget(),
            0,
            &focusHeaderHotKey
        )
        if headerFocusStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Control-Z for header focus")
        } else {
            NSLog("Mission Control Ultra could not register Command-Control-Z for header focus: \(headerFocusStatus)")
        }

        let moveRowUpIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 8)
        let moveRowUpStatus = RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(cmdKey | shiftKey),
            moveRowUpIdentifier,
            GetApplicationEventTarget(),
            0,
            &moveRowUpHotKey
        )
        let moveRowDownIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 9)
        let moveRowDownStatus = RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(cmdKey | shiftKey),
            moveRowDownIdentifier,
            GetApplicationEventTarget(),
            0,
            &moveRowDownHotKey
        )
        if moveRowUpStatus == noErr, moveRowDownStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Shift-Up and Command-Shift-Down")
        } else {
            NSLog("Mission Control Ultra could not register Command-Shift row sorting: \(moveRowUpStatus), \(moveRowDownStatus)")
        }

        let moveItemLeftIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 10)
        let moveItemLeftStatus = RegisterEventHotKey(
            UInt32(kVK_LeftArrow),
            UInt32(cmdKey | shiftKey),
            moveItemLeftIdentifier,
            GetApplicationEventTarget(),
            0,
            &moveItemLeftHotKey
        )
        let moveItemRightIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 11)
        let moveItemRightStatus = RegisterEventHotKey(
            UInt32(kVK_RightArrow),
            UInt32(cmdKey | shiftKey),
            moveItemRightIdentifier,
            GetApplicationEventTarget(),
            0,
            &moveItemRightHotKey
        )
        if moveItemLeftStatus == noErr, moveItemRightStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Shift-Left and Command-Shift-Right")
        } else {
            NSLog("Mission Control Ultra could not register Command-Shift horizontal sorting: \(moveItemLeftStatus), \(moveItemRightStatus)")
        }

        let deleteRowIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 12)
        let deleteRowStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Z),
            UInt32(cmdKey | shiftKey),
            deleteRowIdentifier,
            GetApplicationEventTarget(),
            0,
            &deleteRowHotKey
        )
        if deleteRowStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Shift-Z for row deletion")
        } else {
            NSLog("Mission Control Ultra could not register Command-Shift-Z for row deletion: \(deleteRowStatus)")
        }

        let addRowIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 13)
        let addRowStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey),
            addRowIdentifier,
            GetApplicationEventTarget(),
            0,
            &addRowHotKey
        )
        if addRowStatus == noErr {
            NSLog("Mission Control Ultra registered Command-A for adding rows")
        } else {
            NSLog("Mission Control Ultra could not register Command-A for adding rows: \(addRowStatus)")
        }

        let moveSpaceUpIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 14)
        let moveSpaceUpStatus = RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(cmdKey | optionKey),
            moveSpaceUpIdentifier,
            GetApplicationEventTarget(),
            0,
            &moveSpaceUpHotKey
        )
        let moveSpaceDownIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 15)
        let moveSpaceDownStatus = RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(cmdKey | optionKey),
            moveSpaceDownIdentifier,
            GetApplicationEventTarget(),
            0,
            &moveSpaceDownHotKey
        )
        if moveSpaceUpStatus == noErr, moveSpaceDownStatus == noErr {
            NSLog("Mission Control Ultra registered Command-Option-Up and Command-Option-Down")
        } else {
            NSLog("Mission Control Ultra could not register Command-Option space movement: \(moveSpaceUpStatus), \(moveSpaceDownStatus)")
        }

        let renameRowIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 16)
        let renameRowStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(cmdKey), renameRowIdentifier,
            GetApplicationEventTarget(), 0, &renameRowHotKey
        )
        let pickIconIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 17)
        let pickIconStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_I), UInt32(cmdKey), pickIconIdentifier,
            GetApplicationEventTarget(), 0, &pickIconHotKey
        )
        let pickColorIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 18)
        let pickColorStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey), pickColorIdentifier,
            GetApplicationEventTarget(), 0, &pickColorHotKey
        )
        if renameRowStatus == noErr, pickIconStatus == noErr, pickColorStatus == noErr {
            NSLog("Mission Control Ultra registered Command-R, Command-I, and Command-Option-C for row editing")
        } else {
            NSLog("Mission Control Ultra could not register row editing shortcuts: \(renameRowStatus), \(pickIconStatus), \(pickColorStatus)")
        }
    }

    private func overlayFrames() -> (start: NSRect, destination: NSRect)? {
        guard let screen = NSScreen.main else { return nil }
        let screenFrame = screen.frame
        let size = NSSize(
            width: screenFrame.width,
            height: min(820, screenFrame.height)
        )
        let destination = NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let start = NSRect(
            x: destination.minX,
            y: screenFrame.maxY + 24,
            width: size.width,
            height: size.height
        )
        return (start, destination)
    }

    func showOverlay() {
        guard let frames = overlayFrames() else { return }
        if panel == nil {
            let newPanel = OverlayPanel(
                contentRect: frames.start,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false
            newPanel.isReleasedWhenClosed = false
            newPanel.level = .screenSaver
            newPanel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .transient,
            ]
            newPanel.contentView = NSHostingView(
                rootView: OrganizerView(store: store, onDismiss: { [weak self] in
                    self?.dismissOverlay()
                }, onActivateSpace: { [weak self] space in
                    self?.activate(space: space)
                }, onMoveToDesktop: { [weak self] space in
                    self?.moveToDesktop(space: space)
                }, onCloseSpace: { [weak self] space in
                    self?.close(space: space)
                }, onBeginCardDrag: { [weak self] in
                    self?.beginCardDrag()
                }, onEndCardDrag: { [weak self] in
                    self?.endCardDrag()
                })
            )
            panel = newPanel
        }

        guard let panel else { return }
    panel.level = .screenSaver
        panel.orderOut(nil)
        panel.setFrame(frames.start, display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        isOverlayPresented = true
        lastObservedActiveSpaceID = SkyLightSpaceDiscovery.currentActiveSpaceID()
        startActiveSpacePolling()
        refreshDiscoveredSpaces()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frames.destination, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.refreshDiscoveredSpaces()
        }
    }

    func toggleOverlay() {
        if isOverlayPresented {
            dismissOverlay()
        } else {
            showOverlay()
        }
        updateStatusMenu()
    }

    private func activate(space: SpaceRecord) {
        guard let displayIdentifier = space.displayIdentifier,
              let nativeSpaceID = space.id.split(separator: "-", maxSplits: 1).last.map(String.init) else {
            showSpaceActivationAlert(message: "This card has no native Space identifier.")
            return
        }
        guard let navigation = SkyLightSpaceDiscovery.navigation(
            to: nativeSpaceID,
            on: displayIdentifier
        ) else {
            showSpaceActivationAlert(message: "Mission Control Ultra could not calculate a native Space transition for this card.")
            return
        }
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            showAccessibilityPermissionAlert()
            return
        }
        dismissOverlay()
        Task {
            for step in 0..<navigation.count {
                postSpaceNavigation(direction: navigation.direction)
                if step < navigation.count - 1 {
                    try? await Task.sleep(for: .milliseconds(260))
                }
            }
        }
    }

    private func moveToDesktop(space: SpaceRecord) {
        guard (space.kind == .fullScreenApp || space.kind == .splitView),
              let processIdentifier = space.applicationProcessIdentifiers.first,
              CGPreflightPostEventAccess() else { return }
        activate(space: space)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [])
            self?.postExitFullScreenShortcut()
        }
    }

    private func close(space: SpaceRecord) {
        guard let processIdentifier = space.applicationProcessIdentifiers.first,
              let application = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        application.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshDiscoveredSpaces()
        }
    }

    private func beginCardDrag() {
        panel?.level = .popUpMenu
        guard dragReleaseMonitor == nil else { return }
        dragReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self,
                  let panel = self.panel,
                  !panel.frame.contains(NSEvent.mouseLocation) else { return event }
            self.endCardDrag()
            return nil
        }
    }

    private func endCardDrag() {
        if let dragReleaseMonitor {
            NSEvent.removeMonitor(dragReleaseMonitor)
            self.dragReleaseMonitor = nil
        }
        panel?.level = .screenSaver
    }

    private func postExitFullScreenShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifiers: CGEventFlags = [.maskControl, .maskCommand]
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_F), keyDown: true)
        keyDown?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_F), keyDown: false)
        keyUp?.flags = modifiers
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postSpaceNavigation(direction: SpaceNavigationDirection) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifiers = configuredSpaceNavigationModifiers(for: direction)

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: direction.keyCode,
            keyDown: true
        )
        keyDown?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: direction.keyCode,
            keyDown: false
        )
        keyUp?.flags = modifiers
        keyUp?.post(tap: .cghidEventTap)
    }

    private func configuredSpaceNavigationModifiers(for direction: SpaceNavigationDirection) -> CGEventFlags {
        let symbolicHotKeyID = direction == .left ? "79" : "81"
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        let hotKeys = defaults?.dictionary(forKey: "AppleSymbolicHotKeys")
        let hotKey = hotKeys?[symbolicHotKeyID] as? [String: Any]
        let value = hotKey?["value"] as? [String: Any]
        let parameters = value?["parameters"] as? [NSNumber]
        guard parameters?.count ?? 0 > 2 else { return .maskControl }
        return CGEventFlags(rawValue: parameters![2].uint64Value)
    }

    private func showAccessibilityPermissionAlert() {
        showSpaceActivationAlert(
            message: "Enable Mission Control Ultra in Privacy & Security > Accessibility, then return here and select the Space again.",
            opensAccessibilitySettings: true
        )
    }

    private func showSpaceActivationAlert(message: String, opensAccessibilitySettings: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = opensAccessibilitySettings ? "Accessibility Permission Required" : "Space Selection Unavailable"
        alert.informativeText = message
        if opensAccessibilitySettings {
            alert.addButton(withTitle: "Open Settings")
        }
        alert.addButton(withTitle: "Cancel")
        if opensAccessibilitySettings,
           alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if !opensAccessibilitySettings {
            alert.runModal()
        }
    }

    private func dismissOverlay() {
        guard let panel else { return }
        isOverlayPresented = false
        updateStatusMenu()
        stopActiveSpacePolling()
        let hiddenFrame = panel.frame.offsetBy(dx: 0, dy: 36)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func refreshDiscoveredSpaces() {
        if !CGPreflightScreenCaptureAccess() {
            requestScreenCaptureAccessIfNeeded()
        }
        Task {
            let spaces = await SkyLightSpaceDiscovery().currentSpaces()
            NSLog("Mission Control Ultra applying \(spaces.count) discovered Spaces.")
            store.reconcile(discovered: spaces)
        }
    }
}

extension OverlayController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu()
    }
}

@MainActor
private final class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var systemUsedPercentage = 0
    @Published private(set) var processMemoryBytes: [pid_t: UInt64] = [:]

    private var trackedProcessIdentifiers: Set<pid_t> = []
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

    func updateTrackedProcessIdentifiers(_ processIdentifiers: [pid_t]) {
        let identifiers = Set(processIdentifiers)
        guard identifiers != trackedProcessIdentifiers else { return }
        trackedProcessIdentifiers = identifiers
        refresh()
    }

    func memoryBytes(for space: SpaceRecord) -> UInt64? {
        let bytes = space.applicationProcessIdentifiers.reduce(UInt64(0)) {
            $0 + (processMemoryBytes[$1] ?? 0)
        }
        return bytes > 0 ? bytes : nil
    }

    private func refresh() {
        systemUsedPercentage = currentSystemMemoryPercentage()
        processMemoryBytes = Dictionary(
            uniqueKeysWithValues: trackedProcessIdentifiers.compactMap { processIdentifier in
                processMemoryBytes(for: processIdentifier).map { (processIdentifier, $0) }
            }
        )
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

    private func processMemoryBytes(for processIdentifier: pid_t) -> UInt64? {
        var taskInfo = proc_taskinfo()
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        return result == MemoryLayout<proc_taskinfo>.size ? taskInfo.pti_resident_size : nil
    }
}

private enum OrganizerKeyboardFocus: Equatable {
    case header(selectedRowID: UUID?)
    case row(UUID, spaceID: String?)
}

private enum RowEditAction: String {
    case rename
    case icon
    case color
}

private struct RowEditRequest: Equatable {
    let rowID: UUID
    let action: RowEditAction
    let token = UUID()
}

private struct RowPickerFocus: Equatable {
    let rowID: UUID
    let action: RowEditAction
}

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
        .onAppear {
            memoryUsage.updateTrackedProcessIdentifiers(store.rows.flatMap(\.spaces).flatMap(\.applicationProcessIdentifiers))
        }
        .onReceive(store.$rows) { rows in
            memoryUsage.updateTrackedProcessIdentifiers(rows.flatMap(\.spaces).flatMap(\.applicationProcessIdentifiers))
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerArrowNavigation)) { notification in
            let isUp = notification.userInfo?["isUpArrow"] as? Bool ?? false
            if activePicker != nil {
                navigatePicker(horizontal: false, backwards: isUp)
            } else {
                moveKeyboardFocus(up: isUp)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerHorizontalNavigation)) { notification in
            let isLeft = notification.userInfo?["isLeftArrow"] as? Bool ?? false
            if activePicker != nil {
                navigatePicker(horizontal: true, backwards: isLeft)
            } else {
                moveKeyboardSpaceFocus(left: isLeft)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerSpaceActivation)) { _ in
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
        .onReceive(NotificationCenter.default.publisher(for: .organizerHeaderFocus)) { _ in
            keyboardFocus = .header(selectedRowID: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowReorder)) { notification in
            moveKeyboardFocusedRow(up: notification.userInfo?["isUp"] as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerHorizontalReorder)) { notification in
            moveKeyboardFocusedItem(left: notification.userInfo?["isLeft"] as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowDeletion)) { _ in
            deleteKeyboardFocusedRow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerSpaceMove)) { notification in
            moveKeyboardFocusedSpace(up: notification.userInfo?["isUp"] as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizerRowEdit)) { notification in
            guard let rowID = keyboardFocusedRowID,
                  let actionName = notification.userInfo?["action"] as? String,
                  let action = RowEditAction(rawValue: actionName) else { return }
            if action == .rename {
                activePicker = nil
            } else if activePicker == RowPickerFocus(rowID: rowID, action: action) {
                activePicker = nil
            } else {
                activePicker = RowPickerFocus(rowID: rowID, action: action)
            }
            rowEditRequest = RowEditRequest(rowID: rowID, action: action)
        }
    }

    private var header: some View {
        HStack {
            Text("Spaces Manager")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            Button(action: store.addRow) {
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
            .help("Close Mission Control Ultra")
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
                            keyboardFocusedHeaderChipID == row.id ? Color(hex: "73BCEB") : (focusedRowID == row.id ? .white : .white.opacity(0.22)),
                            lineWidth: keyboardFocusedHeaderChipID == row.id || focusedRowID == row.id ? 2 : 1
                        )
                    }
                }
                .buttonStyle(.plain)
                .help("Show \(row.name)")
                .onDrag {
                    onBeginCardDrag()
                    return rowChipDragProvider(for: row.id)
                }
                .onDrop(of: [.missionControlRow], isTargeted: nil) { providers in
                    moveRowFrom(providers, before: row.id)
                }
            }
        }
        .padding(.horizontal, 4)
        .onDrop(of: [.missionControlRow], isTargeted: nil) { providers in
            moveRowFrom(providers, before: nil)
        }
    }

    private func rowChipDragProvider(for rowID: UUID) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(RowDragItem(id: rowID))) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.missionControlRow.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func moveRowFrom(_ providers: [NSItemProvider], before targetRowID: UUID?) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.missionControlRow.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.missionControlRow.identifier) { data, _ in
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

private struct RowView: View {
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

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 12) {
                    ForEach(row.spaces) { space in
                        ZStack(alignment: .topLeading) {
                            Button { onSelect(space) } label: {
                                SpaceCard(
                                    space: space,
                                    isSelected: space.id == selectedSpaceID,
                                    isKeyboardFocused: space.id == keyboardFocusedSpaceID,
                                    memoryBytes: memoryUsage.memoryBytes(for: space)
                                )
                            }
                            .buttonStyle(.plain)

                            if space.kind == .fullScreenApp || space.kind == .splitView {
                                Button { onMoveToDesktop(space) } label: {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.caption.weight(.heavy))
                                        .foregroundStyle(.black)
                                        .frame(width: 30, height: 30)
                                        .background(.white, in: Circle())
                                        .overlay {
                                            Circle().stroke(.black.opacity(0.12), lineWidth: 1)
                                        }
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
                                        .overlay {
                                            Circle().stroke(.black.opacity(0.12), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .help("Quit \(space.name)")
                                .padding(6)
                            }
                        }
                        .onDrop(of: [.missionControlSpace], isTargeted: nil) { providers in
                            let accepted = moveFrom(providers: providers, before: space.id)
                            if accepted { onEndCardDrag() }
                            return accepted
                        }
                        .onDrag {
                            onBeginCardDrag()
                            return spaceDragProvider(space.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 102, alignment: .top)
            .onDrop(of: [.missionControlRow, .missionControlSpace], isTargeted: nil, perform: moveRowOrSpaceFrom)
        }
        .padding(14)
        .frame(height: 155)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(draggedRowID == row.id ? 0.42 : 1)
        .contentShape(Rectangle())
        .onDrop(of: [.missionControlRow], isTargeted: nil, perform: swapRowFrom)
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
                    emojiSelectionIndex = emojiOptions.firstIndex(of: row.emoji) ?? 0
                }
            case .color:
                isColorPickerPresented.toggle()
                if isColorPickerPresented {
                    colorSelectionIndex = ColorPalette.values.firstIndex(of: row.accentHex) ?? 0
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
                                index == colorSelectionIndex ? Color(hex: "73BCEB") : (row.accentHex == hex ? .white : .black.opacity(0.2)),
                                lineWidth: index == colorSelectionIndex || row.accentHex == hex ? 2 : 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
        .padding(10)
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
            $0.hasItemConformingToTypeIdentifier(UTType.missionControlRow.identifier)
        }) {
            rowProvider.loadDataRepresentation(forTypeIdentifier: UTType.missionControlRow.identifier) { data, _ in
                guard let data,
                      let item = try? JSONDecoder().decode(RowDragItem.self, from: data) else { return }
                Task { @MainActor in
                    swapRow(item.id)
                }
            }
            return true
        }

        guard let spaceProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.missionControlSpace.identifier)
        }) else { return false }
        spaceProvider.loadDataRepresentation(forTypeIdentifier: UTType.missionControlSpace.identifier) { data, _ in
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
            $0.hasItemConformingToTypeIdentifier(UTType.missionControlRow.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.missionControlRow.identifier) { data, _ in
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
            $0.hasItemConformingToTypeIdentifier(UTType.missionControlSpace.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.missionControlSpace.identifier) { data, _ in
            guard let data,
                  let spaceID = String(data: data, encoding: .utf8),
                  spaceID != targetSpaceID else { return }
            Task { @MainActor in onMove(spaceID, targetSpaceID) }
        }
        return true
    }

    private func rowDragProvider() -> NSItemProvider {
        let data = (try? JSONEncoder().encode(RowDragItem(id: row.id))) ?? Data()
        return internalDragProvider(for: .missionControlRow, data: data)
    }

    private func spaceDragProvider(_ spaceID: String) -> NSItemProvider {
        internalDragProvider(for: .missionControlSpace, data: Data(spaceID.utf8))
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

private struct RowDragPreview: View {
    let row: SpaceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(row.emoji)
                Circle().fill(Color(hex: row.accentHex)).frame(width: 14, height: 14)
                Text(row.name).font(.headline)
                Text("\(row.spaces.count) spaces").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(row.spaces.prefix(4)) { space in
                    SpaceCard(space: space, isSelected: false, isKeyboardFocused: false, memoryBytes: nil)
                        .scaleEffect(0.5, anchor: .topLeading)
                        .frame(width: 80, height: 51, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct SpaceCard: View {
    let space: SpaceRecord
    let isSelected: Bool
    let isKeyboardFocused: Bool
    let memoryBytes: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let thumbnail = space.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(hex: "263C34"), Color(hex: "111C1A")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: space.kind.icon)
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(12)
                }
            }
            .frame(height: 68)
            .clipped()
            HStack {
                Text(space.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(memoryLabel)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .font(.caption.weight(.medium))
            .padding(7)
        }
        .frame(width: 160)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isKeyboardFocused ? Color(hex: "73BCEB") : (isSelected ? Color.white : .white.opacity(0.18)),
                    lineWidth: isKeyboardFocused || isSelected ? 2 : 1
                )
        }
    }

    private var memoryLabel: String {
        guard let memoryBytes else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }
}

private enum ColorPalette {
    static let values = [
        "EF6A6A", "F39A4E", "E8C75F", "B9D76B", "75C98D",
        "56C5A8", "57C8D5", "73BCEB", "7897E8", "9D83DC",
        "C77BD7", "E899AE", "C77764", "AE9275", "858C98",
        "F4A5A5", "F5C287", "E5DC86", "9BCF89", "85D4C7",
    ]
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}