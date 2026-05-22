# Contributing

## Build

Prerequisites:

- macOS 15+ (Apple Silicon)
- Xcode (for `xcodebuild`)
- Rust (any install method — script discovers cargo from PATH,
  `$HOME/.cargo/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`; or set
  `CARGO_BIN_DIR`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [`just`](https://github.com/casey/just) (`brew install just`)

Common tasks:

```sh
just              # list recipes
just app          # build the .app
just run          # build + launch
just test         # cargo test
just check        # fmt + clippy + tests (preflight)
just clean        # wipe build artifacts
```

Or open `apps/NeoTorrent/NeoTorrent.xcodeproj` in Xcode and ⌘R. The scheme's
pre-build action calls `scripts/build-rust.sh` automatically.

## Project layout

```
neotorrent/
├── Cargo.toml                  # workspace
├── justfile                    # task runner (see `just --list`)
├── scripts/build-rust.sh       # cargo build + uniffi-bindgen → Generated/
├── crates/
│   ├── neotorrent-core/        # torrent engine
│   └── neotorrent-ffi/         # UniFFI bindings + bindgen bin
└── apps/NeoTorrent/
    ├── project.yml             # XcodeGen spec (Info.plist + entitlements)
    └── NeoTorrent/             # SwiftUI sources
```

## Tests

```sh
just test       # unit tests
just test-net   # network smoke tests (Sintel fetch over WebRTC)
```

Run `just check` (fmt + clippy + tests) before pushing.

## Release

`apps/NeoTorrent/project.yml` is the single source of truth for both the
marketing version (`CFBundleShortVersionString`) and the build number
(`CFBundleVersion`). Build number is a plain integer counter, kept independent
of the marketing version so re-shipping the same marketing version (e.g. App
Store hotfix) still satisfies Apple's strict-monotonic build rule.

`just ship` bumps the marketing version to the chosen value, increments the
build counter by one, commits, tags, and pushes — which kicks off the
[release workflow](.github/workflows/release.yml) (build → sign → notarize →
DMG → GitHub release).

```sh
just ship           # prompts; default = patch bump from latest tag
just ship 0.2.0     # explicit version
```

Requirements: clean working tree on `main`, in sync with `origin/main`, and the
secrets `APPLE_*` + `KEYCHAIN_PASSWORD` configured on the repo for signing /
notarization. To do a manual dry-run build without publishing, trigger the
workflow from the Actions tab with `publish: false`.
