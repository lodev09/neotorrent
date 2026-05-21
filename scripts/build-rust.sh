#!/usr/bin/env bash
set -euo pipefail

# Build the Rust FFI lib and regenerate Swift bindings for Xcode.
# Output lands in apps/Lorrent/Lorrent/Generated/ which Xcode pulls in.

# Xcode's GUI launch gives this script a minimal PATH that excludes the user's
# shell PATH, so cargo (and friends) may not be visible. Allow an explicit
# override via CARGO_BIN_DIR, then probe the standard install locations.
if [ -n "${CARGO_BIN_DIR:-}" ] && [ -x "$CARGO_BIN_DIR/cargo" ]; then
    export PATH="$CARGO_BIN_DIR:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
    for candidate in "$HOME/.cargo/bin" /opt/homebrew/bin /usr/local/bin; do
        if [ -x "$candidate/cargo" ]; then
            export PATH="$candidate:$PATH"
            break
        fi
    done
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found." >&2
    echo "       Install Rust (https://rustup.rs), or set CARGO_BIN_DIR to the" >&2
    echo "       directory containing the cargo binary." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CRATE="lorrent-ffi"
LIB_NAME="lorrent_ffi"
TARGET="aarch64-apple-darwin"
PROFILE="${PROFILE:-release}"
CARGO_PROFILE_DIR="$PROFILE"
[ "$PROFILE" = "dev" ] && CARGO_PROFILE_DIR="debug"

OUT_DIR="apps/Lorrent/Lorrent/Generated"
mkdir -p "$OUT_DIR"

echo "==> cargo build ($PROFILE, $TARGET)"
cargo build --profile "$PROFILE" --target "$TARGET" -p "$CRATE"

DYLIB="target/$TARGET/$CARGO_PROFILE_DIR/lib${LIB_NAME}.dylib"
STATICLIB="target/$TARGET/$CARGO_PROFILE_DIR/lib${LIB_NAME}.a"

echo "==> uniffi-bindgen (Swift)"
cargo run --features cli -p "$CRATE" --bin uniffi-bindgen -- \
    generate \
    --library "$DYLIB" \
    --language swift \
    --out-dir "$OUT_DIR"

echo "==> copying static lib"
cp "$STATICLIB" "$OUT_DIR/lib${LIB_NAME}.a"

# UniFFI emits <module>FFI.modulemap; rename to module.modulemap so Swift
# finds it via SWIFT_INCLUDE_PATHS without extra config.
MAP_SRC="$(ls "$OUT_DIR"/*.modulemap | head -n1 || true)"
if [ -n "$MAP_SRC" ] && [ "$(basename "$MAP_SRC")" != "module.modulemap" ]; then
    mv "$MAP_SRC" "$OUT_DIR/module.modulemap"
fi

echo "==> done. generated in $OUT_DIR"
ls -1 "$OUT_DIR"
