# NeoTorrent task runner.
# Install just: `brew install just`. List recipes: `just`.

set shell := ["bash", "-cu"]

# Show available recipes.
default:
    @just --list --unsorted

# ── Build ────────────────────────────────────────────────────────────────

# Build the Rust core + regenerate UniFFI Swift bindings.
bindings:
    ./scripts/build-rust.sh

# Regenerate the Xcode project from project.yml.
xcode:
    cd apps/NeoTorrent && xcodegen generate

# Debug .app build (xcodegen → xcodebuild; the target's Run Script phase builds Rust).
app: xcode _build-debug

# Rebuild + relaunch the Debug .app (skips xcodegen; run `just xcode` after editing project.yml).
run: _quit _build-debug
    open build/debug/Build/Products/Debug/NeoTorrent.app

# Release build of the .app.
release: xcode
    xcodebuild \
        -project apps/NeoTorrent/NeoTorrent.xcodeproj \
        -scheme NeoTorrent \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath build/release \
        build

# Package the release .app into a DMG (ad-hoc signed; for local layout testing).
dmg: release
    APP_PATH="$PWD/build/release/Build/Products/Release/NeoTorrent.app" ./scripts/package-dmg.sh

_build-debug:
    xcodebuild \
        -project apps/NeoTorrent/NeoTorrent.xcodeproj \
        -scheme NeoTorrent \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath build/debug \
        build

_quit:
    osascript -e 'tell application "NeoTorrent" to quit' >/dev/null 2>&1 || true

# Tag + push a release (prompts for version; defaults to bumping the patch).
ship version="":
    ./scripts/release.sh {{version}}

# ── Quality ──────────────────────────────────────────────────────────────

# Run unit tests.
test:
    cargo test

# Run network integration tests (`#[ignore]`d by default).
test-net:
    cargo test --release -p neotorrent-core --features webrtc -- --ignored --nocapture

# Format Rust sources.
fmt:
    cargo fmt

# Check formatting without writing.
fmt-check:
    cargo fmt --check

# Lint with clippy, treating warnings as errors.
lint:
    cargo clippy --all-targets -- -D warnings

# Preflight: fmt-check + lint + tests. Run before pushing.
check: fmt-check lint test

# ── Housekeeping ─────────────────────────────────────────────────────────

# Wipe build artifacts (cargo target, generated bindings, Xcode project, plist).
clean:
    cargo clean
    rm -rf apps/NeoTorrent/NeoTorrent/Generated
    rm -rf apps/NeoTorrent/NeoTorrent.xcodeproj
    rm -rf apps/NeoTorrent/NeoTorrent/Info.plist
    rm -rf apps/NeoTorrent/build
    rm -rf build dist
