# NeoTorrent

Native macOS torrent client. SwiftUI on top of a Rust core. Apple Silicon only.

Built as a replacement for WebTorrent Desktop — no Electron, no Node, native
everything.

## Features

- Add torrents via magnet URI, `.torrent` file, drag-and-drop, or paste
- Card-based torrent list with inline file picker and progress
- Duplicate magnet detection (no accidental re-adds)
- Pause / resume / remove (with optional file deletion)
- Per-file selection (skip files you don't want)
- Resumes torrents on app launch
- Session-wide bandwidth limits (live-updatable)
- Customizable download folder
- macOS default handler for `magnet:` links and `.torrent` files
- Completion notifications + action/chime sound effects (toggleable)

## Architecture

```
SwiftUI app  ──UniFFI──>  Rust core
                          ├── librqbit  (TCP/uTP/HTTP/UDP trackers, DHT,
                          │              piece picker, disk I/O, streaming
                          │              HTTP API)
                          └── neotorrent-core/{tracker,peer,wire,extension,
                              engine}  (WSS tracker + WebRTC peer transport
                              + BT wire protocol + ut_metadata — built from
                              scratch, currently parallel to librqbit)
```

- `crates/neotorrent-core` — engine, librqbit wrapper, custom WebRTC stack
- `crates/neotorrent-ffi` — UniFFI exports (`NeoTorrentSession`, `parseMagnet`, …)
- `apps/NeoTorrent` — SwiftUI app (XcodeGen-managed project)

The WebRTC modules (`peer.rs`, `tracker.rs`, `wire.rs`, `extension.rs`,
`engine.rs`) are end-to-end working against real WebTorrent peers but not yet
wired into the librqbit-backed download path. They're kept in tree for a future
hybrid client that also speaks WebRTC.

## Contributing

Build, layout, tests, and release workflow are documented in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Built on

- [librqbit](https://github.com/ikatson/rqbit) — pure-Rust BitTorrent client
- [webrtc-rs](https://github.com/webrtc-rs/webrtc) — pure-Rust WebRTC
- [UniFFI](https://github.com/mozilla/uniffi-rs) — Rust ↔ Swift bridge

## Inspiration

Heavily inspired by [WebTorrent Desktop](https://github.com/webtorrent/webtorrent-desktop)
— same drag-a-magnet-and-go UX, but rebuilt as a native macOS app. Goals that
drove the rewrite:

- Drop Electron/Node — ship a single Apple-Silicon binary instead of a 200 MB
  Chromium bundle
- Use the modern Rust BitTorrent stack (`librqbit`) for the wire protocol
- Keep WebTorrent-flavored WebRTC peer support on the roadmap (the
  `neotorrent-core` crates already speak it end-to-end against real WebTorrent
  peers)

## License

[MIT](LICENSE)

---

Made with ❤️ by [@lodev09](http://linkedin.com/in/lodev09/)
