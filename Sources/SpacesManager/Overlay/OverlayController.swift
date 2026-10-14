import AppKit
import ApplicationServices
import Combine
import Carbon
import CoreGraphics
import Darwin
import SwiftUI
import UniformTypeIdentifiers
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let organizerArrowNavigation = Notification.Name("SpacesManager.organizerArrowNavigation")
    static let organizerHorizontalNavigation = Notification.Name("SpacesManager.organizerHorizontalNavigation")
    static let organizerSpaceActivation = Notification.Name("SpacesManager.organizerSpaceActivation")
    static let organizerRowNameCommit = Notification.Name("SpacesManager.organizerRowNameCommit")
    static let organizerHeaderFocus = Notification.Name("SpacesManager.organizerHeaderFocus")
    static let organizerRowReorder = Notification.Name("SpacesManager.organizerRowReorder")
    static let organizerHorizontalReorder = Notification.Name("SpacesManager.organizerHorizontalReorder")
    static let organizerRowDeletion = Notification.Name("SpacesManager.organizerRowDeletion")
    static let organizerRowAddition = Notification.Name("SpacesManager.organizerRowAddition")
    static let organizerSpaceMove = Notification.Name("SpacesManager.organizerSpaceMove")
    static let organizerSpaceMinimize = Notification.Name("SpacesManager.organizerSpaceMinimize")
    static let organizerSpaceExit = Notification.Name("SpacesManager.organizerSpaceExit")
    static let organizerRowEdit = Notification.Name("SpacesManager.organizerRowEdit")
    static let organizerPickerNavigation = Notification.Name("SpacesManager.organizerPickerNavigation")
    static let organizerPickerApply = Notification.Name("SpacesManager.organizerPickerApply")
}

@MainActor
@main
final class OverlayController: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = OverlayController()
        application.delegate = delegate
        application.run()
    }

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
    private var minimizeSpaceHotKey: EventHotKeyRef?
    private var exitSpaceHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var activeSpaceObserver: NSObjectProtocol?
    private var activeSpacePollTimer: Timer?
    private var discoveryTask: Task<Void, Never>?
    private var lastObservedActiveSpaceID: String?
    private var isOverlayPresented = false
    private var dragReleaseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var isAwaitingAccessibilityAuthorization = false
    private var hasPromptedForAccessibilityRestart = false
    private var accessibilityAuthorizationPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installInvocationHotKey()
        observeActiveSpaceChanges()
        NSLog("Spaces Manager can post Space navigation events: \(CGPreflightPostEventAccess())")
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
        if let minimizeSpaceHotKey { UnregisterEventHotKey(minimizeSpaceHotKey) }
        if let exitSpaceHotKey { UnregisterEventHotKey(exitSpaceHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let activeSpaceObserver { NotificationCenter.default.removeObserver(activeSpaceObserver) }
        if let dragReleaseMonitor { NSEvent.removeMonitor(dragReleaseMonitor) }
        activeSpacePollTimer?.invalidate()
        accessibilityAuthorizationPollTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkAccessibilityAuthorization()
    }

    private func checkAccessibilityAuthorization() {
        guard isAwaitingAccessibilityAuthorization,
              !hasPromptedForAccessibilityRestart,
              AXIsProcessTrusted() else { return }
        isAwaitingAccessibilityAuthorization = false
        hasPromptedForAccessibilityRestart = true
        accessibilityAuthorizationPollTimer?.invalidate()
        accessibilityAuthorizationPollTimer = nil
        NSApp.activate(ignoringOtherApps: true)
        promptForAccessibilityRestart()
    }

    private func requestScreenCaptureAccessIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        CGRequestScreenCaptureAccess()
    }

    private func requestAccessibilityAccessIfNeeded() {
        guard !CGPreflightPostEventAccess() else { return }
        isAwaitingAccessibilityAuthorization = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary)
        accessibilityAuthorizationPollTimer?.invalidate()
        accessibilityAuthorizationPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAccessibilityAuthorization()
            }
        }
    }

    private func promptForAccessibilityRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart Spaces Manager?"
        alert.informativeText = "Accessibility permission was granted. Restart Spaces Manager to use it."
        alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            NSApp.terminate(nil)
        }
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
        toggleItem.keyEquivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        toggleItem.keyEquivalentModifierMask = [.control, .shift]
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
        scheduleScreenRecordingPermissionRelaunch()
        requestScreenCaptureAccessIfNeeded()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleScreenRecordingPermissionRelaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "parent_process_id=$1; app_bundle=$2; deadline=$((SECONDS + 75)); while (( SECONDS < deadline )); do if ! kill -0 \"$parent_process_id\" 2>/dev/null; then open \"$app_bundle\"; exit 0; fi; sleep 0.2; done",
            "spaces-manager-screen-recording-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        try? process.run()
    }

    @objc private func openAccessibilitySettings() {
        requestAccessibilityAccessIfNeeded()
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
                    if identifier.id != 16 {
                        NotificationCenter.default.post(name: .organizerRowNameCommit, object: nil)
                    }
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
                        NotificationCenter.default.post(name: .organizerRowAddition, object: nil)
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
                    case 19 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerSpaceMinimize, object: nil)
                    case 20 where controller.isOverlayPresented:
                        NotificationCenter.default.post(name: .organizerSpaceExit, object: nil)
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
            NSLog("Spaces Manager could not install its hotkey handler: \(status)")
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
            NSLog("Spaces Manager registered Control-Shift-Up")
        } else {
            NSLog("Spaces Manager could not register Control-Shift-Up: \(registrationStatus)")
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
            NSLog("Spaces Manager registered Command-Up and Command-Down")
        } else {
            NSLog("Spaces Manager could not register Command arrow navigation: \(upNavigationStatus), \(downNavigationStatus)")
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
            NSLog("Spaces Manager registered Command-Left, Command-Right, and Command-Return")
        } else {
            NSLog("Spaces Manager could not register Command space navigation: \(leftNavigationStatus), \(rightNavigationStatus), \(activateSpaceStatus)")
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
            NSLog("Spaces Manager registered Command-Control-Z for header focus")
        } else {
            NSLog("Spaces Manager could not register Command-Control-Z for header focus: \(headerFocusStatus)")
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
            NSLog("Spaces Manager registered Command-Shift-Up and Command-Shift-Down")
        } else {
            NSLog("Spaces Manager could not register Command-Shift row sorting: \(moveRowUpStatus), \(moveRowDownStatus)")
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
            NSLog("Spaces Manager registered Command-Shift-Left and Command-Shift-Right")
        } else {
            NSLog("Spaces Manager could not register Command-Shift horizontal sorting: \(moveItemLeftStatus), \(moveItemRightStatus)")
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
            NSLog("Spaces Manager registered Command-Shift-Z for row deletion")
        } else {
            NSLog("Spaces Manager could not register Command-Shift-Z for row deletion: \(deleteRowStatus)")
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
            NSLog("Spaces Manager registered Command-A for adding rows")
        } else {
            NSLog("Spaces Manager could not register Command-A for adding rows: \(addRowStatus)")
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
            NSLog("Spaces Manager registered Command-Option-Up and Command-Option-Down")
        } else {
            NSLog("Spaces Manager could not register Command-Option space movement: \(moveSpaceUpStatus), \(moveSpaceDownStatus)")
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
        let minimizeSpaceIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 19)
        let minimizeSpaceStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_M), UInt32(cmdKey), minimizeSpaceIdentifier,
            GetApplicationEventTarget(), 0, &minimizeSpaceHotKey
        )
        let exitSpaceIdentifier = EventHotKeyID(signature: OSType(0x4D43554C), id: 20)
        let exitSpaceStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_W), UInt32(cmdKey), exitSpaceIdentifier,
            GetApplicationEventTarget(), 0, &exitSpaceHotKey
        )
        if minimizeSpaceStatus == noErr, exitSpaceStatus == noErr {
            NSLog("Spaces Manager registered Command-M and Command-W for focused Spaces")
        } else {
            NSLog("Spaces Manager could not register Command-M or Command-W: \(minimizeSpaceStatus), \(exitSpaceStatus)")
        }
        if renameRowStatus == noErr, pickIconStatus == noErr, pickColorStatus == noErr {
            NSLog("Spaces Manager registered Command-R, Command-I, and Command-Option-C for row editing")
        } else {
            NSLog("Spaces Manager could not register row editing shortcuts: \(renameRowStatus), \(pickIconStatus), \(pickColorStatus)")
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
            showSpaceActivationAlert(message: "Spaces Manager could not calculate a native Space transition for this card.")
            return
        }
        guard navigation.count == 0 || isSpaceNavigationEnabled(direction: navigation.direction) else {
            showSpaceActivationAlert(message: "Enable Move left a space and Move right a space in System Settings > Keyboard > Keyboard Shortcuts > Mission Control.")
            return
        }
        guard CGPreflightPostEventAccess() else {
            requestAccessibilityAccessIfNeeded()
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
          guard (space.kind == .fullScreenApp || space.kind == .splitView),
              let processIdentifier = space.applicationProcessIdentifiers.first else { return }
          guard CGPreflightPostEventAccess() else {
            requestAccessibilityAccessIfNeeded()
            showAccessibilityPermissionAlert()
            return
          }
          guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              let displayIdentifier = space.displayIdentifier,
              let nativeSpaceID = space.id.split(separator: "-", maxSplits: 1).last.map(String.init),
              let navigation = SkyLightSpaceDiscovery.navigation(to: nativeSpaceID, on: displayIdentifier) else {
            showSpaceActivationAlert(message: "Spaces Manager could not navigate to the selected Space to close its window.")
            return
        }

        dismissOverlay()
        Task { [weak self] in
            for step in 0..<navigation.count {
                self?.postSpaceNavigation(direction: navigation.direction)
                if step < navigation.count - 1 {
                    try? await Task.sleep(for: .milliseconds(260))
                }
            }
            try? await Task.sleep(for: .milliseconds(450))
            application.activate(options: [.activateAllWindows])
            guard await self?.closeFocusedWindow(for: processIdentifier) == true else {
                self?.showOverlay()
                self?.showSpaceActivationAlert(message: "Spaces Manager could not close the selected window.")
                return
            }
            self?.refreshAfterClosingSpace()
        }
    }

    private func closeFocusedWindow(for processIdentifier: pid_t) async -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        for _ in 0..<5 {
            if let window = accessibilityWindow(
                for: application,
                attribute: kAXFocusedWindowAttribute as CFString
            ) ?? accessibilityWindow(for: application, attribute: kAXMainWindowAttribute as CFString),
               closeWindow(window) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private func accessibilityWindow(for application: AXUIElement, attribute: CFString) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute, &window) == .success,
              let window else {
            return nil
        }
        return unsafeBitCast(window, to: AXUIElement.self)
    }

    private func closeWindow(_ window: AXUIElement) -> Bool {
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXCloseButton" as CFString, &closeButton) == .success,
              let closeButton else {
            return false
        }
        let button = unsafeBitCast(closeButton, to: AXUIElement.self)
        return AXUIElementPerformAction(button, "AXPress" as CFString) == .success
    }

    private func refreshAfterClosingSpace() {
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
        let shortcut = configuredSpaceNavigationShortcut(for: direction)

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: shortcut.keyCode,
            keyDown: true
        )
        keyDown?.flags = shortcut.modifiers
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: shortcut.keyCode,
            keyDown: false
        )
        keyUp?.flags = shortcut.modifiers
        keyUp?.post(tap: .cghidEventTap)
    }

    private func configuredSpaceNavigationShortcut(for direction: SpaceNavigationDirection) -> (keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let symbolicHotKeyID = direction == .left ? "79" : "81"
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        let hotKeys = defaults?.dictionary(forKey: "AppleSymbolicHotKeys")
        let hotKey = hotKeys?[symbolicHotKeyID] as? [String: Any]
        let value = hotKey?["value"] as? [String: Any]
        let parameters = value?["parameters"] as? [NSNumber]
        guard let parameters, parameters.count > 2 else {
            return (direction.keyCode, .maskControl)
        }
        return (CGKeyCode(parameters[1].uint16Value), CGEventFlags(rawValue: parameters[2].uint64Value))
    }

    private func isSpaceNavigationEnabled(direction: SpaceNavigationDirection) -> Bool {
        let symbolicHotKeyID = direction == .left ? "79" : "81"
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        let hotKeys = defaults?.dictionary(forKey: "AppleSymbolicHotKeys")
        let hotKey = hotKeys?[symbolicHotKeyID] as? [String: Any]
        return hotKey?["enabled"] as? Bool ?? true
    }

    private func showAccessibilityPermissionAlert() {
        dismissOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showSpaceActivationAlert(
                message: "Enable Spaces Manager in Privacy & Security > Accessibility, then return here and select the Space again.",
                opensAccessibilitySettings: true
            )
        }
    }

    private func showSpaceActivationAlert(message: String, opensAccessibilitySettings: Bool = false) {
        guard opensAccessibilitySettings else {
            store.spaceSelectionWarning = message
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = message
        alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func dismissOverlay() {
        guard let panel else { return }
        isOverlayPresented = false
        discoveryTask?.cancel()
        discoveryTask = nil
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
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            let spaces = await SkyLightSpaceDiscovery().currentSpaces()
            guard !Task.isCancelled,
                  let self,
                  self.isOverlayPresented else { return }
            guard !spaces.isEmpty else {
                NSLog("Spaces Manager ignored an empty Space discovery result.")
                return
            }
            NSLog("Spaces Manager applying \(spaces.count) discovered Spaces.")
            store.reconcile(discovered: spaces)
        }
    }
}

extension OverlayController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu()
    }
}

