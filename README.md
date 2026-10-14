# Spaces Manager

A native macOS menu bar app for viewing, organizing, and navigating Mission Control Spaces.

Spaces Manager presents an overlay of the Spaces on your displays, including desktops, full-screen apps, and Split View pairs. Organize them into custom rows, reorder them with drag and drop or the keyboard, and switch to a Space directly from the overlay.

## Install

1. Download `SpacesManager-<version>.zip` from the project's GitHub Releases page.
2. Unzip it, then drag **Spaces Manager.app** to your Applications folder.
3. Open **Spaces Manager.app**. On first launch, macOS may ask you to confirm that you want to open it.
4. Grant **Screen & System Audio Recording** and **Accessibility** in **System Settings > Privacy & Security** when prompted. You can also use the menu-bar icon to open the relevant Settings page.

Updates use the same install process: quit the running app, replace it in Applications with the newer release, then reopen it. Keep the app in Applications so macOS retains its permission grants.

## Features

- Menu bar app with a global overlay toggle.
- Detects desktops, full-screen apps, and Split View Spaces across displays.
- Shows active Space selection, available thumbnails, and native window titles when available.
- Create up to seven custom organization rows in addition to the permanent **Unsorted** row.
- Rename rows and assign an emoji and accent color.
- Drag rows and Space cards to reorder them or move a Space between rows.
- Switch to a selected Space directly from the overlay.
- Move a full-screen or Split View window back to a desktop, or close that selected window from its card.
- Persists row names, styling, Space assignments, and ordering in local user defaults.
- Refreshes as the active macOS Space changes.

## Keyboard Shortcuts

`Control-Shift-Up Arrow` toggles the overlay from anywhere. The remaining shortcuts apply while the overlay is open.

| Shortcut                                                 | Action                                                               |
| -------------------------------------------------------- | -------------------------------------------------------------------- |
| `Command-Up Arrow` / `Command-Down Arrow`                | Move focus between rows                                              |
| `Command-Left Arrow` / `Command-Right Arrow`             | Move focus between Space cards or row chips                          |
| `Command-Return`                                         | Activate the focused Space, or enter the focused row from the header |
| `Command-Control-Z`                                      | Focus the header row chips                                           |
| `Command-Shift-Up Arrow` / `Command-Shift-Down Arrow`    | Move the focused row                                                 |
| `Command-Shift-Left Arrow` / `Command-Shift-Right Arrow` | Reorder the focused Space or row chip                                |
| `Command-Option-Up Arrow` / `Command-Option-Down Arrow`  | Move the focused Space to the previous or next row                   |
| `Command-M`                                              | Move the focused full-screen Space back to a desktop                 |
| `Command-W`                                              | Close the focused full-screen or Split View window                   |
| `Command-Shift-Z`                                        | Delete the focused custom row and return its Spaces to Unsorted      |
| `Command-A`                                              | Add a custom row                                                     |
| `Command-R`                                              | Rename the focused row                                               |
| `Command-I`                                              | Open or close the focused row's icon picker                          |
| `Command-Option-C`                                       | Open or close the focused row's color picker                         |

When an icon or color picker is open, use `Command` with the arrow keys to change the selection and `Command-Return` to apply it.

## Permissions and Limitations

- **Screen Recording** enables window thumbnails. The app remains usable when it is not granted, but cards may show placeholders instead.
- **Accessibility** is required because switching Spaces and exiting full-screen use synthesized macOS input events.
- The app reads the native Space inventory through macOS's private SkyLight framework, with a public WindowServer-based fallback. Private frameworks are unsupported by Apple and may change in future macOS releases.
- Selecting a Space relies on the system's configured Mission Control shortcuts. Keep **Move left a space** and **Move right a space** enabled in macOS Keyboard Shortcuts for reliable navigation.
- This project is not sandboxed and uses the private SkyLight framework, so distribute it directly rather than through the Mac App Store.

## Release Distribution

Use a stable Developer ID signature and Apple notarization for direct distribution. This lets user-granted Screen Recording and Accessibility permissions remain associated with the app across updates.

1. Create a **Developer ID Application** certificate in your Apple Developer account and install it in Keychain Access.
2. Store App Store Connect API credentials as a `notarytool` keychain profile. Replace the placeholders with your credentials:

   ```zsh
   xcrun notarytool store-credentials "SpacesManagerNotary" \
     --key <AuthKey_KEYID.p8> \
     --key-id <KEY_ID> \
     --issuer <ISSUER_ID>
   ```

3. Build, sign, notarize, staple, and archive a release:

   ```zsh
   SPACES_MANAGER_NOTARY_PROFILE="SpacesManagerNotary" ./Scripts/release.sh 0.1.0
   ```

   Set `SPACES_MANAGER_RELEASE_IDENTITY` when more than one Developer ID Application certificate is installed. The completed archive is written to `dist/SpacesManager-0.1.0.zip` and can be published on a website or GitHub Release.

## Development

Development requires macOS 14 Sonoma or later and full Xcode with Swift 5.10+. The Command Line Tools alone do not include the SwiftUI macro plugins. If `xcode-select -p` reports `/Library/Developer/CommandLineTools`, install and open Xcode, then run:

```zsh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

Clone the repository and install a development build with:

```zsh
git clone https://github.com/nalnir/spaces-manager.git
cd spaces-manager
./Scripts/run-app.sh
```

The development installer uses an Apple Development identity when available and otherwise uses ad-hoc signing. It installs the app at `~/Applications/Spaces Manager.app`. Use `./Scripts/spaces-manager` to reopen an installed development build.

Build the executable without installing the application bundle:

```zsh
swift build
```

Run the development executable:

```zsh
swift run SpacesManager
```

The Swift package target lives in `Sources/SpacesManager`:

- `Models` contains Space and row data types.
- `Discovery` contains the SkyLight and WindowServer Space discovery implementations.
- `Organization` owns persisted row organization and thumbnail caching.
- `Overlay` contains the menu-bar and overlay controller.
- `Views` contains the SwiftUI organizer, row, and card views.
- `Support` contains shared SwiftUI interaction helpers.
