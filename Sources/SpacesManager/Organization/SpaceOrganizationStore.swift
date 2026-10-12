import AppKit
import Combine
import CoreGraphics
import Foundation

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
    @Published var spaceSelectionWarning: String?

    private let unsortedRowID: UUID
    private var storedAssignments: [String: UUID]
    private var storedSpaceOrder: [String]
    private let persistenceKey = "SpacesManager.rowOrganization"
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

    func addRow() -> UUID? {
        guard canAddRow else { return nil }
        let row = SpaceRow(name: "Untitled Row", emoji: "📁", accentHex: "85D4C7")
        rows.append(row)
        persistOrganization()
        return row.id
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
        if sourceIndex == destinationIndex,
           let targetSpaceID,
           let targetIndex = rows[sourceIndex].spaces.firstIndex(where: { $0.id == targetSpaceID }) {
            rows[sourceIndex].spaces.swapAt(spaceIndex, targetIndex)
            if let sourceOrderIndex = storedSpaceOrder.firstIndex(of: spaceID),
               let targetOrderIndex = storedSpaceOrder.firstIndex(of: targetSpaceID) {
                storedSpaceOrder.swapAt(sourceOrderIndex, targetOrderIndex)
            }
            persistOrganization()
            return
        }
        let space = rows[sourceIndex].spaces.remove(at: spaceIndex)
        let targetIndex = targetSpaceID.flatMap { targetSpaceID in
            rows[destinationIndex].spaces.firstIndex(where: { $0.id == targetSpaceID })
        } ?? rows[destinationIndex].spaces.endIndex
        rows[destinationIndex].spaces.insert(space, at: targetIndex)
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
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "SpacesManager.rowOrganization") else { return nil }
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
            .appendingPathComponent("Spaces Manager", isDirectory: true)
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