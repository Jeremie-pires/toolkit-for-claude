#!/usr/bin/env node
// Claude Code status line: one Node process per refresh, no external deps.
// Line 1: model | project | branch | caveman mode | kit sync warnings | days since the last /toolkit:dream
// Line 2: context bar | quota (5h/7d windows, or a spend limit when one is set) | session cost and duration
'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const R = '\x1b[0m';
const BOLD = '\x1b[1m';
const DIM = '\x1b[2m';
const C = {
  sky: '\x1b[96m', blue: '\x1b[34m', green: '\x1b[32m', yellow: '\x1b[33m',
  orange: '\x1b[38;5;208m', red: '\x1b[31m', cyan: '\x1b[36m', mag: '\x1b[35m', white: '\x1b[37m',
};
const SEP = `${DIM} │ ${R}`;

function readInput() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch {
    return {};
  }
}

function pctColor(p) {
  if (p < 20) return C.sky;
  if (p < 40) return C.blue;
  if (p < 60) return C.green;
  if (p < 75) return C.yellow;
  if (p < 80) return C.orange;
  return C.red;
}

function bar(p, width = 10) {
  const filled = Math.max(0, Math.min(width, Math.floor((p * width) / 100)));
  const col = pctColor(p);
  return `${col}${'▰'.repeat(filled)}${R}${DIM}${'▱'.repeat(width - filled)}${R}`;
}

function pct(label, value) {
  const p = Math.round(Number(value));
  const warn = p >= 80 ? ' ⚠️' : '';
  return `${label} ${bar(p)} ${pctColor(p)}${BOLD}${p}%${R}${warn}`;
}

function untilReset(epochSeconds) {
  const secs = Math.round(Number(epochSeconds) - Date.now() / 1000);
  if (!Number.isFinite(secs)) return '';
  if (secs <= 0) return 'now';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function gitBranch(dir) {
  try {
    return execFileSync('git', ['-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 500,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
    }).trim();
  } catch {
    return '';
  }
}

// Claude Code reads its config from CLAUDE_CONFIG_DIR when set, else ~/.claude
function claudeDir() {
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

function cavemanMode() {
  try {
    return fs.readFileSync(path.join(claudeDir(), '.caveman-active'), 'utf8').trim();
  } catch {
    return '';
  }
}

// bootstrap.ps1 records sync warnings here; surface them so a skipped update is not silent
function kitWarnings() {
  try {
    const state = JSON.parse(fs.readFileSync(path.join(claudeDir(), 'claude-kit-sync.json'), 'utf8'));
    return Array.isArray(state.warnings) ? state.warnings.length : 0;
  } catch {
    return 0;
  }
}

// Days since /toolkit:dream last ran for this project (claude-kit-dream.json), or null if never
function dreamAge(projectDir) {
  try {
    const records = JSON.parse(fs.readFileSync(path.join(claudeDir(), 'claude-kit-dream.json'), 'utf8'));
    const norm = (p) => (process.platform === 'win32' ? path.resolve(p).toLowerCase() : path.resolve(p));
    const key = Object.keys(records).find((k) => norm(k) === norm(projectDir));
    const last = Date.parse(records[key]?.lastDream);
    return Number.isNaN(last) ? null : Math.floor((Date.now() - last) / 86400000);
  } catch {
    return null;
  }
}

function dreamReminder(projectDir) {
  const age = dreamAge(projectDir);
  if (age === null) return `${C.white}dream?${R}`;
  if (age <= 7) return '';
  return age > 25 ? `${C.red}dream ${age}d!${R}` : `${C.orange}dream ${age}d${R}`;
}

function quota(limits) {
  if (!limits) return '';
  const parts = [];
  for (const [key, label] of [['five_hour', '5h'], ['seven_day', '7d']]) {
    const w = limits[key];
    if (w?.used_percentage == null) continue;
    const reset = w.resets_at ? ` ${DIM}(${untilReset(w.resets_at)})${R}` : '';
    parts.push(pct(`${C.yellow}${label}${R}`, w.used_percentage) + reset);
  }
  const s = limits.spend_limit;
  if (s?.used_percentage != null) {
    const usd = s.used_usd != null && s.limit_usd != null ? ` ${DIM}$${s.used_usd.toFixed(0)}/$${s.limit_usd.toFixed(0)}${R}` : '';
    parts.push(pct(`${C.yellow}spend${R}`, s.used_percentage) + usd);
  }
  return parts.join(SEP);
}

function session(cost) {
  if (!cost) return '';
  const usd = Number(cost.total_cost_usd ?? 0);
  const min = Math.floor(Number(cost.total_duration_ms ?? 0) / 60000);
  const time = min >= 60 ? `${Math.floor(min / 60)}h${String(min % 60).padStart(2, '0')}` : `${min}m`;
  return `${C.green}$${usd.toFixed(2)}${R} ${DIM}${time}${R}`;
}

const d = readInput();
const dir = d.workspace?.project_dir || d.workspace?.current_dir || d.cwd || process.cwd();
const branch = gitBranch(dir);
const mode = cavemanMode();
const kitWarn = kitWarnings();
// Only git projects get the reminder, so home or temp folders stay quiet
const dream = branch ? dreamReminder(dir) : '';

const line1 = [
  `${C.cyan}${BOLD}${d.model?.display_name || '?'}${R}`,
  `${C.mag}${path.basename(dir)}${R}`,
  branch && `${C.white}⎇ ${branch}${R}`,
  mode && mode !== 'off' && `${DIM}caveman:${mode}${R}`,
  kitWarn > 0 && `${C.orange}kit! (${kitWarn}, see ~/.claude/claude-kit-sync.json)${R}`,
  dream,
].filter(Boolean).join(SEP);

const used = d.context_window?.used_percentage;
const line2 = [
  used == null ? `${DIM}ctx —${R}` : pct(`${C.cyan}ctx${R}`, used),
  quota(d.rate_limits),
  session(d.cost),
].filter(Boolean).join(SEP);

process.stdout.write(`${line1}\n${line2}\n`);
