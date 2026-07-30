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

# --- Windows: PowerShell entry point --------------------------------------
# PowerShell can't run a '#!/usr/bin/env bash' script, so install jr.ps1 beside
# the jr symlink. PowerShell resolves a bare `jr` on PATH to jr.ps1 ahead of the
# extensionless file, and the wrapper finds the bash jr as its own sibling.

# Is $BIN on the *persisted Windows* PATH? bash's own $PATH is no proxy: a
# `~/.bashrc` PATH export is invisible to PowerShell, and vice versa. Read what
# a fresh PowerShell would inherit — the user + machine Environment keys.
# (`//v` survives MSYS path mangling; a bare `/v` becomes a filesystem path.)
_jr_win_path_has_bin() {
  local reg winbin up
  # Compare in one normal form — lowercase, forward slashes — so neither case
  # nor separator style can hide a match, and so the %USERPROFILE% expansion
  # below has no backslashes to be misread as escapes.
  reg=$( { reg.exe query "HKCU\\Environment" //v Path 2>/dev/null
           reg.exe query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" //v Path 2>/dev/null
         } | tr -d '\r' | tr '[:upper:]' '[:lower:]' | tr '\\' '/' )
  [[ -n "$reg" ]] || return 1
  up=$(printf '%s' "${USERPROFILE:-}" | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
  # PATH entries are commonly stored unexpanded
  [[ -n "$up" ]] && reg=${reg//'%userprofile%'/$up}
  winbin=$(cygpath -m "$BIN" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [[ -n "$winbin" && "$reg" == *"$winbin"* ]]
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    PS_TARGET="$BIN/jr.ps1"
    if [[ -L "$PS_TARGET" && "$(readlink "$PS_TARGET")" == "$SCRIPT_DIR/jr.ps1" ]]; then
      echo "Already installed: $PS_TARGET"
    elif cmp -s "$SCRIPT_DIR/jr.ps1" "$PS_TARGET"; then
      # ln -s degrades to a copy on hosts without symlink support
      echo "Already installed: $PS_TARGET"
    else
      ln -sf "$SCRIPT_DIR/jr.ps1" "$PS_TARGET"
      echo "Installed: $PS_TARGET (run jr from PowerShell)"
    fi

    if ! _jr_win_path_has_bin; then
      WIN_BIN=$(cygpath -w "$BIN" 2>/dev/null || echo "$BIN")
      echo "  Note: $WIN_BIN is not on the Windows PATH, so PowerShell won't find jr."
      echo "    Add it (takes effect in new PowerShell sessions):"
      echo "      [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$WIN_BIN', 'User')"
    fi
    echo "  Note: PowerShell does not read ~/.bashrc — set the JIRA_* vars as Windows user"
    echo "        env vars too, e.g."
    echo "      [Environment]::SetEnvironmentVariable('JIRA_TOKEN', '<token>', 'User')"
    ;;
esac

# remove old source line if present
if grep -qF "jr.sh" ~/.bashrc 2>/dev/null; then
  sed -i '/jr\.sh/d' ~/.bashrc
  echo "Removed old 'source jr.sh' from ~/.bashrc"
fi
