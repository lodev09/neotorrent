# Lorrent

Native macOS torrent client. SwiftUI on top of a Rust core. Apple Silicon only.

Built as a replacement for WebTorrent Desktop — no Electron, no Node, native
everything.

## Features

- Add torrents via magnet URI, `.torrent` file, drag-and-drop, or paste
- Pause / resume / remove (with optional file deletion)
- Per-file selection (skip files you don't want)
- Built-in streaming player — watch video while it downloads (AVPlayer + local
  HTTP range server)
- Resumes torrents on app launch
- Session-wide bandwidth limits (live-updatable)
- Customizable download folder
- macOS default handler for `magnet:` links and `.torrent` files
- Completion notifications + chime
- Auto-play newly-added media torrents

## Architecture

```
SwiftUI app  ──UniFFI──>  Rust core
                          ├── librqbit  (TCP/uTP/HTTP/UDP trackers, DHT,
                          │              piece picker, disk I/O, streaming
                          │              HTTP API)
                          └── lorrent-core/{tracker,peer,wire,extension,
                              engine}  (WSS tracker + WebRTC peer transport
                              + BT wire protocol + ut_metadata — built from
                              scratch, currently parallel to librqbit)
```

- `crates/lorrent-core` — engine, librqbit wrapper, custom WebRTC stack
- `crates/lorrent-ffi` — UniFFI exports (`LorrentSession`, `parseMagnet`, …)
- `apps/Lorrent` — SwiftUI app (XcodeGen-managed project)

The WebRTC modules (`peer.rs`, `tracker.rs`, `wire.rs`, `extension.rs`,
`engine.rs`) are end-to-end working against real WebTorrent peers but not yet
wired into the librqbit-backed download path. They're kept in tree for a future
hybrid client that also speaks WebRTC.

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

Or open `apps/Lorrent/Lorrent.xcodeproj` in Xcode and ⌘R. The scheme's
pre-build action calls `scripts/build-rust.sh` automatically.

## Project layout

```
lorrent/
├── Cargo.toml                  # workspace
├── justfile                    # task runner (see `just --list`)
├── scripts/build-rust.sh       # cargo build + uniffi-bindgen → Generated/
├── crates/
│   ├── lorrent-core/           # torrent engine
│   └── lorrent-ffi/            # UniFFI bindings + bindgen bin
└── apps/Lorrent/
    ├── project.yml             # XcodeGen spec (Info.plist + entitlements)
    └── Lorrent/                # SwiftUI sources
```

## Tests

```sh
just test       # unit tests
just test-net   # network smoke tests (Sintel fetch over WebRTC)
```

## Built on

- [librqbit](https://github.com/ikatson/rqbit) — pure-Rust BitTorrent client
- [webrtc-rs](https://github.com/webrtc-rs/webrtc) — pure-Rust WebRTC
- [UniFFI](https://github.com/mozilla/uniffi-rs) — Rust ↔ Swift bridge
