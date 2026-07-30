#!/usr/bin/env node
/**
 * build-traceability.mjs — SPEC-054 S0
 *
 * Fetches all PRs from the GitHub API and outputs a structured traceability
 * dataset at docs/assets/traceability.json.
 *
 * Environment variables:
 *   GITHUB_TOKEN           — required (provided automatically in Actions)
 *   GITHUB_REPOSITORY      — required, format "owner/repo"
 *   TRACEABILITY_OUTPUT_PATH — optional, default "docs/assets/traceability.json"
 *
 * No external dependencies — Node.js 18+ native fetch only.
 */

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

// ---------------------------------------------------------------------------
// Spec-ref extraction
// ---------------------------------------------------------------------------

const SPEC_REF_RE = /\b(SPEC-\d+|CAP-\d+(?:-F\d+)?)\b/gi;

/**
 * Extract all unique spec/capability refs from a text string.
 * Returns refs normalised to upper-case and deduplicated.
 *
 * @param {string | null | undefined} text
 * @returns {string[]}
 */
export function extractSpecRefs(text) {
  if (!text) return [];
  const seen = new Set();
  const matches = [...text.matchAll(SPEC_REF_RE)].map((m) => m[1].toUpperCase());
  for (const m of matches) seen.add(m);
  return [...seen];
}

// ---------------------------------------------------------------------------
// PR classification
// ---------------------------------------------------------------------------

/**
 * Classify a PR as 'traceable' or 'untraceable'.
 * A PR is traceable if any spec ref appears in its title, branch name, or body.
 *
 * @param {{ title: string; headRefName: string; body: string | null }} pr
 * @returns {'traceable' | 'untraceable'}
 */
export function classifyPR(pr) {
  const combined = [pr.title, pr.headRefName, pr.body ?? ''].join(' ');
  return extractSpecRefs(combined).length > 0 ? 'traceable' : 'untraceable';
}

// ---------------------------------------------------------------------------
// Data builder
// ---------------------------------------------------------------------------

/**
 * @typedef {{
 *   number: number;
 *   title: string;
 *   state: string;
 *   merged: boolean;
 *   headRefName: string;
 *   body: string | null;
 *   author: string;
 *   createdAt: string;
 *   mergedAt: string | null;
 *   url: string;
 * }} PRInput
 *
 * @typedef {{
 *   number: number;
 *   title: string;
 *   state: string;
 *   merged: boolean;
 *   headRefName: string;
 *   author: string;
 *   createdAt: string;
 *   mergedAt: string | null;
 *   url: string;
 *   specRefs: string[];
 *   classification: 'traceable' | 'untraceable';
 * }} PRRecord
 *
 * @typedef {{
 *   schemaVersion: string;
 *   generatedAt: string;
 *   stats: { total: number; traceable: number; untraceable: number; tracePercent: number };
 *   specs: Record<string, { prs: PRRecord[] }>;
 *   governanceGaps: PRRecord[];
 * }} TraceabilityData
 */

/**
 * Build the full traceability dataset from a list of PRs.
 *
 * @param {PRInput[]} prs
 * @returns {TraceabilityData}
 */
export function buildTraceabilityData(prs) {
  /** @type {Record<string, { prs: PRRecord[] }>} */
  const specs = {};
  /** @type {PRRecord[]} */
  const governanceGaps = [];

  for (const pr of prs) {
    const combined = [pr.title, pr.headRefName, pr.body ?? ''].join(' ');
    const specRefs = extractSpecRefs(combined);
    const classification = specRefs.length > 0 ? 'traceable' : 'untraceable';
    /** @type {PRRecord} */
    const record = {
      number: pr.number,
      title: pr.title,
      state: pr.state,
      merged: pr.merged,
      headRefName: pr.headRefName,
      author: pr.author,
      createdAt: pr.createdAt,
      mergedAt: pr.mergedAt,
      url: pr.url,
      specRefs,
      classification,
    };

    if (classification === 'untraceable') {
      governanceGaps.push(record);
    } else {
      for (const ref of specRefs) {
        if (!specs[ref]) specs[ref] = { prs: [] };
        specs[ref].prs.push(record);
      }
    }
  }

  const total = prs.length;
  const traceable = prs.filter((p) => classifyPR(p) === 'traceable').length;
  const untraceable = total - traceable;
  const tracePercent = total === 0 ? 0 : Math.round((traceable / total) * 100);

  return {
    schemaVersion: '1',
    generatedAt: new Date().toISOString(),
    stats: { total, traceable, untraceable, tracePercent },
    specs,
    governanceGaps,
  };
}

// ---------------------------------------------------------------------------
// GitHub API client
// ---------------------------------------------------------------------------

/**
 * Fetch all PRs (all states) from a GitHub repo, paginated.
 *
 * @param {string} repo  format "owner/repo"
 * @param {string} token
 * @returns {Promise<PRInput[]>}
 */
async function fetchAllPRs(repo, token) {
  const prs = [];
  let page = 1;
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  while (true) {
    const url = `https://api.github.com/repos/${repo}/pulls?state=all&per_page=100&page=${page}`;
    const res = await fetch(url, { headers });
    if (!res.ok) {
      throw new Error(`GitHub API error ${res.status} fetching PRs page ${page}: ${await res.text()}`);
    }
    const batch = /** @type {any[]} */ (await res.json());
    if (batch.length === 0) break;
    for (const pr of batch) {
      prs.push({
        number: pr.number,
        title: pr.title ?? '',
        state: pr.state,
        merged: !!pr.merged_at,
        headRefName: pr.head?.ref ?? '',
        body: pr.body ?? '',
        author: pr.user?.login ?? 'unknown',
        createdAt: pr.created_at,
        mergedAt: pr.merged_at ?? null,
        url: pr.html_url,
      });
    }
    page++;
  }
  return prs;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const token = process.env.GITHUB_TOKEN;
  const repo = process.env.GITHUB_REPOSITORY;
  const outputPath = process.env.TRACEABILITY_OUTPUT_PATH ?? 'docs/assets/traceability.json';

  if (!token) throw new Error('GITHUB_TOKEN is required');
  if (!repo) throw new Error('GITHUB_REPOSITORY is required (format: owner/repo)');

  console.error(`[traceability] Fetching PRs for ${repo}…`);
  const prs = await fetchAllPRs(repo, token);
  console.error(`[traceability] Fetched ${prs.length} PRs`);

  const data = buildTraceabilityData(prs);
  console.error(
    `[traceability] Stats: ${data.stats.traceable}/${data.stats.total} traceable (${data.stats.tracePercent}%). ${data.governanceGaps.length} governance gaps.`,
  );

  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, JSON.stringify(data, null, 2));
  console.error(`[traceability] Wrote ${outputPath}`);
}

const isMain =
  typeof process.argv[1] === 'string' &&
  new URL(import.meta.url).pathname.replace(/\\/g, '/').endsWith(
    process.argv[1].replace(/\\/g, '/').replace(/^.*\//, ''),
  );

if (isMain) {
  main().catch((err) => {
    console.error('[traceability] Fatal:', err);
    process.exit(1);
  });
}
