#!/usr/bin/env bash
# Resolve which Node + package manager versions to set up on the runner so
# `pnpm install` / `npm ci` / `yarn install` matches the customer's existing
# CI environment. We deliberately mirror what their own `publish.yml` would
# do (read `.nvmrc`, `package.json#packageManager`, lockfile presence) so
# PR-review's runner-side build uses the same exact toolchain as the
# canonical publish path — that's the whole point of the v2 migration.
#
# Emits three `name=value` lines on $GITHUB_OUTPUT:
#   node-version=…           — value passed to actions/setup-node@v4
#   pkg-manager=pnpm|npm|yarn
#   pnpm-version=…           — value passed to pnpm/action-setup@v4 when
#                               pkg-manager==pnpm; empty otherwise.
#
# Optional overrides via env (set by the composite action when the customer
# passed inputs):
#   INPUT_NODE_VERSION       — overrides node detection
#   INPUT_PACKAGE_MANAGER    — overrides PM detection

set -euo pipefail

REPO_ROOT="${STATECRAFT_REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

# ---------- Node ----------
# Precedence: explicit input > .nvmrc > package.json#engines.node > lts/*.
# `actions/setup-node@v4` accepts whole versions, version ranges, and the
# meta-aliases (`lts/*`, `latest`).
NODE_VERSION="${INPUT_NODE_VERSION:-}"
if [[ -z "$NODE_VERSION" ]]; then
  if [[ -f .nvmrc ]]; then
    NODE_VERSION="$(tr -d ' \t\r\n' < .nvmrc)"
  fi
fi
if [[ -z "$NODE_VERSION" && -f package.json ]]; then
  NODE_VERSION="$(node -e '
    const p=require("./package.json");
    const v=p?.engines?.node;
    if (typeof v === "string") process.stdout.write(v);
  ' 2>/dev/null || true)"
fi
if [[ -z "$NODE_VERSION" ]]; then
  NODE_VERSION="lts/*"
fi

# ---------- Package manager ----------
PKG_MANAGER="${INPUT_PACKAGE_MANAGER:-}"
PNPM_VERSION=""
if [[ -z "$PKG_MANAGER" && -f package.json ]]; then
  # Read packageManager field. If present it's the canonical signal (npm,
  # pnpm, and corepack all honour it). Format is "name@x.y.z".
  PM_FIELD="$(node -e '
    const p=require("./package.json");
    if (typeof p?.packageManager === "string") process.stdout.write(p.packageManager);
  ' 2>/dev/null || true)"
  if [[ -n "$PM_FIELD" ]]; then
    PKG_MANAGER="${PM_FIELD%@*}"
    if [[ "$PKG_MANAGER" == "pnpm" ]]; then
      PNPM_VERSION="${PM_FIELD#*@}"
    fi
  fi
fi
if [[ -z "$PKG_MANAGER" ]]; then
  # Fall back to lockfile detection — same precedence as `actions/setup-node`'s
  # built-in cache detection.
  if   [[ -f pnpm-lock.yaml ]];     then PKG_MANAGER=pnpm
  elif [[ -f yarn.lock ]];           then PKG_MANAGER=yarn
  elif [[ -f package-lock.json ]];   then PKG_MANAGER=npm
  else                                    PKG_MANAGER=npm
  fi
fi

# Validate.
case "$PKG_MANAGER" in
  pnpm|npm|yarn) ;;
  *)
    echo "::error::resolve-toolchain: unknown package manager '$PKG_MANAGER' (expected pnpm | npm | yarn)" >&2
    exit 1
    ;;
esac

# If pnpm without an explicit pinned version, default to 9. Pre-pnpm-10 is
# the safest default for brownfield repos — the whole reason we moved
# build to the runner. The customer can override via packageManager field
# or the explicit action input.
if [[ "$PKG_MANAGER" == "pnpm" && -z "$PNPM_VERSION" ]]; then
  PNPM_VERSION="9"
fi

echo "node-version=$NODE_VERSION"
echo "pkg-manager=$PKG_MANAGER"
echo "pnpm-version=$PNPM_VERSION"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "node-version=$NODE_VERSION"
    echo "pkg-manager=$PKG_MANAGER"
    echo "pnpm-version=$PNPM_VERSION"
  } >>"$GITHUB_OUTPUT"
fi
