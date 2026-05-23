#!/usr/bin/env bash
# Download the `statecraft` CLI binary onto the runner and put it on PATH.
# Same artifact the tray daemon bundles, mirrored to the public
# `statecraftapp/statecraft-cli` GitHub releases by `tray-release.yml`.
#
# Resolved version: the `STATECRAFT_CLI_VERSION` env var if set, else
# `latest`. v2.x of the action pins this to the latest CLI at action-release
# time to avoid silently absorbing breaking CLI changes between minor
# action releases — but the script honours an explicit override.

set -euo pipefail

VERSION="${STATECRAFT_CLI_VERSION:-latest}"
DEST_DIR="${RUNNER_TEMP:-/tmp}/statecraft-cli"
mkdir -p "$DEST_DIR"

if [[ "$VERSION" == "latest" ]]; then
  URL="https://github.com/statecraftapp/statecraft-cli/releases/latest/download/statecraft-linux-x86_64.tar.gz"
else
  URL="https://github.com/statecraftapp/statecraft-cli/releases/download/v${VERSION#v}/statecraft-linux-x86_64.tar.gz"
fi

echo "Downloading statecraft CLI ($VERSION) from $URL"
curl -fsSL -o "$DEST_DIR/statecraft.tar.gz" "$URL"
tar -xzf "$DEST_DIR/statecraft.tar.gz" -C "$DEST_DIR"
chmod +x "$DEST_DIR/statecraft"

# Verify it runs (catches arch/glibc mismatches before we hit the install
# step).
"$DEST_DIR/statecraft" --version

# Persist on PATH for subsequent steps in this job.
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$DEST_DIR" >>"$GITHUB_PATH"
fi
