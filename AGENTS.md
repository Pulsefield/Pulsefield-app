---
commit: c4e4d1127c42d945cab919567b12bd1b6f015e1e
---

# AGENTS.md

Repository guidance for coding agents working in Pulsefield.

## Scope

These instructions apply to routine implementation, test writing, and documentation work in this repository.

## macOS App Builds and Privacy Permissions

When building or updating `PulsefieldMac`, keep the app identity and launch path stable so macOS privacy permissions such as Screen Recording do not point at stale builds.

- Keep `CFBundleIdentifier` stable for the same app channel.
- Keep the signing identity stable within a channel. Do not casually switch between unsigned, ad-hoc signed, Apple Development, and Developer ID builds for the same bundle ID.
- Install and launch the permission-tested build from one canonical path, preferably `/Applications/PulsefieldMac.app`.
- Do not launch permission-sensitive builds from random `DerivedData`, `.build`, `Downloads`, or old build output folders.
- Remove stale same-named app bundles before asking the user to grant Screen Recording or Screen and System Audio Recording access.
- If development and production builds need to coexist, use distinct names and bundle IDs, such as `PulsefieldMac Dev.app` with a `.dev` bundle ID.
- When replacing an installed build, quit the app, replace the existing app bundle at the canonical path, then launch that same path.

Sample canonical local update workflow for this repo:

```sh
cd <project_dir>
set -euo pipefail

APP_NAME=PulsefieldMac
SCHEME=PulsefieldMac
CONFIGURATION=Debug
DERIVED_DATA="$PWD/.build/PulsefieldMacInstallDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$DERIVED_DATA"

xcodebuild \
  -project Pulsefield.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

test -d "$BUILT_APP"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
open "$INSTALLED_APP"
```

Use `Debug` here because `project.yml` currently disables code signing for debug macOS builds. Use `Release` only after signing is configured, and keep the installed app path and bundle ID stable. The current macOS bundle ID is `io.pulsefield.mac`.

Before a permission-sensitive run after stale app copies were launched, clean known local build products first:

```sh
cd <project_dir>
pkill -x PulsefieldMac 2>/dev/null || true

for DIR in \
  "$PWD/.derivedData" \
  "$PWD/DerivedData" \
  "$HOME/Library/Developer/Xcode/DerivedData"
do
  if [ -d "$DIR" ]; then
    find "$DIR" \
      -name PulsefieldMac.app \
      -type d \
      -prune \
      -exec rm -rf {} +
  fi
done

rm -rf "$PWD/.build/PulsefieldMacInstallDerivedData"
```

If macOS privacy permissions still appear to reference an older build after an intentional bundle ID or signing change, reset the Screen Recording permission for the current bundle ID, rerun the canonical workflow, then grant permission again from the launched `/Applications/PulsefieldMac.app`:

```sh
tccutil reset ScreenCapture io.pulsefield.mac
```

## Tests

- Avoid overengineering tests.
- Write concrete and useful tests only.
- Prefer tests that validate user-visible behavior, feature-model transitions, domain mapping, or real regression boundaries.
- Do not add tests just to mirror implementation structure or inflate coverage.
- Do not introduce elaborate test harnesses, builders, mocks, or abstractions unless the current repo state clearly needs them.
- Keep tests easy to read, easy to change, and tightly scoped to real behavior.

## Docs

- When writing docs, always pin the current commit hash in the frontmatter.
- This applies to design explanations, future roadmap docs, and execution plan docs.
- The commit hash must describe the repo baseline the document is talking about.

### Doc Separation

- Clearly distinguish:
  - current repo status, architecture & design
  - future roadmap / proposed design
  - execution plan details
- Do not combine those categories in one file.

### Doc Count

- When documentation is needed, write only one doc by default.
- Give that doc a clear name and a single clear intention.
- Do not split documentation into multiple files unless the user explicitly asks for multiple docs.

### Naming

- Choose doc names that communicate intent directly.
