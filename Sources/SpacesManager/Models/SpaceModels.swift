import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let spacesManagerRow = UTType(exportedAs: "com.lukasstateczny.spaces-manager.row-reorder", conformingTo: .data)
    static let spacesManagerSpace = UTType(exportedAs: "com.lukasstateczny.spaces-manager.space-reorder", conformingTo: .data)
}

struct RowDragItem: Codable, Identifiable {
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
    var windowIdentifiers: [CGWindowID]

    init(
        id: String,
        name: String,
        kind: SpaceKind,
        applications: [String],
        thumbnail: CGImage? = nil,
        isActive: Bool = false,
        displayIdentifier: String? = nil,
        applicationProcessIdentifiers: [pid_t] = [],
        windowIdentifiers: [CGWindowID] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.applications = applications
        self.thumbnail = thumbnail
        self.isActive = isActive
        self.displayIdentifier = displayIdentifier
        self.applicationProcessIdentifiers = applicationProcessIdentifiers
        self.windowIdentifiers = windowIdentifiers
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