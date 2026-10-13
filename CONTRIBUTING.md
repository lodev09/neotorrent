# Contributing

## Build

Prerequisites:

- macOS 15+ (Apple Silicon)
- Xcode (for `xcodebuild`; also provides `python3`, used by `scripts/build-rust.sh`)
- Rust — [rustup](https://rustup.rs) recommended: it picks up the toolchain
  pinned in `rust-toolchain.toml`. Other installs work if they match that
  version; the build script discovers cargo from PATH, `$HOME/.cargo/bin`,
  `/opt/homebrew/bin`, or `/usr/local/bin` (or set `CARGO_BIN_DIR`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [`just`](https://github.com/casey/just) (`brew install just`)
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`;
  only for `just dmg`)

Common tasks:

```sh
just              # list recipes
just app          # generate the Xcode project + build the Debug .app
just run          # rebuild + launch the Debug .app
just test         # cargo test
just check        # fmt + clippy + tests (preflight)
just clean        # wipe build artifacts
```

`apps/NeoTorrent/NeoTorrent.xcodeproj` is generated and not checked in: run
`just xcode` (again after editing `project.yml`), then open it in Xcode and ⌘R.

Build pipeline: the app target's first build phase ("Build Rust core") runs
`scripts/build-rust.sh`, so Xcode, `just app`, and CI all build Rust the same
way and a Rust failure fails the build. The script:

1. `cargo build --locked` the `neotorrent-ffi` static lib — Debug uses the
   `dev-release` cargo profile (optimized, no LTO, incremental), Release uses
   `release` (fat LTO)
2. runs `uniffi-bindgen` (its own small crate, built once in release) in
   library mode to generate the Swift bindings
3. copies the lib + bindings into `apps/NeoTorrent/NeoTorrent/Generated/`

`Cargo.lock` is committed and all builds use `--locked`; after changing
dependencies, run a plain `cargo build` (or `cargo update -p <crate>`) and
commit the lockfile.

## Project layout

```
neotorrent/
├── Cargo.toml                  # workspace
├── rust-toolchain.toml         # pinned Rust toolchain
├── justfile                    # task runner (see `just --list`)
├── scripts/build-rust.sh       # cargo build + uniffi-bindgen → Generated/
├── crates/
│   ├── neotorrent-core/        # torrent engine
│   ├── neotorrent-ffi/         # UniFFI bindings
│   └── uniffi-bindgen/         # bindgen CLI used by build-rust.sh
└── apps/NeoTorrent/
    ├── project.yml             # XcodeGen spec (Info.plist + entitlements)
    └── NeoTorrent/             # SwiftUI sources
```

## Tests

```sh
just test       # unit tests
just test-net   # live-network smoke tests (`--features webrtc`): WSS tracker
                # announce + Sintel metadata fetch from WebRTC peers
```

Run `just check` (fmt + clippy + tests) before pushing. CI runs the same checks
(plus the `webrtc` feature) and an unsigned Debug app build on every PR.

## Release

`apps/NeoTorrent/project.yml` is the single source of truth for both the
marketing version (`CFBundleShortVersionString`) and the build number
(`CFBundleVersion`). Build number is a plain integer counter, kept independent
of the marketing version so re-shipping the same marketing version (e.g. App
Store hotfix) still satisfies Apple's strict-monotonic build rule. The Rust
workspace version (`Cargo.toml`) is bumped alongside the marketing version.

`just ship` bumps the marketing version (in `project.yml` and `Cargo.toml`) to
the chosen value, increments the build counter by one, commits (with
`Cargo.lock`), tags, and pushes `main` + the tag atomically — which kicks off
the [release workflow](.github/workflows/release.yml) (build → sign → notarize
→ DMG + SHA-256 checksum → GitHub release).

```sh
just ship           # prompts; default = patch bump from latest tag
just ship 0.2.0     # explicit version
```

Requirements: clean working tree on `main`, in sync with `origin/main`, and the
secrets `APPLE_*` configured on the repo for signing /
notarization. To do a manual dry-run build without publishing, trigger the
workflow from the Actions tab with `publish: false`. Manual runs with
`publish: true` must be started on a tag; existing release assets are never
overwritten.

Locally, `scripts/notarize.sh` can use a stored `notarytool` profile via
`NOTARY_KEYCHAIN_PROFILE` instead of the `APPLE_*` variables.
