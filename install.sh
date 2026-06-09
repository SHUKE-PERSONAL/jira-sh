#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/bin"
TARGET="$BIN/jr"

chmod +x "$SCRIPT_DIR/jr"

mkdir -p "$BIN"

if [[ -L "$TARGET" && "$(readlink "$TARGET")" == "$SCRIPT_DIR/jr" ]]; then
  echo "Already installed."
else
  ln -sf "$SCRIPT_DIR/jr" "$TARGET"
  echo "Installed: $TARGET"
  if [[ ":$PATH:" != *":$BIN:"* ]]; then
    echo "  Note: add $BIN to your PATH if not already set"
    echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.bashrc"
  fi
fi

# remove old source line if present
if grep -qF "jr.sh" ~/.bashrc 2>/dev/null; then
  sed -i '/jr\.sh/d' ~/.bashrc
  echo "Removed old 'source jr.sh' from ~/.bashrc"
fi
