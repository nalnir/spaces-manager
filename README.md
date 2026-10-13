# Spaces Manager

A native macOS menu bar app for viewing, organizing, and navigating Mission Control Spaces.

Spaces Manager presents an overlay of the Spaces on your displays, including desktops, full-screen apps, and Split View pairs. Organize them into custom rows, reorder them with drag and drop or the keyboard, and switch to a Space directly from the overlay.

## Requirements

- macOS 14 Sonoma or later
- Xcode Command Line Tools or Xcode with Swift 5.10+
- Screen Recording permission for window thumbnails
- Accessibility permission for switching Spaces and moving full-screen apps back to a desktop

## Install

1. Clone the repository and open it in Terminal.

   ```zsh
   git clone https://github.com/nalnir/spaces-manager.git
   cd SpacesManager
   ```

2. Build, install, and launch the app.

   ```zsh
   ./Scripts/run-app.sh
   ```

   The script automatically uses an Apple Development identity when one is available, otherwise it uses ad-hoc signing. It installs the app at `~/Applications/Spaces Manager.app` and registers it to start automatically whenever you sign in. Launch an already installed copy with:

   ```zsh
   ./Scripts/spaces-manager
   ```

3. When prompted, allow Screen Recording and Accessibility in **System Settings > Privacy & Security**. You can also open the Spaces Manager menu bar icon to review or request permissions.

To force a particular signing identity, set `SPACES_MANAGER_SIGNING_IDENTITY` for the installation command:

```zsh
SPACES_MANAGER_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/run-app.sh
```

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
- This project is intended for local use and is not sandboxed or notarized for distribution.

## Development

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
