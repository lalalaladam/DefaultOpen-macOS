# AGENTS.md

## Development

- Read and understand the existing architecture before modifying code.
- Modify only files required for the task.
- Preserve existing functionality unless explicitly requested otherwise.
- Avoid unnecessary architectural refactoring.
- Keep new files and code additions to the minimum reasonably required.
- Prefer extending an existing file when the responsibility already belongs there.
- Maintain compatibility with the project's supported macOS version.
- Build and test locally after meaningful changes.

## Git

- Do not commit, push, tag, publish, or create releases without explicit user authorization.
- Do not discard or overwrite existing user changes.
- Before release-related work, verify the current Git state and HEAD.

## Build Metadata

Use the Git commit count as the numeric build number:

    CFBundleVersion = git rev-list --count HEAD

Do not manually assign or edit the build number.

Debug builds should retain enough metadata to identify the exact source state:

- Marketing version
- Build number
- Git commit hash
- Working-tree status (`clean` / `dirty`)
- Build timestamp

Release builds should present clean public version information and omit debug-only metadata.

## About Window

If a custom About window is implemented:

- Prefer a native custom `NSWindow` rather than the standard system About panel when custom content is required.
- Keep the controller strongly retained.
- Ensure closing and reopening the window works reliably.
- Avoid scrollable containers; all required content should be visible at once.
- Keep icon, application name, version information, and credits clearly aligned and readable.
- Do not hide or remove required attribution or license information.
- Verify the actual About window at runtime; a successful build alone is not sufficient.

## Verification

- Test only the build configuration relevant to the requested task unless broader verification is explicitly required.
- Do not claim a configuration or behavior was verified unless it was actually built and tested.