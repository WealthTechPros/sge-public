#!/usr/bin/env node
// Standalone opt-in tracking, shipped with the public skill (no private hooks dependency).
import { existsSync, lstatSync, mkdirSync, readFileSync, readSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(import.meta.url);
const events = { sessionStart: 'start', agentStop: 'beat', sessionEnd: 'end' };
const mode = process.argv[2] ?? '--check';

function readSession() {
  try {
    const limit = 1048576;
    const buffer = Buffer.alloc(limit + 1);
    let size = 0;
    while (size <= limit) {
      const count = readSync(0, buffer, size, buffer.length - size, null);
      if (!count) break;
      size += count;
    }
    if (size > limit) return;
    const input = JSON.parse(buffer.subarray(0, size).toString('utf8'));
    const session = input?.sessionId ?? input?.session_id;
    if (typeof session !== 'string' || !/^[A-Za-z0-9._-]{1,128}$/.test(session)) return;
    if (input.sessionId !== undefined && input.session_id !== undefined && input.sessionId !== input.session_id) return;
    process.stdout.write(session);
  } catch {
    // Malformed payloads must not disclose content or break a Copilot session.
  }
}

function configure() {
  const windows = process.platform === 'win32';
  const executable = windows
    ? join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    : 'bash';
  const writer = join(dirname(script), `copilot-session-record.${windows ? 'ps1' : 'sh'}`);
  const definition = {
    version: 1,
    hooks: Object.fromEntries(Object.entries(events).map(([event, action]) => [event, [{
      type: 'command', exec: executable,
      args: windows
        ? ['-NoProfile', '-NonInteractive', '-File', writer, '-Event', action, '-HookInput']
        : [writer, action, '--hook-input'],
      timeoutSec: 15,
    }]])),
  };
  const rendered = `${JSON.stringify(definition, null, 2)}\n`;
  if (mode === '--print') {
    process.stdout.write(rendered);
    return;
  }
  const directory = join(process.env.COPILOT_HOME || join(homedir(), '.copilot'), 'hooks');
  const target = join(directory, 'sge-copilot-reaper.json');
  if (existsSync(directory) && lstatSync(directory).isSymbolicLink()) {
    throw new Error('Hooks directory is a link; refusing to read or write it.');
  }
  let matches = false;
  if (existsSync(target)) {
    if (!lstatSync(target).isFile() || lstatSync(target).isSymbolicLink()) {
      throw new Error('Hook target is not a regular file; leaving it untouched.');
    }
    matches = JSON.stringify(JSON.parse(readFileSync(target, 'utf8'))) === JSON.stringify(definition);
    if (!matches) throw new Error('Hook file differs from this preview; review it manually. Nothing overwritten.');
  }
  if (mode === '--check') {
    console.log(matches
      ? 'Copilot reaper hook definition present (not proof it is loaded or producing records).'
      : 'Copilot reaper hooks not installed here. Preview with --print; --install is an explicit opt-in.');
    process.exitCode = matches ? 0 : 1;
    return;
  }
  if (matches) {
    console.log('Copilot reaper hook definition unchanged.');
    return;
  }
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  writeFileSync(target, rendered, { flag: 'wx', mode: 0o600 });
  console.log('Copilot reaper hook definition installed. Verify loading and record production in the intended session.');
}

if (mode === '--session-id' && process.argv.length === 3) {
  readSession();
} else if (['--check', '--print', '--install'].includes(mode) && process.argv.length <= 3) {
  try {
    configure();
  } catch {
    console.error('Copilot reaper hook setup could not be verified. Review the target file; nothing overwritten.');
    process.exitCode = 1;
  }
} else {
  console.error('Usage: node copilot-hooks.mjs [--check|--print|--install]');
  process.exitCode = 2;
}
