# Statecraft PR review action

Generate a visual preview of the user journeys touched by a pull request. On
PR open / synchronize, this action POSTs the PR's base + head SHAs to a
Statecraft workspace; a server-side worker clones the repo at HEAD, runs a
survey agent that proposes affected journeys, spawns one render run per
journey, and posts a sticky PR comment with preview links.

## Prerequisites

1. **Workspace API token** with the `pr-review:run` scope. Mint via the
   editor's Workspace Settings → API tokens UI (check the `pr-review:run`
   box), or via the CLI:

   ```
   statecraft tokens create \
     --workspace <slug> \
     --name pr-review-ci \
     --scope pr-review:run
   ```

   The plaintext value is shown once. Store it as a GitHub repository
   secret named `STATECRAFT_PR_REVIEW_TOKEN` (or whatever you reference
   from your workflow's `with:` block).

2. **`slug:` field at the top of your repo's `statecraft.yaml`.** The
   action reads it to decide which design system in your workspace the
   preview should render against. Example:

   ```yaml
   slug: my-design-system
   ```

   If you'd rather not put the slug in the manifest, pass `design-system:`
   explicitly in the workflow's `with:` block — the input takes
   precedence over the yaml.

3. **GitHub permissions.** Your Statecraft GitHub OAuth app must have
   access to the repo. For private repos owned by an organization with
   OAuth App access restrictions enabled, grant the app access at
   `https://github.com/settings/connections/applications/<client-id>`.

## Example workflow

Place at `.github/workflows/pr-review.yml`:

```yaml
name: Statecraft PR review
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  review:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      pull-requests: write   # for the sticky comment
      contents: read
    steps:
      - uses: statecraftapp/pr-review-action@v2
        with:
          statecraft-token: ${{ secrets.STATECRAFT_PR_REVIEW_TOKEN }}
          # Optional: narrow what the survey agent considers.
          # scope: "checkout flow"
          # Optional: override slug if your statecraft.yaml doesn't have one.
          # design-system: my-ds-slug
          # Optional: override toolchain detection if heuristics misfire.
          # node-version: "20"
          # package-manager: pnpm
```

## What v2 changed

Starting with `@v2`, the action runs your design system's build **on the GitHub Actions runner** — using your repo's own pnpm/Node version, lockfile, and `.npmrc` — instead of in our Fly worker. That means the same toolchain that powers your canonical `publish.yml` also powers PR-review's per-PR ephemeral build, eliminating "works in my CI, breaks in Statecraft's" surprises (pnpm 10 build-script blocking being the most common). Most PRs don't touch design-system source and skip the build entirely; when the build IS needed the runner caches `pnpm install` across runs natively.

`@v1` keeps working unchanged through at least 2026-08 — pinning to `@v1` keeps the server-side Fly build path.

## Inputs

| Name | Required | Default | Notes |
|------|----------|---------|-------|
| `statecraft-token` | yes | — | `sck_…` workspace token with `pr-review:run` scope. |
| `node-version` | no | (heuristic) | Override the Node.js version installed on the runner. Default reads `.nvmrc`, then `package.json#engines.node`, falls back to `lts/*`. |
| `package-manager` | no | (heuristic) | Override the package manager (`pnpm` / `npm` / `yarn`). Default reads `package.json#packageManager`, then falls back to lockfile detection. |
| `statecraft-cli-version` | no | `latest` | Statecraft CLI version installed for the DS-build step. Pin to lock against breaking changes between minor action releases. |
| `statecraft-base-url` | no | `https://api.statecraftapp.com` | Convex site URL for the deployment hosting the HTTP routes. |
| `statecraft-web-origin` | no | `https://statecraftapp.com` | Used to build preview links posted to the PR comment. |
| `scope` | no | `""` | Free-text hint passed to the survey agent to narrow what it enumerates. |
| `design-system` | no | (read from `statecraft.yaml`) | DS slug override. |
| `poll-timeout-seconds` | no | `1800` | Max seconds to wait for the run to reach a terminal status. |
| `poll-interval-seconds` | no | `5` | Seconds between status polls. |
| `github-token` | no | `${{ github.token }}` | Token used to post the sticky comment. Supply a PAT only to comment from a bot account. |

## Outputs

| Name | Notes |
|------|-------|
| `run-id` | The `prReviewRuns` id created (or reused) for this PR. |
| `status` | Terminal status of the run (`done`, `failed`, `cancel_requested`). |
| `preview-links-json` | JSON array of `{projectId, slug, journeyName, url}` per affected journey. |

## Event support

Only the `pull_request` event is supported. We intentionally do **not**
accept `pull_request_target`: it exposes secrets to fork PRs while
defaulting to a base-branch checkout, and is a common security footgun.
If you need a fork-PR variant, wrap your own workflow around the action
with informed consent.

## Cancellation

Clicking "Cancel" on the workflow run in the GitHub Actions UI propagates
back to the Statecraft worker via a `DELETE /api/pr-reviews/run` from the
script's `SIGTERM` / `SIGINT` trap. The worker's turn-boundary check
picks up the cancel and exits cleanly, including cascading to any
journey-import children the run had already spawned.

## Re-runs

The Statecraft side upserts on `(workspace, repo, prNumber)`. Pushing a
new commit to the same PR re-queues the same row with a bumped
`attemptId` — older in-flight workers detect the change and exit
cleanly without clobbering the new attempt's state. Per-journey project
URLs are stable across pushes when the survey agent reuses the previous
push's slug (see the `previousJourneys` plumbing in `prReviewRuns`).

## Common errors

| Server response | What it means |
|---|---|
| `400 Design system with slug "…" not found in this workspace.` | The slug resolved (from input or `statecraft.yaml`) doesn't match a DS in the workspace your token is scoped to. `statecraft design-system ls` shows what exists where. Align the slug, override it via the workflow input, or import the DS into the right workspace. |
| `401 Missing/invalid Authorization` | The `statecraft-token` secret is empty, malformed, or scoped to a different deployment than the one the action is POSTing to (default: `api.statecraftapp.com` = prod). Mint a fresh token with the `pr-review:run` scope in the target workspace. |
| `402 Agent credit limit reached` | Account hit its per-period agent-credit ceiling. Upgrade or add an Anthropic API key on the Account page (BYO-key bypasses metering). |
| `404` from `api.statecraftapp.com` | Means you're not actually reaching Convex — usually a stale fork of this action with a base-URL that isn't wired up. Use the latest `@v1` and the default `statecraft-base-url`. |
