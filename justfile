# Lorrent task runner.
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
    cd apps/Lorrent && xcodegen generate

# Full macOS .app build (Rust → bindings → xcodegen → xcodebuild).
app: bindings xcode
    xcodebuild \
        -project apps/Lorrent/Lorrent.xcodeproj \
        -scheme Lorrent \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        build

# Build + launch.
run: app
    open ~/Library/Developer/Xcode/DerivedData/Lorrent-*/Build/Products/Debug/Lorrent.app

# Release build of the .app.
release:
    PROFILE=release ./scripts/build-rust.sh
    cd apps/Lorrent && xcodegen generate
    xcodebuild \
        -project apps/Lorrent/Lorrent.xcodeproj \
        -scheme Lorrent \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        build

# ── Quality ──────────────────────────────────────────────────────────────

# Run unit tests.
test:
    cargo test

# Run network integration tests (`#[ignore]`d by default).
test-net:
    cargo test --release -- --ignored --nocapture

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
    rm -rf apps/Lorrent/Lorrent/Generated
    rm -rf apps/Lorrent/Lorrent.xcodeproj
    rm -rf apps/Lorrent/Lorrent/Info.plist
    rm -rf apps/Lorrent/build
