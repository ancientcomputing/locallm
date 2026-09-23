# Components Updates Demo

The three model-lifecycle views from `LocalLMLabSDKComponents`, driven by **simulated** sources so you can
reach every state of every view on demand:

- **`ModelOnboardingView`** — a *Validate → Download → Pin* stepper for adding a model.
- **`ModelUpdateView`** — check for a newer version, see what would change, update, and roll back.
- **`ModelVersionsView`** — the versions on disk, what removing each would actually free, and a guarded Remove.

Nothing here touches the network or MLX. Short sleeps stand in for the work, and the "models" are just labels,
so the app starts instantly and there is nothing to download. That is the point: these views are
**provider-agnostic**. They own presentation and state, and take plain value types (`PreflightResult`,
`InstalledModel`, `ModelUpdateOffer`, `ModelVersionRow`) and closures that *you* supply. This example fills
those closures with fakes. A real host fills them from `MLXModelProvider` — `validate`, `download`,
`checkPinUpdate`, `updatePin(_:to:beforeSwitch:)`, `snapshots(for:)`, `removeSnapshot(_:revision:)`.

**If your app downloads models and you want a ready-made onboarding, update and cleanup UI, start here** to
see what each view needs from you. To see the same flows against a real `MLXModelProvider` — real downloads,
real pins, real updates — run [`mlx-control-room`](../mlx-control-room/). The ~40-line adapter from
`MLXModelProvider` to these views is in [`Components/README.md`](../../Components/README.md#adapting-mlxmodelprovider),
and [`docs/annotated-examples.md`](../../docs/annotated-examples.md#examplescomponents-updates-demo) walks this
example's source with every SDK touchpoint marked.

Requires macOS 27+ on Apple Silicon (Xcode 27 to build). No permissions, no signing, no account.

## Getting the SDK

This branch tracks `1.0.0-RC.1`. Nothing to download by hand — `Package.swift` depends on the sibling
[`Components`](../../Components/) package, which resolves `LocalLMLabSDKCore` as a binary dependency and builds
against `1.0.0-RC.1` by default. Set `LOCALLM_SDK_VERSION` in a shell (not Xcode) to pin another published
release — see [`../README.md`](../README.md#building--running-an-sdk-example).

## Build and run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run UpdatesDemo
```

Skip `DEVELOPER_DIR` if `xcode-select -p` already points at Xcode 27 (adjust the path if yours lives elsewhere).
There is no `.xcodeproj` and no `packaging/`; to run it from Xcode, open `Package.swift` and Run the
**UpdatesDemo** scheme. Started with `swift run`, the window is not part of an app bundle, so if it doesn't
come to the front, click it.

## What to try

The window has five sections, top to bottom.

1. **Onboarding a model.** Press *Add* to run Validate → Download → Pin for a model. Three switches make each
   step go wrong, so you can see how the view reports it:
   - *preflight denies the repo (trust policy)* — the flow stops at Validate and names the stage
     (`failed at .trustPolicy — …`); nothing after it runs.
   - *download resolves a different commit than the app ships* — the Pin step refuses, because the resolved
     commit isn't the one the request expected (`ModelOnboardingRequest.expectedRevision`).
   - *download fails part-way* — the download shows progress, then fails at the verify stage.
2. **A model you chose.** You decide when to update. *Check for update* shows what would change (here a
   single file's size), *Update* downloads and switches, and the view then offers *Roll back*.
3. **A built-in model.** The developer offers the update, and can move the model back to the version the app
   shipped. The line above it shows the host's **pause point**: after the new version is downloaded and before
   the switch, the SDK calls your `beforeSwitch`, so you can stop new requests and wait for the running one. The
   view shows a *switching* state while that happens.
4. **Something that can't be updated here.** A model the app ships fixed shows the reason instead of a button.
5. **Cleaning up old versions.** Each version on disk, which one is current, and two numbers per row: what
   removing it would free and what it shares with other versions. Removing a version frees only the files no
   other version uses; the current version can't be removed.

## What the code shows

The whole app is one file, [`UpdatesDemoApp.swift`](Sources/UpdatesDemo/UpdatesDemoApp.swift). The seams to
notice:

| You supply | It stands in for | Where the view uses it |
|---|---|---|
| `ModelOnboardingSource(validate:download:)` | `MLXModelProvider.validate` / `.download` | the stepper's Validate and Download steps |
| `ModelUpdateActions(check:apply:)` | `checkPinUpdate` / `updatePin(_:to:beforeSwitch:)` | *Check for update*, *Update*, *Roll back* |
| `ModelUpdateModel.pauseInference` | your own "quiesce inference" logic | awaited after the download, before the switch |
| `ModelVersionsModel(list:remove:)` | `snapshots(for:)` / `removeSnapshot(_:revision:)` | the versions list and its guarded Remove |

`apply` has exactly the shape of `updatePin(_:to:beforeSwitch:)`: download and verify, call `beforeSwitch`
**once, before anything changes**, then switch, and a throw must leave the model on the version it was on.
`ModelUpdateOwnership` (`.userChosen`, `.developerOffered`, `.fixed(reason:)`) decides what each view offers.
