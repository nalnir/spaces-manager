import AppKit
import ApplicationServices
import Combine
import Carbon
import CoreGraphics
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@main
struct SpacesManagerApp: App {
    @NSApplicationDelegateAdaptor(OverlayController.self) private var overlayController

    var body: some Scene {
        Settings { EmptyView() }
    }
}
