import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

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

    static func navigation(to nativeSpaceID: String, on displayIdentifier: String) -> SpaceNavigation? {
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
            NSLog("Spaces Manager could not read the SkyLight Space inventory; using the public fallback.")
            return await fallback.currentSpaces()
        }

        let visibleSpaces = await fallback.currentSpaces()
        let windowTitlesByID = await fallback.windowTitlesByID()
        let nativeWindowIDs = Set(snapshot.spaces.flatMap(windowIdentifiers(in:)))
        let windowThumbnailsByID = await fallback.windowThumbnailsByID(for: nativeWindowIDs)
        let desktopThumbnail = visibleSpaces.first(where: { $0.kind == .desktop })?.thumbnail
        var desktopCount = 0

        var records = snapshot.spaces.map { space -> SpaceRecord in
            let identifier = space["ManagedSpaceID"] as? NSNumber
            let spaceID = identifier?.stringValue ?? UUID().uuidString
            let isActive = snapshot.activeSpaceIDs.contains(spaceID)
            let processIdentifiers = processIdentifiers(in: space)
            let windowIdentifiers = windowIdentifiers(in: space)
            let applicationNames = processIdentifiers.compactMap(applicationName(for:))
            let windowTitles = windowIdentifiers.compactMap { windowTitlesByID[$0] }
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
                name = windowTitles.isEmpty ? applicationNames.joined(separator: " + ") : windowTitles.joined(separator: " + ")
            default:
                name = windowTitles.first ?? applicationNames.first ?? "Full Screen App"
            }

            let thumbnail: CGImage?
            if kind == .desktop && isActive {
                thumbnail = desktopThumbnail
            } else if isActive {
                thumbnail = windowIdentifiers.lazy.compactMap { windowThumbnailsByID[$0] }.first
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
                applicationProcessIdentifiers: processIdentifiers,
                windowIdentifiers: windowIdentifiers
            )
        }
        let nativeProcessIdentifiers = Set(records.flatMap(\.applicationProcessIdentifiers))
        let fallbackOnlySpaces = visibleSpaces.filter { space in
            space.kind == .fullScreenApp
                && !space.applicationProcessIdentifiers.isEmpty
                && space.applicationProcessIdentifiers.allSatisfy { !nativeProcessIdentifiers.contains($0) }
        }
        records.append(contentsOf: fallbackOnlySpaces)
        NSLog("Spaces Manager read \(records.count) native Spaces from SkyLight.")
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

    private func windowIdentifiers(in space: [String: Any]) -> [CGWindowID] {
        let tiles = ((space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]]) ?? []
        return (tiles + [space]).compactMap { item in
            let value = (item["TileWindowID"] as? NSNumber) ?? (item["fs_wid"] as? NSNumber)
            return value.map { CGWindowID($0.uint32Value) }
        }
        .reduce(into: []) { identifiers, windowIdentifier in
            if !identifiers.contains(windowIdentifier) {
                identifiers.append(windowIdentifier)
            }
        }
    }

    private func applicationName(for processIdentifier: pid_t) -> String? {
        NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
    }
}

enum SpaceNavigationDirection {
    case left
    case right

    var keyCode: CGKeyCode {
        switch self {
        case .left: CGKeyCode(kVK_LeftArrow)
        case .right: CGKeyCode(kVK_RightArrow)
        }
    }
}

struct SpaceNavigation {
    let direction: SpaceNavigationDirection
    let count: Int
}

struct WindowServerDiscovery: NativeSpaceDiscovering {
    func windowTitlesByID() async -> [CGWindowID: String] {
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: content.windows.compactMap { window -> (CGWindowID, String)? in
                guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else {
                    return nil
                }
                return (window.windowID, title)
            }
        )
    }

    func windowThumbnailsByID(for windowIdentifiers: Set<CGWindowID>) async -> [CGWindowID: CGImage] {
        guard !windowIdentifiers.isEmpty,
              CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
              ) else {
            return [:]
        }

        var thumbnails: [CGWindowID: CGImage] = [:]
        for window in content.windows where windowIdentifiers.contains(window.windowID) {
            let configuration = SCStreamConfiguration()
            configuration.width = 480
            configuration.height = 270
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            ) {
                thumbnails[window.windowID] = image
            }
        }
        return thumbnails
    }

    func currentSpaces() async -> [SpaceRecord] {
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("Spaces Manager needs Screen Recording permission before it can discover Spaces.")
            return []
        }
        let ownProcessID = Int(ProcessInfo.processInfo.processIdentifier)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            NSLog("Spaces Manager could not enumerate shareable windows: \(error.localizedDescription)")
            return []
        }
        NSLog(
            "Spaces Manager found \(content.displays.count) displays and \(content.windows.count) shareable windows."
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
                && isFullScreen(application.processID)
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
            "Spaces Manager retained \(appWindows.count) app windows across \(largestWindowByProcess.count) applications."
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
                    applicationProcessIdentifiers: [application.processID],
                    windowIdentifiers: [window.windowID]
                )
            )
        }
        NSLog("Spaces Manager created \(discovered.count) Space cards.")
        return discovered.sorted { lhs, rhs in
            lhs.kind == .desktop ? false : rhs.kind == .desktop ? true : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func isFullScreen(_ processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement] else {
            return false
        }
        return windows.contains { window in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else {
                return false
            }
            return value as? Bool == true
        }
    }
}