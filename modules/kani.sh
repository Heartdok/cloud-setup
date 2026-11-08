# kani — the Kani Rust model checker (KANI_PIN): `cargo kani` proves #[kani::proof] harnesses; on the rust module's toolchain
# `cargo install kani-verifier`, then `cargo kani setup`, which fetches Kani's bundle (CBMC inside)
# and the nightly toolchain it builds with into ~/.kani and our rustup. The largest download here:
# a setup that runs out of time cuts it, and a session's repair then finishes it. Wrappers in $BIN set RUSTUP_HOME/CARGO_HOME as the rust module's do.
# shellcheck shell=bash

# shellcheck disable=SC2034 # read by lib/common.sh requires_of
requires="rust"

KANI_WRAPPERS="kani cargo-kani"

kani_env() {
  if [ "$RO_HOME" = 1 ]; then RUSTUP_HOME="$OPT/rustup"; CARGO_HOME="$OPT/cargo"; else RUSTUP_HOME="$HOME/.rustup"; CARGO_HOME="$HOME/.cargo"; fi
  export RUSTUP_HOME CARGO_HOME PATH="$CARGO_HOME/bin:$PATH"
}

setup() {
  kani_env
  if ! kani_installed; then
    cargo install --locked kani-verifier --version "$KANI_PIN" >/dev/null 2>&1 || { echo "kani: cargo install kani-verifier $KANI_PIN failed" >&2; return 1; }
  fi
  kani_ready || in_ihome cargo kani setup >/dev/null 2>&1 || { echo "kani: cargo kani setup failed" >&2; return 1; }
  kani_wrappers && kani_have
}

drift() { kani_env; kani_have || echo kani; }   # reconcile: the pinned release, set up
reconcile() { setup; }

status() { kani_env; kani_have && echo "kani=$KANI_PIN" || echo "kani=missing"; }

kani_installed() { "$CARGO_HOME/bin/cargo-kani" --version 2>/dev/null | grep -q " ${KANI_PIN}\$"; }
kani_ready() { [ -d "${KANI_HOME:-$IHOME/.kani}/kani-${KANI_PIN}" ]; }
kani_have() { kani_installed && kani_ready && [ -x "$BIN/cargo-kani" ]; }

kani_wrappers() {
  local n tmp
  for n in $KANI_WRAPPERS; do
    tmp="$BIN/.$n.$$"
    printf '#!/bin/sh\n# cloud-setup kani: run %s on our own rustup\nexport RUSTUP_HOME=%q CARGO_HOME=%q\nexec %q "$@"\n' \
      "$n" "$RUSTUP_HOME" "$CARGO_HOME" "$CARGO_HOME/bin/$n" > "$tmp" \
      && chmod 755 "$tmp" && mv -f "$tmp" "$BIN/$n" || { rm -f "$tmp"; return 1; }
  done
  mirror_bin $KANI_WRAPPERS   # word list
}
