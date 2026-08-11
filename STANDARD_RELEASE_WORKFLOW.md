# Standard Release Workflow

Follow this workflow for every stable DefaultOpen release. Replace `X.Y.Z`
with the intended marketing version, for example `1.0.0`.

## Release Constraints

- Official artifacts must use the Release configuration.
- The release source must be a clean, committed Git state.
- `CFBundleVersion` is always the Git commit count; never edit it manually.
- This project does not have an Apple Developer Program membership.
- Release artifacts use ad-hoc signing. Do not attempt Developer ID signing,
  Apple notarization, or stapling.
- An ad-hoc signature is not an Apple identity signature and does not prevent
  Gatekeeper from warning users about an application downloaded from the Internet.
- Committing, pushing, tagging, and creating a GitHub Release each require
  explicit user authorization. A request to build does not authorize publishing.

## 1. Prepare the Release Source

1. Finish and verify all intended source and documentation changes.
2. Set `MARKETING_VERSION` to `X.Y.Z` in the Xcode project. Do not edit
   `CURRENT_PROJECT_VERSION` or `CFBundleVersion` to assign a build number.
3. Review the exact changes:

   ```bash
   git status --short
   git diff --check
   git diff
   ```

4. With explicit user authorization, stage only the intended files and create
   an English Conventional Commit, for example:

   ```bash
   git add <explicit-file-list>
   git commit -m "chore: prepare vX.Y.Z release"
   ```

5. Confirm that the release source is clean and record its identity:

   ```bash
   git status --short
   git rev-parse HEAD
   git rev-parse --short HEAD
   git rev-list --count HEAD
   ```

   Stop if the working tree is not clean. The numeric result of
   `git rev-list --count HEAD` is the release build number.

## 2. Create the Release Archive

Use a fresh archive path below `Build/`, which is ignored by Git. Never
overwrite an earlier archive or release directory.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild clean archive \
  -project FileAssociationManager.xcodeproj \
  -scheme FileAssociationManager \
  -configuration Release \
  -archivePath "Build/Archives/DefaultOpen-vX.Y.Z.xcarchive" \
  CURRENT_PROJECT_VERSION=<GitCommitCount> \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
```

If the installed application is named differently (for example
`Xcode-beta.app`), set `DEVELOPER_DIR` only for the command; do not change the
user's global developer-directory setting.

Copy the application from the archive without modifying the archive:

```bash
mkdir "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>"
ditto \
  "Build/Archives/DefaultOpen-vX.Y.Z.xcarchive/Products/Applications/DefaultOpen.app" \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/DefaultOpen.app"
```

If archive creation or extraction fails, stop. Do not substitute a Debug app
or silently reuse an older build product.

## 3. Ad-Hoc Sign and Verify

Apply an explicit ad-hoc signature to the extracted app:

```bash
codesign --force --sign - --timestamp=none \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/DefaultOpen.app"
```

Verify the bundle and executable:

```bash
codesign --verify --deep --strict --verbose=2 \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/DefaultOpen.app"

plutil -p \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/DefaultOpen.app/Contents/Info.plist"

lipo -archs \
  "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>/DefaultOpen.app/Contents/MacOS/DefaultOpen"
```

Verification must confirm:

- `CFBundleShortVersionString` is `X.Y.Z`.
- `CFBundleVersion` is the recorded Git commit count.
- `CFBundleIdentifier` is `com.lalalaladam.DefaultOpen`.
- The executable contains `arm64` only.
- The bundle has a valid ad-hoc signature and no Developer ID identity.
- Release metadata does not contain `DefaultOpenDebugMetadata`.
- The About window code will display `Version X.Y.Z (Build N)` and omit only
  Debug-specific metadata.

`spctl --assess` may reject an ad-hoc-signed, unnotarized app. That is expected
for this project and must not be represented as successful notarization.

## 4. Package and Checksum

Run these commands from the release output directory so the checksum records
only the artifact filename:

```bash
cd "Build/Release-vX.Y.Z-<BuildNumber>-<GitHash>"
ditto -c -k --keepParent "DefaultOpen.app" "DefaultOpen-vX.Y.Z-arm64.zip"
shasum -a 256 "DefaultOpen-vX.Y.Z-arm64.zip" > "DefaultOpen-vX.Y.Z-arm64.sha256"
shasum -a 256 -c "DefaultOpen-vX.Y.Z-arm64.sha256"
```

The only public release artifacts are:

- `DefaultOpen-vX.Y.Z-arm64.zip`
- `DefaultOpen-vX.Y.Z-arm64.sha256`

Do not upload the raw `.app`, `.xcarchive`, Derived Data, or Debug products.

## 5. Tag, Push, and Publish

Perform this section only with explicit user authorization.

1. Confirm the repository is still clean and HEAD is the commit used above:

   ```bash
   git status --short
   git rev-parse HEAD
   ```

2. Create an annotated version tag:

   ```bash
   git tag -a vX.Y.Z -m "DefaultOpen vX.Y.Z"
   ```

3. Push the release commit and tag without force:

   ```bash
   git push origin main
   git push origin vX.Y.Z
   ```

4. Create a GitHub Release for `vX.Y.Z` and upload only the ZIP and SHA-256
   files.

If any source file changes after the archive is built, do not reuse the
artifacts. Commit the correction with authorization, then repeat the workflow
from the clean-source verification step.

## 6. Final Verification

Before declaring the release complete, confirm:

- The working tree is clean.
- The release commit equals the commit used for the archive.
- The local and remote `vX.Y.Z` tags reference that commit.
- `origin/main` contains that commit.
- The GitHub Release uses the correct tag.
- The GitHub Release contains only the intended ZIP and checksum artifacts.
- The published checksum matches the published ZIP.

Stop on any failed step, report the exact error, and wait for direction. Never
force-push, rewrite history, delete or overwrite tags/releases, or bypass a
failed verification without explicit user instruction.
