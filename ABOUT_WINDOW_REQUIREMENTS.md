# About Window Requirements

These requirements apply whenever the About window is created, modified, debugged, reviewed, or rebuilt.

## Required Content and Order

The About window must show, in this order:

1. Application icon
2. Application name
3. Standard version line:

       Version X.Y.Z (Build N)

4. Debug metadata, in Debug builds only:

       Version: vX.Y.Z
       Build: N
       Commit: <hash>
       Status: <clean/dirty>
       Build Time: <timestamp>

5. Credits / project information when applicable

Release builds may hide only Debug-only metadata.

## Window Implementation

- Use a custom native `NSWindow` managed by a strongly retained `AboutWindowController`.
- Do not use the standard system About panel.
- The About menu item must have an explicit target/action.
- Use a uniquely named action such as:

      @objc func showDefaultOpenCustomAbout(_ sender: Any?)

- Set `NSWindow.isReleasedWhenClosed = false`.
- Closing and reopening About must continue to work reliably.
- Give the window a valid non-zero initial content size.
- Avoid recursive or circular Auto Layout sizing during controller initialization.
- Activate the application before presenting the window.

## No-Scroll Requirement

The complete About hierarchy must be non-scrollable.

Do not use:

- `NSScrollView`
- SwiftUI `ScrollView`
- `List`
- `Form`
- `Table`
- `TextEditor`
- any other scroll-capable container

All required content must be visible simultaneously when the window opens.

Prefer native controls such as:

- `NSView`
- `NSImageView`
- `NSTextField`
- `NSStackView`
- `NSBox`

## Sizing and Alignment

- Use deterministic sizing appropriate for the static content.
- Do not clip, truncate, hide, or shrink required content to an unreadable size.
- Prevent resizing below the size required to display all content.
- Horizontally center:
  - application icon
  - application name
  - standard version line
  - every Debug metadata line
  - credits/project text

For AppKit text fields, set text alignment explicitly; centering the frame alone is not sufficient.

## Verification

- Codex must ensure About-related changes compile successfully and satisfy these requirements by code inspection.
- Manual visual and interaction verification is normally performed by the user.
- Do not launch and visually inspect the application unless explicitly requested.
- Treat user-reported About-window behavior as the authoritative runtime result.
- Do not claim runtime behavior was verified unless it was actually tested.
