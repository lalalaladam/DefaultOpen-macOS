# AGENTS.md

## Development

- Read and understand the existing architecture before modifying code.
- Modify only files required for the task.
- Preserve existing functionality unless explicitly requested otherwise.
- Avoid unnecessary architectural refactoring and unnecessary new files.
- Maintain compatibility with the project's supported macOS version.
- After meaningful changes, ensure the project builds successfully.

## Git

- Do not commit, push, tag, publish, or create releases without explicit user authorization.
- Do not discard or overwrite existing user changes.
- Generated build products must remain excluded from Git.

## Build Metadata

Use the Git commit count as the numeric build number:

    CFBundleVersion = git rev-list --count HEAD

Do not manually assign or edit `CFBundleVersion`.

Debug builds must include:

- Marketing version
- Build number
- Short Git commit hash
- Working-tree status (`clean` / `dirty`)
- Build timestamp (`yyyyMMdd.HHmmss`)

## Debug Build Output

Every successful local Debug build must also archive the runnable `.app` into:

    Build/Debug-<BuildNumber>-<GitHash>-<Timestamp>/

Example:

    Build/Debug-31-213a61a-20260726.002044/

Rules:

- `BuildNumber` = `git rev-list --count HEAD`
- `GitHash` = short Git HEAD hash
- Never overwrite an earlier archived Debug build.
- The archive must contain the runnable `.app` built from that exact source state.
- `Build/` must remain ignored by Git.

## About Window

Before creating or modifying the About window, read and follow:

    ABOUT_WINDOW_REQUIREMENTS.md

## Verification

- Codex should perform build-time and code-level verification.
- Manual UI and visual verification is normally performed by the user.
- Do not spend time launching and visually inspecting the app unless explicitly requested.
- Treat user-reported UI/runtime behavior as the authoritative verification result.
- Never claim runtime behavior was verified unless it was actually tested.
