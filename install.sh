#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="source \"$SCRIPT_DIR/jr.sh\""

if grep -qF "$SCRIPT_DIR/jr.sh" ~/.bashrc 2>/dev/null; then
  echo "Already installed."
else
  echo "$LINE" >> ~/.bashrc
  echo "Done. Run: source ~/.bashrc"
fi
