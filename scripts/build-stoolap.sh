#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOOLAP_DIR="$ROOT_DIR/vendor/stoolap"
STOOLAP_COMMIT="7e6634ba8447f33ae99aefb99693459cd691394a"
PATCH_FILE="$ROOT_DIR/patches/stoolap-0.4.0-liquidstoolap.patch"

if [[ ! -d "$STOOLAP_DIR/.git" ]]; then
  mkdir -p "$ROOT_DIR/vendor"
  git clone --filter=blob:none --no-checkout https://github.com/stoolap/stoolap.git "$STOOLAP_DIR"
  git -C "$STOOLAP_DIR" fetch --depth 1 origin "$STOOLAP_COMMIT"
  git -C "$STOOLAP_DIR" checkout --detach "$STOOLAP_COMMIT"
fi

actual_commit="$(git -C "$STOOLAP_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$STOOLAP_COMMIT" ]]; then
  echo "Stoolap checkout is at $actual_commit; expected $STOOLAP_COMMIT" >&2
  exit 1
fi

if git -C "$STOOLAP_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
  git -C "$STOOLAP_DIR" apply "$PATCH_FILE"
elif ! git -C "$STOOLAP_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
  echo "Stoolap patch is neither cleanly applicable nor already applied" >&2
  exit 1
fi

CARGO_HOME="${CARGO_HOME:-$ROOT_DIR/.cargo-home}" \
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/.cargo-target}" \
STOOLAP_GIT_COMMIT="${STOOLAP_COMMIT}+liquidstoolap.1" \
  cargo build --manifest-path "$STOOLAP_DIR/Cargo.toml" \
    --release --no-default-features --features ffi
