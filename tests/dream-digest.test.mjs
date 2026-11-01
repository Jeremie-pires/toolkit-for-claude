// Tests for plugins/toolkit/scripts/dream-digest.mjs. Run: node --test tests/
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  parseArgs, projectSlug, readTranscripts, extract, renderDigest, run, truncate, userText,
} from '../plugins/toolkit/scripts/dream-digest.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, '..', 'plugins', 'toolkit', 'scripts', 'dream-digest.mjs');
const fixtures = path.join(here, 'fixtures', 'transcripts');
const proj = path.join(fixtures, 'proj');
const since = new Date('2026-10-15T00:00:00Z');
const now = new Date('2026-11-01T00:00:00Z');

function digestOf(dir = proj) {
  const { sessions, stats } = readTranscripts(dir, since);
  return renderDigest({ project: '/x/kit', since, until: now, sessions, stats, found: extract(sessions) });
}

test('slug replaces every non-alphanumeric character', () => {
  const dir = process.platform === 'win32' ? 'C:\\Users\\me\\Code\\my_kit' : '/home/me/Code/my_kit';
  const expected = process.platform === 'win32' ? 'C--Users-me-Code-my-kit' : '-home-me-Code-my-kit';
  assert.equal(projectSlug(dir), expected);
});

test('arguments: overrides, bad date, unknown flag', () => {
  const args = parseArgs(['--transcripts', proj, '--since', '2026-10-15']);
  assert.equal(args.transcripts, proj);
  assert.equal(args.since.toISOString(), '2026-10-15T00:00:00.000Z');
  assert.throws(() => parseArgs(['--since', 'nope']), /ISO date/);
  assert.throws(() => parseArgs(['--since']), /needs a value/);
  assert.throws(() => parseArgs(['--bogus']), /unknown argument/);
});

test('user text skips meta, compact summaries and injected command text', () => {
  assert.equal(userText({ type: 'user', message: { content: 'hello' } }), 'hello');
  assert.equal(userText({ type: 'user', isMeta: true, message: { content: 'skill body' } }), null);
  assert.equal(userText({ type: 'user', isCompactSummary: true, message: { content: 'sum' } }), null);
  assert.equal(userText({ type: 'user', message: { content: '<command-name>/x</command-name>' } }), null);
  assert.equal(userText({ type: 'user', message: { content: [{ type: 'tool_result', content: 'ok' }] } }), null);
  assert.equal(userText({ type: 'assistant', message: { content: 'hi' } }), null);
});

test('window keeps recent records and orders sessions', () => {
  const { sessions } = readTranscripts(proj, since);
  assert.equal(sessions.length, 2);
  const { userMessages } = extract(sessions);
  assert.deepEqual(userMessages.map((m) => [m.tag, m.text]), [
    ['s1', 'Add a login page'],
    ['s1', 'non, utilise pnpm pas npm'],
    ['s2', 'Write the tests first'],
  ]);
});

test('unknown types and malformed lines are counted, not fatal', () => {
  const { stats } = readTranscripts(proj, since);
  assert.equal(stats.skippedTypes.get('future-record'), 2);
  assert.equal(stats.malformed, 2);
  assert.match(digestOf(), /2 skipped \(1 unknown types\) · 2 malformed lines/);
});

test('digest drops thinking, assistant text, images and old messages', () => {
  const digest = digestOf();
  assert.match(digest, /^# Dream digest: kit$/m);
  assert.match(digest, /- \[2026-10-20 s1\] "Add a login page"/);
  for (const dropped of ['secret plan', 'I will use npm', 'AAAA', 'old message', 'Read AI_STATE']) {
    assert.doesNotMatch(digest, new RegExp(dropped));
  }
});

test('items are truncated and flattened', () => {
  assert.equal(truncate('a\n  b'), 'a b');
  assert.equal(truncate('x'.repeat(400)).length, 300);
});

test('run writes the digest to the temp folder', () => {
  const { code, message } = run(['--transcripts', proj, '--since', '2026-10-15', '--project', '/x/kit'], now);
  assert.equal(code, 0);
  assert.equal(path.dirname(message), os.tmpdir());
  assert.match(fs.readFileSync(message, 'utf8'), /Add a login page/);
  fs.unlinkSync(message);
});

test('exit code 2 when the folder is missing or has nothing readable', () => {
  const missing = spawnSync(process.execPath, [script, '--transcripts', path.join(fixtures, 'nope')], { encoding: 'utf8' });
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /No transcript folder/);
  const empty = spawnSync(process.execPath, [script, '--transcripts', path.join(fixtures, 'empty')], { encoding: 'utf8' });
  assert.equal(empty.status, 2);
  assert.match(empty.stderr, /No readable transcript record/);
});
