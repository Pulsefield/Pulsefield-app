---
commit: d15db863e9d00e3fd09a550b3b060ceed1e4dd7b
title: SwiftUI Architecture Guidelines
---

# SwiftUI Architecture Guidelines

- baseline interpretation: the repo is still a skeleton app with one real feature seam, one root app model, no persistence, no navigation stack, and no cross-feature design system

These guidelines are intentionally scoped to the repository state above. They are not generic SwiftUI rules for every future Pulsefield phase.

## Current Read

At this commit, Pulsefield is small enough that more abstraction would cost more than it saves:

- separate platform app entry points in `Apps/PulsefieldiOS/PulsefieldiOSApp.swift` and `Apps/PulsefieldMac/PulsefieldMacApp.swift`
- one feature-oriented model in `Sources/PulsefieldCore/Features/Recognition/RecognitionAppModel.swift`
- one primary screen in `Sources/PulsefieldUI/Features/Recognition/RecognitionDashboardView.swift`
- protocol seams for microphone, recognition, and beatmap services
- unit tests around the app model behavior

That means the correct bias right now is:

- prefer directness over framework-building
- prefer feature files over horizontal layers
- prefer small protocol seams over a large dependency container
- prefer app-owned domain models over SDK-shaped models

## Guidelines

### 1. Keep Feature-First Structure

Organize new work by feature, not by view-model/service/util buckets across the whole repo.

Good near-term examples:

- `Features/Recognition/...`
- `Features/Beatmap/...`
- `Features/History/...`

Avoid creating top-level folders like these until the app is materially larger:

- `ViewModels/`
- `Managers/`
- `Helpers/`
- `Utilities/`

Reasoning: the current codebase is too small for cross-feature buckets to improve clarity.

### 2. Stay With Observation, Not a Heavier State Framework

Use `@Observable` models as the default state container for features.

Current repo direction that should remain the default:

- feature state and UI-facing derived values live together
- async side effects are kicked off from the feature model
- services stay behind small protocols
- views bind with `@Bindable`

Do not add TCA, Redux-style reducers, or a custom state framework yet.

Adopt a heavier architecture only when at least one of these becomes true:

- multiple child features need coordinated effect orchestration
- navigation becomes deep and state-driven across many screens
- feature composition becomes difficult to test with the current shape
- cancellation, long-lived effects, and parent-child state sharing become hard to reason about

Until then, the current model style is easier to read and cheaper to change.

### 3. Prefer Init Injection Before App-Wide DI

Pass dependencies into feature models explicitly through initializers.

Keep using patterns like:

- `RecognitionAppModel(permissionService:recognitionService:beatmapGenerator:)`

Do not introduce a global service locator or a large dependency graph container yet.

Use `EnvironmentValues` only for truly app-wide concerns such as:

- theme and design tokens
- analytics client
- persistence container
- navigation coordinator if one becomes shared

Reasoning: explicit construction is still cheap in this repo, and it keeps tests obvious.

### 4. Add Navigation Only When There Is Real Navigation

When the app grows past a single dashboard, use `NavigationStack` with typed routes.

Preferred pattern:

- define a small `Route` enum per feature or per navigation domain
- keep navigation state close to the owning feature model
- pass typed data, not string identifiers

Avoid:

- stringly-typed routing
- pushing navigation concerns into unrelated service layers
- creating a central router object before there are enough screens to justify it

Right now, Pulsefield does not need a navigation abstraction.

### 5. Delay Persistence Until History Is Real

Do not add storage just to make the skeleton look complete.

Add persistence when one of these becomes product-real:

- recognition history
- saved beatmap drafts
- cached provider configuration
- user settings beyond a couple of flags

When that moment arrives, the first choice should be SwiftData because the deployment floor is already iOS 17 and macOS 14.

Move to GRDB only if Pulsefield starts needing:

- complex queries
- explicit migrations
- direct SQLite control
- tighter performance tuning around large local datasets

### 6. Keep Networking Boring

When live provider work starts, default to:

- `URLSession`
- async/await
- thin client protocols
- response mapping into app-owned domain types

Do not add Moya, Alamofire, or a custom networking framework unless a concrete limitation appears.

This repo is more likely to benefit from better domain boundaries than from a richer HTTP abstraction.

### 7. Keep Views Thin, But Not Empty

SwiftUI views should remain mostly declarative, but they do not need to be stripped down into trivial wrappers.

Good view responsibilities:

- layout
- presentation logic
- bindings
- calling model intents
- small private subviews and styling helpers

Move logic out of the view when it becomes:

- asynchronous orchestration
- provider selection
- permission flow control
- reusable business rules

Do not split views into many micro-files unless the resulting components are truly reusable or materially easier to read.

### 8. Wait Before Extracting a Design System Target

The current styling in the dashboard is acceptable for a skeleton.

Do not create a separate `DesignSystem` module until:

- at least two real features exist
- visual tokens are reused across screens
- component duplication starts to appear

When that threshold is reached, extract only the stable pieces first:

- colors
- spacing
- typography
- card/chip/button treatments

Avoid creating a large component catalog before the product language is settled.

### 9. Keep Tests Focused on Behavior

The current test direction is correct: test feature-model behavior at the protocol seam.

Add more tests in this order:

1. feature model transitions
2. service mapping logic
3. persistence integration once storage exists
4. UI tests only for important end-to-end flows

Prefer Swift Testing for new pure-Swift tests when it fits naturally, while keeping XCTest where platform integration is simpler.

## Decision Rules

Before adding a new abstraction, ask:

1. Does this remove repeated code that already exists in at least two real places?
2. Does this make a current feature easier to test or change right now?
3. Would a new contributor understand the code faster after this abstraction exists?

If the answer is mostly no, do not add the abstraction yet.

## Near-Term Repo Plan

For the next phase of Pulsefield, the recommended path is:

1. Keep the existing app shell and recognition feature structure.
2. Add the next real feature without introducing a global architecture framework.
3. Introduce typed navigation only when a second screen exists.
4. Introduce persistence only when history or saved work becomes product-real.
5. Extract shared design primitives only after duplication appears across multiple screens.

That keeps the repo aligned with modern SwiftUI patterns without pretending the current skeleton is already a large application.
