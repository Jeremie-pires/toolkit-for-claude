// Tests for the dream reminder segment of global/statusline.js. Run: node --test
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const statusline = path.join(here, '..', 'global', 'statusline.js');
const repo = path.resolve(here, '..');
const DAY_MS = 24 * 60 * 60 * 1000;

// Runs the status line with a temporary home folder; returns line 1 without colors.
// With useConfigDir, the dream file goes to a folder named by CLAUDE_CONFIG_DIR instead of ~/.claude.
function line1(projectDir, dreamFile, { useConfigDir = false } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'statusline-home-'));
  try {
    fs.mkdirSync(path.join(home, '.claude'));
    const configDir = useConfigDir ? path.join(home, 'config') : path.join(home, '.claude');
    if (useConfigDir) fs.mkdirSync(configDir);
    if (dreamFile !== undefined) fs.writeFileSync(path.join(configDir, 'claude-kit-dream.json'), dreamFile);
    const env = { ...process.env, HOME: home, USERPROFILE: home };
    if (useConfigDir) env.CLAUDE_CONFIG_DIR = configDir;
    else delete env.CLAUDE_CONFIG_DIR;
    const res = spawnSync(process.execPath, [statusline], {
      input: JSON.stringify({ workspace: { project_dir: projectDir } }),
      encoding: 'utf8',
      env,
    });
    assert.equal(res.status, 0, res.stderr);
    return res.stdout.split('\n')[0].replace(/\x1b\[[0-9;]*m/g, '');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

const dreamedDaysAgo = (days, dir = repo) =>
  JSON.stringify({ [dir]: { lastDream: new Date(Date.now() - days * DAY_MS - 60000).toISOString() } });

test('7 days or less: nothing', () => {
  assert.doesNotMatch(line1(repo, dreamedDaysAgo(7)), /dream/);
});

test('8 to 25 days: dream Nd', () => {
  assert.match(line1(repo, dreamedDaysAgo(9)), /│ dream 9d$/);
  assert.match(line1(repo, dreamedDaysAgo(25)), /│ dream 25d$/);
});

test('past 25 days: dream Nd!', () => {
  assert.match(line1(repo, dreamedDaysAgo(27)), /│ dream 27d!$/);
});

test('never dreamed, missing or corrupt file: dream?', () => {
  assert.match(line1(repo, JSON.stringify({ '/other': { lastDream: new Date().toISOString() } })), /│ dream\?$/);
  assert.match(line1(repo), /│ dream\?$/);
  assert.match(line1(repo, '{broken'), /│ dream\?$/);
});

test('project path matches the record regardless of case on Windows', { skip: process.platform !== 'win32' }, () => {
  assert.doesNotMatch(line1(repo, dreamedDaysAgo(1, repo.toUpperCase())), /dream/);
});

test('CLAUDE_CONFIG_DIR: the record is read from that folder', () => {
  assert.match(line1(repo, dreamedDaysAgo(9), { useConfigDir: true }), /│ dream 9d$/);
});

test('non-git folders show nothing', () => {
  const plain = fs.mkdtempSync(path.join(os.tmpdir(), 'statusline-plain-'));
  try {
    assert.doesNotMatch(line1(plain), /dream/);
  } finally {
    fs.rmSync(plain, { recursive: true, force: true });
  }
});
