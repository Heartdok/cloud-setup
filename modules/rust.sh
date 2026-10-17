# rust — a user-space Rust toolchain via our own rustup: each repo's pinned toolchain (rust-toolchain[.toml]), else stable minimal
# Never the image's rustup (Cursor's ships an older one the user cannot write to): ours lives in
# ~/.rustup + ~/.cargo, or with a read-only HOME (Codex Cloud) in <prefix>/opt/{rustup,cargo}
# (lib/common.sh). Small wrappers in $BIN (cargo, rustc, rustup, rustfmt, cargo-clippy, clippy-driver,
# rustdoc) export RUSTUP_HOME/CARGO_HOME and exec the real proxy, so a session that only has
# $BIN on PATH uses our toolchain whatever RUSTUP_HOME/CARGO_HOME the image sets. No root needed.
# shellcheck shell=bash

RUST_WRAPPERS="cargo rustc rustup rustfmt cargo-clippy clippy-driver rustdoc"

# Where our rustup lives; exported so every rustup/cargo run below uses it, not the image's.
rust_env() {
  if [ "$RO_HOME" = 1 ]; then RUSTUP_HOME="$OPT/rustup"; CARGO_HOME="$OPT/cargo"
  else RUSTUP_HOME="$HOME/.rustup"; CARGO_HOME="$HOME/.cargo"; fi
  export RUSTUP_HOME CARGO_HOME
  # rustup-init refuses to run beside a rustc it did not install (Cursor's system Rust); we want both.
  export RUSTUP_INIT_SKIP_PATH_CHECK=yes
}

# rustup's own installer: a minimal profile, no shell-rc edits (the wrappers are the PATH story).
rust_install_rustup() {
  ( set -o pipefail
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal )
}

# The wrappers, written to a temp name and renamed so an existing $BIN/<name> (a symlink to the
# image's copy, say) is replaced, never written through.
rust_wrappers() {
  local n tmp
  for n in $RUST_WRAPPERS; do
    tmp="$BIN/.$n.$$"
    printf '#!/bin/sh\n# cloud-setup rust: run the real %s from our own rustup\nexport RUSTUP_HOME=%q CARGO_HOME=%q\nexec %q "$@"\n' \
      "$n" "$RUSTUP_HOME" "$CARGO_HOME" "$CARGO_HOME/bin/$n" > "$tmp" \
      && chmod 755 "$tmp" && mv -f "$tmp" "$BIN/$n" || { rm -f "$tmp"; return 1; }
  done
  hash -r
}

# In a repo that pins a toolchain: install it (channel + components). rustup >= 1.28 does this with
# `toolchain install`; older ones did it in `show`. Then prove the pin resolves.
rust_pin() {
  [ -f rust-toolchain.toml ] || [ -f rust-toolchain ] || return 0
  "$CARGO_HOME/bin/rustup" toolchain install || "$CARGO_HOME/bin/rustup" show >/dev/null || return 1
  "$CARGO_HOME/bin/rustc" --version >/dev/null
}

setup() {
  rust_env
  # Always ours: a rustup elsewhere on PATH is not a reason to skip.
  [ -x "$CARGO_HOME/bin/rustup" ] || in_ihome rust_install_rustup || { echo "rust: rustup install failed" >&2; return 1; }
  [ -x "$CARGO_HOME/bin/rustup" ] || { echo "rust: rustup not found in $CARGO_HOME/bin after install" >&2; return 1; }
  # A repeat run repairs a half-finished install: a default toolchain (stable, minimal) must exist.
  "$CARGO_HOME/bin/rustup" show active-toolchain >/dev/null 2>&1 \
    || { "$CARGO_HOME/bin/rustup" set profile minimal && "$CARGO_HOME/bin/rustup" default stable; } || return 1
  rust_wrappers || return 1
  in_repos_wanting rust rust_pin
}

status() {
  local r repos v
  rust_env
  repos="$(repos_wanting rust)"; [ -n "$repos" ] || repos=.
  while IFS= read -r r; do
    [ -d "$r" ] || continue
    v="$(cd "$r" && RUSTUP_AUTO_INSTALL=0 ver "$CARGO_HOME/bin/rustc" --version)"
    echo "rust=${v:-missing}"
  done <<< "$repos" | sort -u | paste -sd' ' -
}
