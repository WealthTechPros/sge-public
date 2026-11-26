import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const pathKey = value => {
  if (process.platform === 'win32' && /^\/[a-z]\//i.test(value)) value = `${value[1]}:${value.slice(2)}`;
  const result = path.resolve(value).replaceAll('\\', '/').replace(/\/$/, '');
  return process.platform === 'win32' ? result.toLowerCase() : result;
};

export function stateLocation(file) {
  const requested = path.resolve(file);
  let parent = path.dirname(requested);
  while (!fs.existsSync(parent)) parent = path.dirname(parent);
  const absolute = path.join(fs.realpathSync.native(parent), path.relative(parent, requested));
  if (absolute.split(/[\\/]/).some(part => /^(onedrive|sharepoint|dropbox|google drive|icloud|box sync)/i.test(part))) {
    throw new Error('state and reports must be outside synchronised folders');
  }
  for (const name of ['OneDrive', 'OneDriveCommercial', 'OneDriveConsumer']) {
    if (process.env[name] && pathKey(absolute).toLowerCase().startsWith(`${pathKey(process.env[name]).toLowerCase()}/`)) {
      throw new Error('state and reports must be outside synchronised folders');
    }
  }
  if (fs.existsSync(requested) && (fs.lstatSync(requested).isSymbolicLink() || !fs.lstatSync(requested).isFile())) {
    throw new Error('state must be a regular, non-linked file');
  }
  parent = path.dirname(absolute);
  while (!fs.existsSync(parent)) parent = path.dirname(parent);
  const git = spawnSync('git', ['-C', parent, 'rev-parse', '--is-inside-work-tree'], { encoding: 'utf8' });
  if (git.status === 0 && git.stdout.trim() === 'true') throw new Error('state must be outside versioned source');
  return absolute;
}
