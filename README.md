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
      - uses: statecraftapp/pr-review-action@v1
        with:
          statecraft-token: ${{ secrets.STATECRAFT_PR_REVIEW_TOKEN }}
          # Optional: narrow what the survey agent considers.
          # scope: "checkout flow"
          # Optional: override slug if your statecraft.yaml doesn't have one.
          # design-system: my-ds-slug
```

## Inputs

| Name | Required | Default | Notes |
|------|----------|---------|-------|
| `statecraft-token` | yes | — | `sck_…` workspace token with `pr-review:run` scope. |
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
