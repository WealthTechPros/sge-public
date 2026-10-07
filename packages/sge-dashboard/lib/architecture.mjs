/**
 * Architecture artefact (SPEC-131, #2922): parse docs/sgd-build/architecture.yaml,
 * check it against the capability model and the repo's code paths, and draw it
 * as a mermaid diagram.
 *
 * Shared by three callers so they can never disagree about the format:
 *   - scripts/build-sge-dag.mjs (component DAG nodes, edges and findings)
 *   - lib/build-dashboard.mjs (the dashboard's Architecture section)
 *   - scripts/check-architecture.mjs (the sge-align C41 check)
 *
 * Node built-ins only, like every generator in scripts/ (SPEC-062). The parser
 * reads the fixed shape SPEC-131 §2.1 defines; it is not a general YAML parser.
 *
 *   version: 1
 *   components:
 *     - id: COMP-API
 *       name: Public REST API
 *       realises: [CAP-ORDERS]        # flow list, or one "- CAP-ORDERS" per line
 *       paths: [src/api/]
 *       dependsOn: [COMP-DB]          # optional
 *
 * A "#" starts a comment only outside quotes, and a block list may sit at the
 * same indent as its key (SPEC-133 S12, #2923).
 */
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";

export const ARCHITECTURE_FILE = "docs/sgd-build/architecture.yaml";

// Capability-model locations, in the order a consuming repo is searched (C41).
const MODEL_FILES = [
  "docs/sgd-build/capability-model.yaml",
  ".claude/product-context/capability-model.yaml",
  "docs/capability-model.yaml",
];

const LIST_KEYS = new Set(["realises", "paths", "dependsOn"]);

const unquote = (s) => s.trim().replace(/^(["'])(.*)\1$/, "$2").trim();

/**
 * Drop a YAML comment from a line: a "#" at the start of the line or after
 * whitespace, outside single or double quotes (SPEC-133 S12, #2923). A "#"
 * inside a quoted value ("Step #2") is part of the value.
 */
export function stripComment(line) {
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (ch === "\\" && quote === '"') i++;
      else if (ch === quote) quote = null;
    } else if (ch === '"' || ch === "'") {
      // A quote opens a quoted scalar only where one can start, so the
      // apostrophe in an unquoted "don't" is plain text.
      if (i === 0 || /[\s:,[{]/.test(line[i - 1])) quote = ch;
    } else if (ch === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
      return line.slice(0, i).replace(/\s+$/, "");
    }
  }
  return line;
}

/** Split a flow list "[a, 'b, c']" on the commas outside quotes. */
const flowList = (v) => {
  const inner = v.trim().replace(/^\[/, "").replace(/\]$/, "");
  const out = [];
  let cur = "";
  let quote = null;
  for (const ch of inner) {
    if (quote) {
      if (ch === quote) quote = null;
    } else if (ch === '"' || ch === "'") quote = ch;
    else if (ch === ",") {
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out.map(unquote).filter(Boolean);
};

/**
 * Parse the artefact text. Never throws: lines it cannot place are reported in
 * `errors` (each becomes an architecture-invalid finding).
 * @returns {{ version: string|null, components: object[], errors: string[] }}
 */
export function parseArchitecture(text) {
  const components = [];
  const errors = [];
  let version = null;
  let inComponents = false;
  let cur = null;
  let listKey = null; // a block list being read ("realises:" followed by "- x" lines)

  const lines = String(text).replace(/\r\n?/g, "\n").split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = stripComment(lines[i]);
    if (!line.trim()) continue;
    const indent = line.match(/^ */)[0].length;
    const body = line.trim();

    // The component list may sit at the same indent as "components:" (valid
    // YAML, SPEC-133 S12): inside components, a column-0 "- " line is an item.
    if (indent === 0 && !(inComponents && /^-\s/.test(body))) {
      listKey = null;
      cur = null;
      const top = body.match(/^([A-Za-z_]+):\s*(.*)$/);
      if (top && top[1] === "version") version = unquote(top[2]);
      inComponents = !!top && top[1] === "components";
      if (!top) errors.push(`line ${i + 1}: unrecognised top-level line "${body}"`);
      continue;
    }
    if (!inComponents) continue;

    const item = body.match(/^-\s+id:\s*(.*)$/);
    if (item && indent <= 2) {
      cur = { id: unquote(item[1]), name: null, realises: [], paths: [], dependsOn: [] };
      components.push(cur);
      listKey = null;
      continue;
    }
    if (!cur) {
      errors.push(`line ${i + 1}: component entries must start with "- id:"`);
      continue;
    }
    const blockItem = body.match(/^-\s+(.*)$/);
    if (blockItem && listKey) {
      cur[listKey].push(unquote(blockItem[1]));
      continue;
    }
    const kv = body.match(/^([A-Za-z_]+):\s*(.*)$/);
    if (!kv) {
      errors.push(`line ${i + 1}: ${cur.id}: unrecognised line "${body}"`);
      continue;
    }
    const [, key, value] = kv;
    listKey = null;
    if (key === "name") cur.name = unquote(value) || null;
    else if (LIST_KEYS.has(key)) {
      if (value === "") listKey = key;
      else cur[key] = value.startsWith("[") ? flowList(value) : [unquote(value)];
    }
    // Other keys (description, owner, ...) are allowed and ignored.
  }
  return { version, components, errors };
}

const GLOB = /[*?[\]{}]/;

/**
 * Apply SPEC-131 §2.1 rules A1-A7, plus A8 from SPEC-133 (a component id
 * must not reuse an existing DAG node id). Every finding is a warning.
 * @param {{components: object[], errors?: string[]}} arch
 * @param {{capabilityIds: Set<string>|null, pathExists: (p: string) => boolean, nodeIds?: Set<string>|null}} ctx
 *   capabilityIds null = no capability model, so rule A4 is skipped.
 *   nodeIds null (the default) = no DAG in scope, so rule A8 is skipped.
 */
export function architectureFindings(arch, { capabilityIds, pathExists, nodeIds = null }) {
  const findings = [];
  const add = (kind, subject, detail) => findings.push({ kind, severity: "warning", subject, detail });
  for (const e of arch.errors || []) add("architecture-invalid", ARCHITECTURE_FILE, e);

  const ids = new Set();
  const declared = new Set(arch.components.map((c) => c.id));
  for (const c of arch.components) {
    if (!c.id) {
      add("architecture-invalid", ARCHITECTURE_FILE, "a component has an empty id");
      continue;
    }
    if (ids.has(c.id)) add("architecture-invalid", c.id, `duplicate component id ${c.id}`);
    ids.add(c.id);
    // Rule A8 (SPEC-133 S12): a component id must not reuse the id of a node
    // the DAG already has (a capability, feature, spec or the vision).
    if (nodeIds && nodeIds.has(c.id))
      add("architecture-invalid", c.id, `component id ${c.id} reuses the id of an existing DAG node`);
    if (!c.name) add("architecture-invalid", c.id, "component has no name");

    if (!c.realises.length) add("component-unmapped", c.id, "component realises no capability");
    else if (capabilityIds) {
      for (const cap of c.realises) {
        if (!capabilityIds.has(cap))
          add("component-unknown-capability", c.id, `realises ${cap}, which the capability model does not declare`);
      }
    }

    if (!c.paths.length) add("component-missing-path", c.id, "component declares no code paths");
    for (const p of c.paths) {
      if (p.startsWith("/") || p.split(/[\\/]/).includes("..") || GLOB.test(p)) {
        add("architecture-invalid", c.id, `path ${p} must be repo-relative, with no "..", no leading "/" and no glob`);
      } else if (!pathExists(p)) {
        add("component-missing-path", c.id, `code path ${p} does not exist`);
      }
    }

    for (const d of c.dependsOn) {
      if (!declared.has(d)) add("architecture-invalid", c.id, `dependsOn ${d}, which is not a component in this file`);
    }
  }
  return findings;
}

const mid = (id) => String(id).replace(/[^A-Za-z0-9]/g, "_");
const label = (s) => String(s).replace(/"/g, "#quot;");

/**
 * Mermaid flowchart for the components: one box per component, a dashed
 * "realises" arrow to each capability, a solid arrow per dependsOn.
 * @param {object[]} components
 * @param {Record<string,string>} [capNames] capability id -> name, for labels
 */
export function architectureMermaid(components, capNames = {}) {
  const L = ["flowchart LR"];
  const ids = new Set(components.map((c) => c.id));
  for (const c of components) L.push(`  ${mid(c.id)}["${label(c.name || c.id)}"]`);
  const caps = [...new Set(components.flatMap((c) => c.realises))];
  for (const cap of caps) {
    const name = capNames[cap];
    L.push(`  ${mid(cap)}(["${label(name ? `${cap}: ${name}` : cap)}"])`);
  }
  for (const c of components) {
    for (const cap of c.realises) L.push(`  ${mid(c.id)} -.->|realises| ${mid(cap)}`);
    for (const d of c.dependsOn) if (ids.has(d)) L.push(`  ${mid(c.id)} --> ${mid(d)}`);
  }
  return L.join("\n");
}

/** Read and parse the artefact under `root`; null when the file is absent. */
export function loadArchitecture(root, file = ARCHITECTURE_FILE) {
  const p = path.join(root, file);
  return existsSync(p) ? parseArchitecture(readFileSync(p, "utf8")) : null;
}

/**
 * Every id a capability-model file declares with an `id:` key, in any shape
 * (SPEC-131 §2.3: looser than the sge model parser, never wrong about a declared
 * id). null when no model is found.
 */
export function declaredModelIds(root) {
  for (const rel of MODEL_FILES) {
    const p = path.join(root, rel);
    if (!existsSync(p)) continue;
    const ids = new Set();
    for (const m of readFileSync(p, "utf8").matchAll(/(?:^|[\s{,-])id:\s*["']?([A-Za-z0-9_.-]+)/gm)) ids.add(m[1]);
    return ids;
  }
  return null;
}

/**
 * The C41 check (SPEC-131 §2.5): warn-first architecture drift for a repo.
 * @returns {{check: "C41", applicable: boolean, reason?: string, findings: object[]}}
 */
export function checkArchitecture(root, { file = ARCHITECTURE_FILE, capabilityIds } = {}) {
  const arch = loadArchitecture(root, file);
  if (!arch) {
    return { check: "C41", applicable: false, reason: `no ${file} in this repo (architecture not adopted yet)`, findings: [] };
  }
  const caps = capabilityIds === undefined ? declaredModelIds(root) : capabilityIds;
  const findings = architectureFindings(arch, {
    capabilityIds: caps,
    pathExists: (p) => existsSync(path.join(root, p)),
    // Rule A8 in a consuming repo: the ids its capability model declares.
    nodeIds: caps,
  }).map((f) => ({ check: "C41", ...f }));
  return { check: "C41", applicable: true, findings };
}
