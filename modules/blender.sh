# blender — headless Blender (BLENDER_PIN, sha256-verified official tarball) + the system libraries and xvfb it needs
# `blender -b … -P scene.py`.
# shellcheck shell=bash

setup() {
  { apt_install libxi6 libxkbcommon0 libxkbcommon-x11-0 libsm6 libice6 libxext6 \
    libxrender1 libxfixes3 libx11-6 libxxf86vm1 libxrandr2 libxinerama1 libxcursor1 \
    libgl1 libegl1 libgl1-mesa-dri libglu1-mesa xvfb libcairo2 || return 1; }
  blender_install
}

status() { blender_have && echo "blender=$BLENDER_PIN" || echo "blender=missing"; }

blender_dest() { echo "$OPT/blender-${BLENDER_PIN}"; }
blender_have() { "$(blender_dest)/blender" --version 2>/dev/null | head -1 | grep -q "Blender ${BLENDER_PIN}"; }

blender_install() {
  [ "$(uname -m)" = x86_64 ] || { echo "blender: linux-x64 only" >&2; return 1; }
  local dest name url tmp
  dest="$(blender_dest)"; name="blender-${BLENDER_PIN}-linux-x64"
  url="https://download.blender.org/release/Blender${BLENDER_PIN%.*}/${name}.tar.xz"
  if ! blender_have; then
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 --max-time 900 -o "$tmp/b.tar.xz" "$url" \
      && echo "${BLENDER_SHA256}  $tmp/b.tar.xz" | sha256sum -c --status \
      && tar -xJf "$tmp/b.tar.xz" -C "$tmp" && rm -rf "$dest" && mv "$tmp/$name" "$dest"
    local rc=$?; rm -rf "$tmp"; [ $rc = 0 ] || { echo "blender: download/verify/unpack failed ($url)" >&2; return 1; }
  fi
  link blender "$dest/blender"; blender_have
}
