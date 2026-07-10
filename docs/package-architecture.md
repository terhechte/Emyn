# Package architecture

The Xcode project contains the SwiftUI app and the Core Media IO extension. Reusable implementation lives in local Swift packages under `Packages/`, and every package has its own manifest so it can be added to another project independently.

## Dependency direction

```text
Emyn app
├── VideoCompositionKit
│   ├── BackgroundRemovalKit
│   ├── SharedFrameKit
│   ├── WindowCaptureKit
│   │   └── PlatformMacOSKit
│   └── PlatformMacOSKit
├── TranscriptionKit
│   └── CTranscribe binary package
├── WindowCaptureKit
├── BackgroundRemovalKit
└── SharedFrameKit

EmynVirtualCameraExtension
└── SharedFrameKit
```

`VideoCompositionKit` intentionally does not depend on `TranscriptionKit`. It accepts a generic `CaptionRenderConfiguration`; the app target owns the small adapter from speech caption settings to composition caption settings. This keeps transcription and video composition reusable in isolation.

## Package responsibilities

- `WindowCaptureKit` owns ScreenCaptureKit window discovery and capture, window-control sessions, event forwarding, fit/alignment types, and `WindowPointerMapper`. The mapper is the single source of truth for converting the visible crop in the composed output back to the target window rectangle.
- `TranscriptionKit` owns audio capture, resampling, model discovery/downloads, streaming and non-streaming transcription, and transcription-specific caption preferences.
- `BackgroundRemovalKit` owns Vision segmentation, analysis sizing, temporal mask smoothing, pixel-buffer pools, and materialized render masks through `PersonBackgroundRemover`.
- `VideoCompositionKit` owns camera capture, background/media composition, window integration, filters, overlays, captions, presentation effects, and publication to `SharedFrameKit`.
- `SharedFrameKit` owns `OutputFrameSize` and the memory-mapped reader/writer contract used across process boundaries.

## Reusing a package

Add the package directory as a local package in Xcode, or reference it from another manifest:

```swift
dependencies: [
    .package(path: "../Emyn/Packages/WindowCaptureKit")
]
```

Then depend on its library product:

```swift
.target(
    name: "MyAppCore",
    dependencies: ["WindowCaptureKit"]
)
```

The package manifests use relative paths for the existing binary/platform wrappers. If a package is moved to a different repository, either keep those relative dependencies alongside it or change the manifest to the corresponding remote package URLs.
