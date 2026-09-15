#!/usr/bin/env node
// compaction-window.mjs — the ONE place that knows how big the context window is
// and where the warning bands sit.
//
// WHY THIS EXISTS. `autoCompactWindow` used to be written down in five places: the
// setting itself, two threshold constants in context-watchdog.mjs, the prose of five
// of that hook's output strings, a line of CLAUDE.md, and a global memory. Raising the
// setting on 2026-09-15 would have left four of them asserting 200K while the session
// actually compacted near 334K — the drift class the user's constants directive names
// ("never inline a value that must agree across files"). Every consumer now derives
// from the setting at run time, so the setting is the only thing to change.
//
// THE SETTING IS A CONFIGURED VALUE, NOT THE TRIGGER. Measured 2026-09-14 over 5,660
// automatic compaction boundaries in ~/.claude + ~/.claude1: with autoCompactWindow at
// 200,000, 5,041 of them (89%) fired between 160K and 170K. The compactor therefore
// triggers at about 83.5% of the configured number, and every band has to be computed
// from the TRIGGER rather than from the setting.
//
// THE BAND FRACTIONS REPRODUCE THE OLD HAND-PICKED CONSTANTS. At the previous setting of
// 200,000 this derivation returns WARN 120K and URGENT 150K — byte-identical to the two
// literals it replaces. That is the check on the arithmetic: the refactor is provably a
// no-op at the old value, so the only behavioural change is the one the user asked for.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// Share of the configured window at which the compactor actually fires (measured above).
export const TRIGGER_FRACTION = 0.835;

// URGENT must land strictly before the boundary, because the durable-state sync it asks
// for is worth nothing if it lands after. WARN is the "think about the next boundary"
// band, far enough back that a task boundary is likely to arrive before the cliff.
export const URGENT_FRACTION = 0.90;
export const WARN_FRACTION = 0.72;

// The harness default when autoCompactWindow is unset is NOT published by Anthropic, and
// an agent measuring this corpus could not source one. 200,000 is used as the fallback
// because it is what this configuration ran for a month and is therefore the value whose
// behaviour is measured — it is a known quantity, not a guess at the harness default.
export const FALLBACK_WINDOW = 200_000;

const round10k = (n) => Math.round(n / 10_000) * 10_000;

export function settingsPath() {
  return join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'settings.json');
}

// Read autoCompactWindow, clamped to the documented legal range 100K–1M. A value outside
// that range is a typo the harness would reject anyway; falling back is safer than acting
// on a band computed from it.
export function configuredWindow(path = settingsPath()) {
  try {
    const v = JSON.parse(readFileSync(path, 'utf8')).autoCompactWindow;
    if (typeof v === 'number' && Number.isFinite(v) && v >= 100_000 && v <= 1_000_000) return v;
  } catch { /* unreadable settings must never break a hook */ }
  return FALLBACK_WINDOW;
}

export function bands(path = settingsPath()) {
  const configured = configuredWindow(path);
  const trigger = Math.round(configured * TRIGGER_FRACTION);
  return {
    configured,
    trigger,
    urgent: round10k(trigger * URGENT_FRACTION),
    warn: round10k(trigger * WARN_FRACTION),
    // Pre-formatted for prose, so no consumer hand-writes "200K" anywhere.
    configuredK: `${Math.round(configured / 1000)}K`,
    triggerK: `${Math.round(trigger / 1000)}K`,
  };
}
