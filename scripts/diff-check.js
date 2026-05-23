#!/usr/bin/env node
// Runner-side diff check — mirrors
// `services/journey-worker/src/prReview/dsDiffCheck.ts` so the action can
// decide whether the PR touched design-system source BEFORE spending the
// 1-3 min on install + `statecraft publish`. Most PRs don't touch DS files,
// so this is the dominant savings of v2 vs always-build.
//
// LLM-free by design — the answer is "did any file under entry_dir change?",
// which a deterministic check should never get wrong. Over-detection is
// fine (we'd rather build for a no-op PR than ship a broken preview);
// under-detection is not — that's a silent stale render.
//
// Usage:
//   node diff-check.js <base-sha> <head-sha> <repo-root>
//
// Output (stdout):
//   needs_build=true   (or false)
//   reason=<human-readable>
//
// Exits 0 even when needs_build=false. Exits 1 on internal errors (manifest
// missing, git diff failed) so the caller can distinguish "skipped"
// from "couldn't decide" — though the runner-side script today treats any
// non-zero exit as "fail safe, build anyway."

import { execSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';

const LOCKFILE_BASENAMES = new Set([
  'package.json',
  'package-lock.json',
  'pnpm-lock.yaml',
  'yarn.lock',
]);

function emit(needsBuild, reason) {
  // Output is two `key=value` lines so the bash caller can `eval` them or
  // `grep | cut` cleanly. Don't put quotes around values — the reason
  // string can contain anything; the caller treats the rest-of-line as
  // the value.
  process.stdout.write(`needs_build=${needsBuild ? 'true' : 'false'}\n`);
  process.stdout.write(`reason=${reason}\n`);
}

function fail(message) {
  process.stderr.write(`diff-check: ${message}\n`);
  // Fail-safe default for the caller — if it ignores our exit code, the
  // emitted state still says "build" so we err on the side of correctness.
  emit(true, `diff-check failed: ${message}`);
  process.exit(1);
}

// Minimal regex-based YAML extraction. We only need `build.entry` and the
// optional `additionalModules[].entry` paths from `statecraft.yaml`.
// Adding `yaml` as a dependency would force the action to do `npm install`
// before this step, which we want to avoid (the diff check is supposed to
// run BEFORE install so we can skip install entirely on no-DS-change PRs).
function extractEntryPaths(yamlText) {
  const lines = yamlText.split('\n');
  const entries = [];

  // 1. Top-level build: ... entry: ...
  //    YAML allows nested keys at any consistent indent; the customer's
  //    statecraft.yaml conventionally uses 2-space indent under `build:`.
  //    Match block-start at column 0 → indented `entry:` until next
  //    top-level key.
  let inBuild = false;
  for (const line of lines) {
    if (/^[A-Za-z]/.test(line)) {
      inBuild = /^build\s*:/.test(line);
      continue;
    }
    if (!inBuild) continue;
    const m = /^\s+entry\s*:\s*(.+?)\s*$/.exec(line);
    if (m) {
      let v = m[1].trim();
      // Strip optional surrounding quotes.
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      entries.push(v);
      break; // Only one `entry` under `build`.
    }
  }

  // 2. additionalModules — each item is `- entry: <path>` (optionally with
  //    other keys on subsequent lines). We don't try to handle arbitrarily
  //    deep object nesting; if someone wires that up, they can fall back
  //    to overriding the diff check (or simply accepting an always-build).
  let inAdditional = false;
  for (const line of lines) {
    if (/^[A-Za-z]/.test(line)) {
      inAdditional = /^additionalModules\s*:/.test(line);
      continue;
    }
    if (!inAdditional) continue;
    const m = /^\s*-?\s*entry\s*:\s*(.+?)\s*$/.exec(line);
    if (m) {
      let v = m[1].trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      entries.push(v);
    }
  }

  return entries;
}

function entryDirsFromEntries(entries) {
  const dirs = [];
  for (const entry of entries) {
    const trimmed = entry.replace(/^\.\/+/, '').replace(/^\/+/, '');
    if (!trimmed) continue;
    const dir = path.posix.dirname(trimmed);
    dirs.push(dir === '.' ? '' : `${dir}/`);
  }
  return dirs;
}

function changedFiles(baseSha, headSha, repoRoot) {
  try {
    const out = execSync(`git diff --name-only ${baseSha}...${headSha}`, {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return out.split('\n').map((s) => s.trim()).filter(Boolean);
  } catch (err) {
    throw new Error(`git diff failed: ${err.message ?? String(err)}`);
  }
}

function main() {
  const [, , baseSha, headSha, repoRoot] = process.argv;
  if (!baseSha || !headSha || !repoRoot) {
    fail('usage: diff-check.js <base-sha> <head-sha> <repo-root>');
    return;
  }

  const manifestRel = 'statecraft.yaml';
  const manifestAbs = path.join(repoRoot, manifestRel);
  if (!existsSync(manifestAbs)) {
    // Mirrors the worker: no manifest = fail safe, build.
    emit(true, 'no statecraft.yaml in repo root — failing safe');
    return;
  }
  const manifestText = readFileSync(manifestAbs, 'utf8');

  let files;
  try {
    files = changedFiles(baseSha, headSha, repoRoot);
  } catch (err) {
    fail(err.message);
    return;
  }

  // 1. Direct hit on the manifest.
  for (const f of files) {
    if (f === manifestRel) {
      emit(true, `manifest file changed: ${f}`);
      return;
    }
  }

  // 2. Entry-dir intersection.
  const entries = extractEntryPaths(manifestText);
  const dirs = entryDirsFromEntries(entries);
  for (const f of files) {
    for (const dir of dirs) {
      if (dir === '' || f.startsWith(dir)) {
        emit(true, `file under DS entry directory ${dir || '<repo root>'} changed: ${f}`);
        return;
      }
    }
  }

  // 3. Lockfile / package.json — intentionally broad.
  for (const f of files) {
    const base = path.posix.basename(f);
    if (LOCKFILE_BASENAMES.has(base)) {
      emit(true, `dependency manifest changed: ${f}`);
      return;
    }
  }

  emit(false, 'no DS source files touched');
}

main();
