# TranscribeCppBinary

This local Swift package expects `TranscribeCpp.xcframework` next to `Package.swift`.
The framework is generated and intentionally ignored by git.

Run this before building from a fresh checkout or when you want to refresh to the
latest upstream release:

```sh
./transcribe-cpp-swift/scripts/update-xcframework.sh
```

To pin a specific upstream release:

```sh
./transcribe-cpp-swift/scripts/update-xcframework.sh v0.1.1
```

The script downloads `TranscribeCpp.xcframework.zip` from
`handy-computer/transcribe.cpp`, repairs the macOS framework symlink layout, and
ad-hoc signs the repaired framework so Xcode can embed and re-sign it.
