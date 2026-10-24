#!/bin/sh
# Installs nust on macOS or Linux. No sudo needed.
#
#   curl -fsSL https://raw.githubusercontent.com/devvMuhammad/nust-cli/main/install.sh | sh
#
# Optional: NUST_VERSION=v0.1.0 to pin a release, NUST_INSTALL_DIR to pick the folder
# (default ~/.local/bin), NUST_BASE_URL to download from somewhere else (testing).

set -eu

REPO="devvMuhammad/nust-cli"
INSTALL_DIR="${NUST_INSTALL_DIR:-$HOME/.local/bin}"

err() {
  printf 'nust install: %s\n' "$*" >&2
  exit 1
}

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux) OS=linux ;;
  *) err "this script is for macOS and Linux. On Windows run: irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=x64 ;;
  *) err "unsupported CPU '$(uname -m)'; nust is built for arm64 and x86_64" ;;
esac

# A terminal running under Rosetta reports x86_64 on an Apple Silicon Mac. Use the native build.
if [ "$OS" = darwin ] && [ "$ARCH" = x64 ] && [ "$(sysctl -in hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
  ARCH=arm64
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  err "needs curl or wget"
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    err "needs sha256sum or shasum to check the download"
  fi
}

if [ -n "${NUST_BASE_URL:-}" ]; then
  BASE="${NUST_BASE_URL%/}"
elif [ -n "${NUST_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/v${NUST_VERSION#v}"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

asset="nust-$OS-$ARCH"
work=$(mktemp -d "${TMPDIR:-/tmp}/nust-install.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

echo "Downloading nust for $OS $ARCH..."
fetch "$BASE/$asset" "$work/nust" || err "could not download $BASE/$asset"
fetch "$BASE/SHA256SUMS" "$work/SHA256SUMS" || err "could not download $BASE/SHA256SUMS"

want=$(awk -v n="$asset" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print tolower($1); exit } }' "$work/SHA256SUMS")
[ -n "$want" ] || err "SHA256SUMS has no entry for $asset"
[ "$want" = "$(sha256 "$work/nust")" ] || err "the download is corrupted (checksum mismatch); nothing was installed"

mkdir -p "$INSTALL_DIR"
chmod 755 "$work/nust"
# Copy next to the target first so the final move is an atomic rename.
cp "$work/nust" "$INSTALL_DIR/.nust.new.$$"
mv -f "$INSTALL_DIR/.nust.new.$$" "$INSTALL_DIR/nust"

echo "Installed $("$INSTALL_DIR/nust" version 2>/dev/null || echo nust) to $INSTALL_DIR/nust"

# Put the folder on PATH for future terminals, once.
case ":$PATH:" in
  *":$INSTALL_DIR:"*) on_path=1 ;;
  *) on_path=0 ;;
esac
if [ "$on_path" = 0 ]; then
  # Write $HOME rather than the expanded path, so the line stays readable.
  shown="$INSTALL_DIR"
  case "$INSTALL_DIR" in "$HOME"/*) shown="\$HOME/${INSTALL_DIR#"$HOME"/}" ;; esac
  case "$(basename "${SHELL:-sh}")" in
    zsh) rc="$HOME/.zshrc"; line="export PATH=\"$shown:\$PATH\"" ;;
    bash) if [ "$OS" = darwin ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi; line="export PATH=\"$shown:\$PATH\"" ;;
    fish) rc="$HOME/.config/fish/config.fish"; line="fish_add_path \"$INSTALL_DIR\"" ;;
    *) rc="$HOME/.profile"; line="export PATH=\"$shown:\$PATH\"" ;;
  esac
  if ! grep -qsF "$line" "$rc"; then
    mkdir -p "$(dirname "$rc")"
    printf '\n# nust\n%s\n' "$line" >> "$rc"
    echo "Added $INSTALL_DIR to your PATH in $rc"
  fi
  echo
  echo "Open a new terminal, then run: nust login"
else
  echo
  echo "Next: nust login"
fi
