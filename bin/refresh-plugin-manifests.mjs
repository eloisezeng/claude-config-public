#!/usr/bin/env node
// Regenerate the repo's plugin manifests from this machine's live plugin state.
//
// WHY A NORMALIZER AND NOT A COPY. The live files under $CLAUDE_CONFIG_DIR/plugins
// are a CACHE record, not a declaration. Copying them into the repo verbatim was
// the old arrangement, and it produced three defects, all measured 2026-09-09:
//
//   * `installPath` is an ABSOLUTE path under the running machine's home. The
//     committed copy carried three entries under a second machine's home
//     alongside this machine's, because whichever box committed last won. Two
//     machines syncing the raw file would rewrite each other forever: every
//     sync a diff, every diff a commit, neither ever converging.
//   * `lastUpdated` / `gitCommitSha` / `version` move whenever a plugin's cache
//     refreshes -- churn that says nothing about what is INSTALLED.
//   * The raw file used to carry `enabledPlugins`; Claude Code has since moved
//     that to settings.json, which this repo already tracks as a symlink. The
//     committed copy was a stale duplicate of a record something else now owns.
//
// So this writes the DECLARATION -- which marketplaces exist, which plugins are
// installed from them, at what scope -- with every machine-local and volatile
// field dropped.
//
// WHY IT UNIONS RATHER THAN REPLACES. Dropping the volatile fields makes the
// output's SHAPE machine-independent; it does not make the plugin SET
// machine-independent, and an earlier version of this comment claimed it did
// ("byte-identical on every machine"). That claim is only true when the machines
// have the same plugins installed. Measured 2026-09-09: this Mac has
// `mattpocock-skills@mattpocock` and `claude-mem@thedotmack`; the box that also
// syncs this repo does not -- so the two sides alternately added and removed the
// same ten lines, 13 commits in 86 minutes, every sync a diff and neither ever
// converging. That is the very defect the notes above say a raw copy caused; the
// normalizer inherited it because subtraction, not formatting, was the cause.
//
// The manifest is therefore treated as a DECLARATION of what this configuration
// WANTS installed -- a union across the machines that share it -- not an
// inventory of any one machine. A machine that has never installed a plugin now
// leaves that plugin's entry alone instead of deleting it.
//
// Removal stays possible but must be DELIBERATE: `--prune` writes exactly this
// machine's set. A sync never prunes, so no unattended run can silently drop a
// plugin another machine still depends on.
//
// Enablement is deliberately NOT mirrored here: settings.json owns it. One
// record, one writer.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const LIVE = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'plugins');
const CHECK = process.argv.includes('--check');
const PRUNE = process.argv.includes('--prune');

function die(msg) { console.error(`refresh-plugin-manifests: ${msg}`); process.exit(1); }

function readLive(name) {
  const p = join(LIVE, name);
  if (!existsSync(p)) die(`${p} does not exist -- refusing to write a manifest from nothing`);
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch (e) { die(`${p} is not readable JSON (${e.message}) -- refusing rather than emptying the manifest`); }
}

// Sort keys so the output cannot depend on the live file's insertion order,
// which differs per machine by install history.
const sorted = (o, f) => Object.fromEntries(Object.keys(o).sort().map(k => [k, f(o[k])]));

const liveMk = readLive('known_marketplaces.json');
const liveIp = readLive('installed_plugins.json');

// `source` is the only machine-independent half: where the marketplace comes
// from. `installLocation` and `lastUpdated` are this machine's cache state.
const marketplaces = sorted(liveMk.marketplaces ?? liveMk, m => ({ source: m.source }));

// Each plugin maps to a list of installs, one per scope (user/project). Scope is
// the only field that describes the INSTALL rather than the cached copy of it.
const plugins = sorted(liveIp.plugins ?? {}, arr =>
  (Array.isArray(arr) ? arr : [arr]).map(i => ({ scope: i.scope })));

// Fail closed. An empty manifest is indistinguishable from "you have no plugins"
// and would silently delete the record of every one of them -- the same
// subtraction a derived list makes when its pattern stops matching.
if (Object.keys(marketplaces).length === 0) die('live known_marketplaces.json lists NO marketplaces -- refusing to write an empty manifest');
if (Object.keys(plugins).length === 0) die('live installed_plugins.json lists NO plugins -- refusing to write an empty manifest');

// Read what the repo already declares, so this machine can ADD to it without
// subtracting another machine's plugins. A repo file that is missing or is not
// readable JSON contributes nothing rather than aborting: the live side has
// already been validated and fail-closed above, so the worst case here is that
// this run declares only what this machine has -- which is the old behaviour,
// not a new failure.
function readRepoDecl(name, key) {
  const path = join(REPO, 'plugins', name);
  if (!existsSync(path)) return {};
  try {
    const d = JSON.parse(readFileSync(path, 'utf8'));
    const v = d[key];
    return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
  } catch { return {}; }
}

// Union, live winning on any key both sides have: the live record is the fresher
// description of an install this machine actually performed. Keys are re-sorted
// after merging so the result cannot depend on which side contributed them.
const union = (prev, live) =>
  PRUNE ? live
        : Object.fromEntries(Object.keys({ ...prev, ...live }).sort()
            .map(k => [k, live[k] ?? prev[k]]));

const out = {
  'known_marketplaces.json': {
    version: liveMk.version ?? 1,
    marketplaces: union(readRepoDecl('known_marketplaces.json', 'marketplaces'), marketplaces),
  },
  'installed_plugins.json': {
    version: liveIp.version ?? 1,
    plugins: union(readRepoDecl('installed_plugins.json', 'plugins'), plugins),
  },
};

let changed = 0;
for (const [name, data] of Object.entries(out)) {
  const path = join(REPO, 'plugins', name);
  const text = JSON.stringify(data, null, 2) + '\n';
  const prev = existsSync(path) ? readFileSync(path, 'utf8') : null;
  if (prev === text) continue;
  changed++;
  if (CHECK) { console.error(`refresh-plugin-manifests: plugins/${name} is STALE`); continue; }
  writeFileSync(path, text);
  console.log(`refresh-plugin-manifests: rewrote plugins/${name}`);
}
if (CHECK && changed) process.exit(1);
if (CHECK) console.log('refresh-plugin-manifests: manifests match this machine');
