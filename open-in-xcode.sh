#!/usr/bin/env bash
#
# Bootstrap Macterm and open it in Xcode.
# Run from the repo root:  ./open-in-xcode.sh
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

# --- mise on PATH (installed via Homebrew) --------------------------------
if ! command -v mise >/dev/null 2>&1; then
  if [[ -x /opt/homebrew/bin/mise ]]; then
    eval "$(/opt/homebrew/bin/mise activate bash)"
  else
    echo "mise not found. Install it with:  brew install mise" >&2
    exit 1
  fi
else
  eval "$(mise activate bash)"
fi

# --- Point xcodebuild at the full Xcode (not Command Line Tools) ----------
# The build needs the full Xcode. This requires sudo (password prompt).
XCODE="/Applications/Xcode-beta.app"
[[ -d "$XCODE" ]] || XCODE="/Applications/Xcode.app"
if [[ ! -d "$XCODE" ]]; then
  echo "No Xcode.app found in /Applications. Install Xcode first." >&2
  exit 1
fi
ACTIVE="$(xcode-select -p 2>/dev/null || true)"
if [[ "$ACTIVE" != "$XCODE/Contents/Developer" ]]; then
  echo ">> Switching active developer dir to $XCODE (needs sudo)"
  sudo xcode-select -s "$XCODE/Contents/Developer"
fi
# Accept the Xcode license if needed (no-op if already accepted)
sudo xcodebuild -license accept 2>/dev/null || true

# --- Authenticated GitHub access avoids rate limits -----------------------
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"

# --- Install project tools (xcodegen, swiftformat, swiftlint, xcbeautify) -
echo ">> Installing project tools via mise"
mise trust
mise install

# --- Download the pre-built GhosttyKit.xcframework ------------------------
# Needs access to the private thdxg/ghostty repo via gh.
echo ">> Downloading GhosttyKit framework"
mise run setup

# --- Generate the Xcode project and open it -------------------------------
echo ">> Generating Macterm.xcodeproj"
mise exec -- xcodegen generate

echo ">> Opening in Xcode"
open Macterm.xcodeproj

echo
echo "Done. In Xcode: select the 'Macterm' scheme and press Cmd+R to run."
