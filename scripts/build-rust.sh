#!/usr/bin/env bash
set -euo pipefail

# Build the Rust FFI lib and regenerate Swift bindings for Xcode.
# Output lands in apps/NeoTorrent/NeoTorrent/Generated/ which Xcode pulls in.

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

CRATE="neotorrent-ffi"
LIB_NAME="neotorrent_ffi"
TARGET="aarch64-apple-darwin"
PROFILE="${PROFILE:-release}"
CARGO_PROFILE_DIR="$PROFILE"
[ "$PROFILE" = "dev" ] && CARGO_PROFILE_DIR="debug"

# Match the Xcode deployment target so the linker stops warning about objects
# built for a newer macOS than they're linked against. Keep in sync with
# apps/NeoTorrent/project.yml (MACOSX_DEPLOYMENT_TARGET).
export MACOSX_DEPLOYMENT_TARGET="15.0"

OUT_DIR="apps/NeoTorrent/NeoTorrent/Generated"
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

# Rewrite the `minos` field in LC_BUILD_VERSION inside the static archive's
# objects so the linker stops warning about "built for newer macOS version
# (26.0) than being linked (15.0)". Rustup ships prebuilt std
# (`compiler_builtins.*.o`) compiled against the current SDK; those objects
# are pure arithmetic intrinsics with no platform-versioned API use, so
# claiming a lower minos is safe. vtool refuses an in-place edit (object
# headers have no slack), so we patch the four bytes directly.
ARCHIVE="$OUT_DIR/lib${LIB_NAME}.a"
echo "==> patching LC_BUILD_VERSION minos in $(basename "$ARCHIVE")"
WORK="$(mktemp -d)"
(cd "$WORK" && ar x "$ROOT/$ARCHIVE")
python3 - "$WORK" <<'PY'
import os, struct, sys, glob

LC_BUILD_VERSION = 0x32
TARGET_MINOS = (15 << 16) | (0 << 8) | 0   # 15.0.0
MH_MAGIC_64 = 0xfeedfacf

def patch(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    if len(data) < 32:
        return False
    magic, = struct.unpack_from('<I', data, 0)
    if magic != MH_MAGIC_64:
        return False
    ncmds, = struct.unpack_from('<I', data, 16)
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            cur_minos, = struct.unpack_from('<I', data, off + 12)
            if cur_minos != TARGET_MINOS:
                struct.pack_into('<I', data, off + 12, TARGET_MINOS)
                with open(path, 'wb') as f:
                    f.write(data)
                return True
            return False
        off += cmdsize
    return False

work = sys.argv[1]
changed = 0
for obj in glob.glob(os.path.join(work, '*.o')):
    if patch(obj):
        changed += 1
print(f"    patched {changed} object(s)")
PY
(cd "$WORK" && ar rcs "rebuilt.a" *.o)
mv "$WORK/rebuilt.a" "$ARCHIVE"
rm -rf "$WORK"

# UniFFI emits <module>FFI.modulemap; rename to module.modulemap so Swift
# finds it via SWIFT_INCLUDE_PATHS without extra config.
MAP_SRC="$(ls "$OUT_DIR"/*.modulemap | head -n1 || true)"
if [ -n "$MAP_SRC" ] && [ "$(basename "$MAP_SRC")" != "module.modulemap" ]; then
    mv "$MAP_SRC" "$OUT_DIR/module.modulemap"
fi

# UniFFI's generated Swift declares two file-private globals that trip strict
# concurrency checks. Tag them `nonisolated(unsafe)` — UniFFI's runtime
# protects them internally, so the unchecked promise is correct.
GEN_SWIFT="$OUT_DIR/${LIB_NAME}.swift"
if [ -f "$GEN_SWIFT" ]; then
    sed -i.bak \
        -e 's/^fileprivate let uniffiContinuationHandleMap/fileprivate nonisolated(unsafe) let uniffiContinuationHandleMap/' \
        -e 's/^private var initializationResult: InitializationResult/private nonisolated(unsafe) var initializationResult: InitializationResult/' \
        "$GEN_SWIFT"
    rm -f "$GEN_SWIFT.bak"
fi

echo "==> done. generated in $OUT_DIR"
ls -1 "$OUT_DIR"
