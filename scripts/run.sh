#!/usr/bin/env bash
# Statecraft PR review composite-action entry point.
#
# Reads PR context from $GITHUB_EVENT_PATH, POSTs to /api/pr-reviews/run,
# polls /api/pr-reviews/run?runId=… until terminal, then posts a sticky PR
# comment with one preview link per affected journey.
#
# Required env (set by action.yml):
#   STATECRAFT_TOKEN          sck_… workspace API token, scope pr-review:run
#   STATECRAFT_BASE_URL       Convex site URL
#   STATECRAFT_WEB_ORIGIN     used for preview links posted to the PR
#   STATECRAFT_POLL_TIMEOUT   seconds before we give up polling
#   STATECRAFT_POLL_INTERVAL  seconds between polls
#   GH_TOKEN                  token for posting the sticky PR comment
# Optional env:
#   STATECRAFT_SCOPE          free-text narrowing hint for the survey agent
#   STATECRAFT_DESIGN_SYSTEM  slug, if the workspace has multiple DSes

set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "::error::$name is empty (action input or required env)"
    exit 1
  fi
}

require STATECRAFT_TOKEN
require STATECRAFT_BASE_URL
require STATECRAFT_WEB_ORIGIN
require GH_TOKEN
require GITHUB_EVENT_PATH
require GITHUB_REPOSITORY

# Only meaningful on `pull_request` events. We intentionally do NOT accept
# `pull_request_target` here: that event runs with secrets exposed but
# defaults to the base-branch checkout, which is a well-known footgun for
# untrusted-PR scenarios. If a user really wants to wire this action into a
# `pull_request_target` workflow, they can do that themselves with informed
# consent — we won't bless it from the composite action.
event_name="${GITHUB_EVENT_NAME:-}"
case "$event_name" in
  pull_request) ;;
  *)
    echo "::error::This action only supports pull_request events (got: $event_name)."
    exit 1
    ;;
esac

pr_number=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
base_sha=$(jq -r '.pull_request.base.sha' "$GITHUB_EVENT_PATH")
head_sha=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")

if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
  echo "::error::Could not read .pull_request.number from event payload"
  exit 1
fi
if [[ -z "$base_sha" || "$base_sha" == "null" ]]; then
  echo "::error::Could not read .pull_request.base.sha from event payload"
  exit 1
fi
if [[ -z "$head_sha" || "$head_sha" == "null" ]]; then
  echo "::error::Could not read .pull_request.head.sha from event payload"
  exit 1
fi

base_url="${STATECRAFT_BASE_URL%/}"
web_origin="${STATECRAFT_WEB_ORIGIN%/}"

echo "::group::Submitting PR-review run"
echo "Repository: $GITHUB_REPOSITORY"
echo "PR #$pr_number  base=$base_sha  head=$head_sha"
echo "Statecraft: $base_url"
echo "::endgroup::"

# DS slug resolution: action input wins, then `slug:` from the repo's
# statecraft.yaml, then fail. The Statecraft side requires an explicit slug
# now (no more "auto-pick the workspace's single DS" — too implicit, broke
# when workspaces grew a second DS). The grep is intentionally strict so
# YAML quoting variations don't slip through silently:
#   `slug: foo`        → foo
#   `slug: "foo-bar"`  → foo-bar
#   `slug: 'foo'`      → foo
# Indented `slug:` keys (nested under another block) are ignored — only
# top-level `slug:` is the source of truth.
design_system="${STATECRAFT_DESIGN_SYSTEM:-}"
manifest_path="${STATECRAFT_REPO_ROOT:-$PWD}/statecraft.yaml"
if [[ -z "$design_system" && -f "$manifest_path" ]]; then
  raw_slug=$(grep -E '^slug:[[:space:]]+[^[:space:]]' "$manifest_path" | head -n 1 || true)
  if [[ -n "$raw_slug" ]]; then
    # Strip `slug:` prefix, surrounding whitespace, optional quotes.
    design_system=$(printf '%s' "$raw_slug" \
      | sed -E 's/^slug:[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')
    echo "Resolved design-system slug from statecraft.yaml: $design_system"
  fi
fi
if [[ -z "$design_system" ]]; then
  echo "::error::No design-system slug. Either add 'slug: <ds-slug>' to your repo's statecraft.yaml or pass design-system: <slug> as an action input."
  exit 1
fi

# ---------- v2: diff-detect on the runner + optional DS build ----------
# Mirrors the journey-worker's `detectDsSourceChange` so we can skip the
# 1-3 min install + publish on the (majority) PRs that don't touch DS
# source. When the diff DOES touch DS source, we build the ephemeral DS
# right here on the runner — using the customer's toolchain (their pnpm
# version, their lockfile, their `.npmrc`) instead of our worker's
# corepack-bundled pnpm 10. That's the structural fix for the runtime
# mismatch class of bug.

repo_root="${STATECRAFT_REPO_ROOT:-$PWD}"
diff_output=$(mktemp)
needs_build=false
diff_reason=""
if node "$GITHUB_ACTION_PATH/scripts/diff-check.js" "$base_sha" "$head_sha" "$repo_root" >"$diff_output" 2>&1; then
  needs_build=$(grep -E '^needs_build=' "$diff_output" | head -n 1 | sed -E 's/^needs_build=//')
  diff_reason=$(grep -E '^reason=' "$diff_output" | head -n 1 | sed -E 's/^reason=//')
else
  echo "::warning::diff-check exited non-zero; failing safe to build"
  cat "$diff_output"
  needs_build=true
  diff_reason="diff-check errored"
fi
rm -f "$diff_output"
echo "::group::Runner-side diff check"
echo "needs_build=$needs_build"
echo "reason=$diff_reason"
echo "::endgroup::"

ephemeral_ds_id=""
ephemeral_ds_slug=""

if [[ "$needs_build" == "true" ]]; then
  echo "::group::Minting ephemeral publish token"
  mint_body=$(jq -n \
    --arg repo "$GITHUB_REPOSITORY" \
    --argjson prNumber "$pr_number" \
    --arg headSha "$head_sha" \
    --arg designSystem "$design_system" \
    '{repo: $repo, prNumber: $prNumber, headSha: $headSha, designSystem: $designSystem}')
  mint_response=$(mktemp)
  http_status=$(curl -sS -o "$mint_response" -w '%{http_code}' \
    -X POST "$base_url/api/pr-reviews/mint-ephemeral-publish-token" \
    -H "Authorization: Bearer $STATECRAFT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$mint_body" || true)
  if [[ "$http_status" != "200" ]]; then
    echo "::error::Statecraft refused to mint ephemeral publish token (HTTP $http_status):"
    cat "$mint_response"
    echo
    exit 1
  fi
  ephemeral_token=$(jq -r '.token' "$mint_response")
  ephemeral_ds_slug=$(jq -r '.slug' "$mint_response")
  ephemeral_ds_id=$(jq -r '.designSystemId' "$mint_response")
  rm -f "$mint_response"
  echo "Ephemeral DS: $ephemeral_ds_slug ($ephemeral_ds_id)"
  echo "::endgroup::"

  echo "::group::Installing dependencies (${STATECRAFT_PKG_MANAGER:-pnpm})"
  pushd "$repo_root" >/dev/null
  case "${STATECRAFT_PKG_MANAGER:-pnpm}" in
    pnpm) pnpm install --frozen-lockfile ;;
    npm)  npm ci ;;
    yarn) yarn install --immutable ;;
    *)
      echo "::error::Unknown package manager: ${STATECRAFT_PKG_MANAGER}"
      exit 1
      ;;
  esac
  echo "::endgroup::"

  echo "::group::Building + publishing ephemeral design system"
  status_file=$(mktemp)
  # `--skip-install` because we just ran the install above with the
  # customer's lockfile + their PM. `--status-file` lets us read a clean
  # JSON outcome regardless of the CLI's textual log output.
  if ! STATECRAFT_TOKEN="$ephemeral_token" statecraft publish \
        --slug "$ephemeral_ds_slug" \
        --manifest "$repo_root/statecraft.yaml" \
        --skip-install \
        --status-file "$status_file"; then
    publish_error=$(jq -r '.error.detail // .error.title // ""' "$status_file" 2>/dev/null || echo "")
    if [[ -z "$publish_error" ]]; then
      publish_error="statecraft publish exited non-zero (no status-file detail)"
    fi
    echo "::error::Design system build failed: $publish_error"
    # Post the sticky comment so the PR shows the failure inline, then
    # exit. No prReviewRuns row exists yet (we haven't POSTed /run), so
    # this is the only place the failure surfaces in the PR thread.
    MARKER='<!-- statecraft-pr-review -->'
    comment_body="$MARKER
**Statecraft preview · design system build failed.**

The runner-side build of your design system failed before the PR-review run could start. The error from \`statecraft publish\`:

\`\`\`
$publish_error
\`\`\`

_See the [Statecraft PR review docs](https://statecraftapp.com/docs/pr-review) for the build-failure troubleshooting steps._"
    api_base="${GITHUB_API_URL:-https://api.github.com}"
    payload=$(jq -n --arg body "$comment_body" '{body: $body}')
    curl -sS -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$api_base/repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" \
      -d "$payload" >/dev/null || true
    rm -f "$status_file"
    exit 1
  fi
  publish_status=$(jq -r '.status' "$status_file" 2>/dev/null || echo "")
  rm -f "$status_file"
  if [[ "$publish_status" != "published" && "$publish_status" != "nochange" ]]; then
    echo "::error::statecraft publish reported unexpected status: $publish_status"
    exit 1
  fi
  echo "publish status: $publish_status"
  popd >/dev/null
  echo "::endgroup::"
fi

# ---------- POST the run-create with v2 fields ----------
if [[ -n "$ephemeral_ds_id" ]]; then
  request_body=$(jq -n \
    --arg repo "$GITHUB_REPOSITORY" \
    --argjson prNumber "$pr_number" \
    --arg baseSha "$base_sha" \
    --arg headSha "$head_sha" \
    --arg scope "${STATECRAFT_SCOPE:-}" \
    --arg designSystem "$design_system" \
    --arg ephemeralDsId "$ephemeral_ds_id" \
    --arg ephemeralDsSlug "$ephemeral_ds_slug" \
    '{repo: $repo, prNumber: $prNumber, baseSha: $baseSha, headSha: $headSha,
      designSystem: $designSystem,
      buildMode: "runner",
      ephemeralDesignSystemId: $ephemeralDsId,
      ephemeralDesignSystemSlug: $ephemeralDsSlug}
     + (if $scope == "" then {} else {scope: $scope} end)')
else
  request_body=$(jq -n \
    --arg repo "$GITHUB_REPOSITORY" \
    --argjson prNumber "$pr_number" \
    --arg baseSha "$base_sha" \
    --arg headSha "$head_sha" \
    --arg scope "${STATECRAFT_SCOPE:-}" \
    --arg designSystem "$design_system" \
    '{repo: $repo, prNumber: $prNumber, baseSha: $baseSha, headSha: $headSha,
      designSystem: $designSystem}
     + (if $scope == "" then {} else {scope: $scope} end)')
fi

create_response=$(mktemp)
http_status=$(curl -sS -o "$create_response" -w '%{http_code}' \
  -X POST "$base_url/api/pr-reviews/run" \
  -H "Authorization: Bearer $STATECRAFT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$request_body" || true)

if [[ "$http_status" != "202" ]]; then
  echo "::error::Statecraft rejected the run (HTTP $http_status):"
  cat "$create_response"
  echo
  exit 1
fi

run_id=$(jq -r '.runId' "$create_response")
reused=$(jq -r '.reused' "$create_response")
if [[ -z "$run_id" || "$run_id" == "null" ]]; then
  echo "::error::Response missing runId:"
  cat "$create_response"
  exit 1
fi
rm -f "$create_response"

echo "Run: $run_id  (reused: $reused)"
echo "run-id=$run_id" >>"$GITHUB_OUTPUT"

# ---------- Workflow-cancel propagation ----------
# GitHub Actions kills run.sh with SIGTERM when a user clicks "Cancel" in
# the workflow UI. Without a trap, the script just dies — but the actual
# work happens on the Statecraft worker which has no idea the user gave
# up, so the run keeps churning (and may still post the sticky comment).
# Trap and POST a cancel before exiting so the worker's turn-boundary
# check picks it up and exits cleanly, including cascading to the
# spawned journey-import children.
cancel_on_signal() {
  local sig="$1"
  echo "::warning::Received $sig — requesting Statecraft to cancel run $run_id"
  curl -sS -o /dev/null \
    -X DELETE "$base_url/api/pr-reviews/run?runId=$run_id" \
    -H "Authorization: Bearer $STATECRAFT_TOKEN" \
    --max-time 10 || true
  exit 130
}
trap 'cancel_on_signal SIGINT' INT
trap 'cancel_on_signal SIGTERM' TERM

# ---------- Poll ----------
deadline=$(( $(date +%s) + STATECRAFT_POLL_TIMEOUT ))
poll_response=$(mktemp)
status=""
current_phase=""
last_logged_phase=""

while :; do
  http_status=$(curl -sS -o "$poll_response" -w '%{http_code}' \
    -G "$base_url/api/pr-reviews/run" \
    --data-urlencode "runId=$run_id" \
    -H "Authorization: Bearer $STATECRAFT_TOKEN" || true)

  if [[ "$http_status" != "200" ]]; then
    echo "::warning::Poll returned HTTP $http_status"
    cat "$poll_response"
    echo
    # Don't fail on transient errors; just retry until the timeout.
  else
    status=$(jq -r '.status // ""' "$poll_response")
    current_phase=$(jq -r '.currentPhase // ""' "$poll_response")
    if [[ "$current_phase" != "$last_logged_phase" && -n "$current_phase" ]]; then
      echo "[$status] phase: $current_phase"
      last_logged_phase="$current_phase"
    fi
    case "$status" in
      done|failed|cancel_requested) break ;;
    esac
  fi

  if (( $(date +%s) >= deadline )); then
    status="timeout"
    break
  fi
  sleep "$STATECRAFT_POLL_INTERVAL"
done

echo "status=$status" >>"$GITHUB_OUTPUT"

# Build the preview-links JSON enriched with full URLs the comment can link to.
preview_links_json='[]'
last_error=''
ds_build_status=''
if [[ "$status" == "done" || "$status" == "failed" || "$status" == "cancel_requested" ]]; then
  workspace_id=$(jq -r '.workspaceId // ""' "$poll_response")
  last_error=$(jq -r '.lastError // ""' "$poll_response")
  # When the PR's diff touched DS source files the worker spawns a DS-build
  # child first; on failure the parent run's `lastError` gets a "Design
  # system build failed: ..." prefix and `dsBuildStatus` is set to 'failed'.
  # We render that case with a distinct sticky-comment body so the user
  # knows it's a build problem rather than a render problem.
  ds_build_status=$(jq -r '.dsBuildStatus // ""' "$poll_response")
  preview_links_json=$(jq --arg origin "$web_origin" --arg ws "$workspace_id" \
    '[.previewLinks[] | . + {url: ($origin + "/w/" + $ws + "/p/" + (.projectId|tostring))}]' \
    "$poll_response")
fi
rm -f "$poll_response"

# Use a heredoc + delimiter so we can set a multi-line GITHUB_OUTPUT value.
{
  echo "preview-links-json<<__END_PREVIEW_LINKS__"
  echo "$preview_links_json"
  echo "__END_PREVIEW_LINKS__"
} >>"$GITHUB_OUTPUT"

# ---------- Build & post the sticky comment ----------
MARKER='<!-- statecraft-pr-review -->'

build_body() {
  local body=""
  body+="$MARKER"$'\n'
  case "$status" in
    done)
      local count
      count=$(jq 'length' <<<"$preview_links_json")
      if [[ "$count" -eq 0 ]]; then
        body+="**Statecraft preview** · this PR doesn't appear to touch any user journeys the survey agent recognised."$'\n'
      else
        body+="**Statecraft preview** · $count journey$( [[ $count == 1 ]] || echo s ) affected by this PR:"$'\n\n'
        body+=$(jq -r '.[] | "- [" + .journeyName + "](" + .url + ")"' <<<"$preview_links_json")
        body+=$'\n'
      fi
      ;;
    failed)
      if [[ "$ds_build_status" == "failed" ]]; then
        body+="**Statecraft preview · design system build failed.**"$'\n\n'
        body+="This PR modifies the design system, so we tried to rebuild it from the PR's checkout before rendering. The build failed:"$'\n\n'
      else
        body+="**Statecraft preview failed.**"$'\n\n'
      fi
      if [[ -n "$last_error" ]]; then
        body+='```'$'\n'"$last_error"$'\n''```'$'\n'
      fi
      ;;
    cancel_requested)
      body+="**Statecraft preview cancelled.**"$'\n'
      ;;
    timeout)
      body+="**Statecraft preview still running** after ${STATECRAFT_POLL_TIMEOUT}s. The agent may still complete; check the workspace's PR Reviews surface for the latest status."$'\n'
      ;;
    *)
      body+="**Statecraft preview** ended with unexpected status: \`$status\`."$'\n'
      ;;
  esac
  body+=$'\n'"_Run \`$run_id\` · [docs](https://statecraftapp.com/docs/pr-review)_"
  printf '%s' "$body"
}

comment_body=$(build_body)

# Sticky comment: find an existing comment with our marker, edit if found;
# otherwise create a new one.
api_base="${GITHUB_API_URL:-https://api.github.com}"
list_response=$(mktemp)
http_status=$(curl -sS -o "$list_response" -w '%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api_base/repos/$GITHUB_REPOSITORY/issues/$pr_number/comments?per_page=100" || true)

if [[ "$http_status" != "200" ]]; then
  echo "::warning::Could not list PR comments (HTTP $http_status); skipping sticky update."
  cat "$list_response"
  echo
  rm -f "$list_response"
elif command -v jq >/dev/null; then
  existing_id=$(jq -r --arg m "$MARKER" \
    '[.[] | select(.body != null and (.body | startswith($m))) | .id] | first // empty' \
    "$list_response")
  rm -f "$list_response"

  comment_payload=$(jq -n --arg body "$comment_body" '{body: $body}')

  if [[ -n "$existing_id" ]]; then
    echo "Editing existing PR comment $existing_id"
    curl -sS -X PATCH \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$api_base/repos/$GITHUB_REPOSITORY/issues/comments/$existing_id" \
      -d "$comment_payload" >/dev/null
  else
    echo "Creating new PR comment"
    curl -sS -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$api_base/repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" \
      -d "$comment_payload" >/dev/null
  fi
fi

case "$status" in
  done)
    exit 0
    ;;
  failed)
    echo "::error::Statecraft run failed: $last_error"
    exit 1
    ;;
  cancel_requested)
    echo "::error::Statecraft run was cancelled."
    exit 1
    ;;
  timeout)
    echo "::error::Statecraft run did not reach a terminal status within ${STATECRAFT_POLL_TIMEOUT}s."
    exit 1
    ;;
  *)
    echo "::error::Statecraft run ended with unexpected status: $status"
    exit 1
    ;;
esac
