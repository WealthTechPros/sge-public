/**
 * artefact-schemas.mjs — validate SGE artefacts against the JSON Schemas in
 * docs/schemas/ (SPEC-133, #2923).
 *
 * One module, three callers, so they can never disagree:
 *   - scripts/build-sge-dag.mjs adds each violation to docs/sge-dag.json as a
 *     `schema-violation` warning finding; `--strict` makes the build exit 1.
 *   - scripts/check-artefact-schemas.mjs is the /sge:sge-align C42 check.
 *   - scripts/build-sge-digest.mjs reads the capability model through
 *     parseCapabilityModel (re-exported by build-sge-dag.mjs).
 *
 * Node built-ins only, like every generator in scripts/ (SPEC-062). That rules
 * out a JSON Schema library and a YAML library, so this file carries:
 *   - validateSchema: the draft-07 subset the five schemas use (type, const,
 *     enum, pattern, minLength, required, properties, additionalProperties,
 *     items, minItems, local $ref), plus two SGE keywords handled by
 *     validateArtefacts: x-sge-sections and x-sge-idMatchesFilename;
 *   - parseYamlLite: the YAML subset SGE frontmatter uses (block mappings and
 *     sequences, flow lists and maps, quoted scalars, block scalars, comments);
 *   - readCapabilityModel: the fixed-indent capability-model line parser the
 *     DAG has always used, moved here so it can be shared.
 * The architecture artefact keeps its own parser (SPEC-131), imported below.
 */
import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadArchitecture, stripComment } from "../packages/sge-dashboard/lib/architecture.mjs";

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
export const SCHEMA_DIR = path.join(MODULE_DIR, "..", "docs", "schemas");

/** Artefact kind -> schema file in docs/schemas/. */
export const SCHEMA_FILES = {
  vision: "vision.schema.json",
  "capability-model": "capability-model.schema.json",
  spec: "spec.schema.json",
  adr: "adr.schema.json",
  architecture: "architecture.schema.json",
};

/** Where each artefact lives, in the order a repo is searched. */
export const VISION_FILES = ["docs/sgd-build/vision.md", "docs/vision.md"];
export const MODEL_FILES = [
  "docs/sgd-build/capability-model.yaml",
  ".claude/product-context/capability-model.yaml",
  "docs/capability-model.yaml",
];
export const SPEC_DIRS = ["docs/sgd-build/specs", "docs/specs", "docs/features"];
const ADR_DIRS = ["docs/decisions", "docs/adr"];
const ARCHITECTURE_FILE = "docs/sgd-build/architecture.yaml";
const SPEC_FILE_RE = /^(SPEC|SGD|SGE)-\d+.*\.md$/;
const SPEC_ID_RE = /^(?:SGE|SGD|SPEC)-\d+(?:-to-\d+)?/;
const ADR_FILE_RE = /^\d{4}-.*\.md$/;

export function loadSchemas(dir = SCHEMA_DIR) {
  const out = {};
  for (const [kind, file] of Object.entries(SCHEMA_FILES)) out[kind] = JSON.parse(readFileSync(path.join(dir, file), "utf8"));
  return out;
}

// ---------------------------------------------------------------------------
// JSON Schema (draft-07 subset)
// ---------------------------------------------------------------------------

const typeOf = (v) => (v === null ? "null" : Array.isArray(v) ? "array" : Number.isInteger(v) ? "integer" : typeof v);
const typeMatches = (want, v) => {
  const t = typeOf(v);
  return t === want || (want === "number" && t === "integer");
};
const show = (v) => JSON.stringify(v);

/**
 * Validate `value` against `schema`. Returns [{ field, message }], one per
 * violation; field is a path such as `domains[0].capabilities[1].id`
 * (empty string for the root).
 */
export function validateSchema(schema, value, field = "", root = schema) {
  const errors = [];
  const err = (f, message) => errors.push({ field: f, message });
  const join = (k) => (field ? `${field}.${k}` : k);

  if (schema.$ref) {
    const m = schema.$ref.match(/^#\/definitions\/(.+)$/);
    const target = m && root.definitions?.[m[1]];
    if (!target) return [{ field, message: `schema error: unresolvable $ref ${schema.$ref}` }];
    return validateSchema(target, value, field, root);
  }
  if ("const" in schema && value !== schema.const) {
    err(field, `is ${show(value)}, must be ${show(schema.const)}`);
    return errors;
  }
  if (schema.type) {
    const wants = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!wants.some((w) => typeMatches(w, value))) {
      err(field, `is ${typeOf(value)}, must be ${wants.join(" or ")}`);
      return errors;
    }
  }
  if (schema.enum && !schema.enum.includes(value)) err(field, `is ${show(value)}, must be one of ${schema.enum.join(", ")}`);
  if (typeof value === "string") {
    if (schema.minLength !== undefined && value.length < schema.minLength) err(field, `must not be empty`);
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) err(field, `is ${show(value)}, must match ${schema.pattern}`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) err(field, `must list at least ${schema.minItems} item(s)`);
    if (schema.items) value.forEach((v, i) => errors.push(...validateSchema(schema.items, v, `${field}[${i}]`, root)));
  }
  if (typeOf(value) === "object") {
    for (const k of schema.required || []) if (!(k in value)) err(join(k), `is required`);
    const props = schema.properties || {};
    for (const [k, v] of Object.entries(value)) {
      if (props[k]) errors.push(...validateSchema(props[k], v, join(k), root));
      else if (schema.additionalProperties === false) err(join(k), `is not allowed`);
      else if (typeof schema.additionalProperties === "object") {
        errors.push(...validateSchema(schema.additionalProperties, v, join(k), root));
      }
    }
  }
  return errors;
}

// ---------------------------------------------------------------------------
// YAML subset (frontmatter)
// ---------------------------------------------------------------------------

// The plain key body ends on a non-space, non-colon character, so it cannot
// overlap the \s* before the colon (no quadratic backtracking, PR #2955).
const KEY_RE = /^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s"'#\-[{:](?:[^:]*[^\s:])?|-[^\s:](?:[^:]*[^\s:])?)\s*:(?:\s+(.*))?$/;
/** KEY_RE, tried only on a line that has a colon at all. */
const matchKey = (b) => (b.includes(":") ? b.match(KEY_RE) : null);

function unquoteScalar(s) {
  if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
    return s.slice(1, -1).replace(/\\(["\\/nt])/g, (_, c) => ({ n: "\n", t: "\t" })[c] ?? c);
  }
  if (s.startsWith("'") && s.endsWith("'") && s.length >= 2) return s.slice(1, -1).replace(/''/g, "'");
  return s;
}

/** A plain or quoted scalar, YAML 1.2 core-schema typed. */
function scalar(raw) {
  const s = raw.trim();
  if (/^["']/.test(s)) return unquoteScalar(s);
  if (s === "" || s === "~" || s === "null" || s === "Null" || s === "NULL") return null;
  if (/^(true|True|TRUE)$/.test(s)) return true;
  if (/^(false|False|FALSE)$/.test(s)) return false;
  if (/^[-+]?\d+$/.test(s)) return Number(s);
  if (/^[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?$/.test(s)) return Number(s);
  return s;
}

/** Parse a flow collection ("[a, b]" or "{k: v}"); null when it is malformed. */
function parseFlow(s) {
  let i = 0;
  const ws = () => {
    while (i < s.length && /\s/.test(s[i])) i++;
  };
  const atom = (stops) => {
    ws();
    if (s[i] === "[" || s[i] === "{") return node();
    if (s[i] === '"' || s[i] === "'") {
      const q = s[i];
      let j = i + 1;
      while (j < s.length && !(s[j] === q && s[j - 1] !== "\\")) j++;
      const out = unquoteScalar(s.slice(i, j + 1));
      i = j + 1;
      return out;
    }
    let j = i;
    while (j < s.length && !stops.includes(s[j])) j++;
    const out = scalar(s.slice(i, j));
    i = j;
    return out;
  };
  const node = () => {
    const open = s[i++];
    const close = open === "[" ? "]" : "}";
    const out = open === "[" ? [] : {};
    ws();
    if (s[i] === close) {
      i++;
      return out;
    }
    for (;;) {
      if (open === "[") out.push(atom([",", "]"]));
      else {
        const k = atom([":", ",", "}"]);
        ws();
        if (s[i] !== ":") throw new Error("flow map entry without ':'");
        i++;
        out[String(k)] = atom([",", "}"]);
      }
      ws();
      if (s[i] === ",") {
        i++;
        continue;
      }
      if (s[i] === close) {
        i++;
        return out;
      }
      throw new Error(`unexpected ${s[i] ?? "end of text"}`);
    }
  };
  try {
    const out = node();
    ws();
    return i === s.length ? { value: out } : null;
  } catch {
    return null;
  }
}

/**
 * Parse the YAML subset SGE frontmatter uses. Never throws: a line it cannot
 * place is reported in `errors` (`line N: ...`) and skipped.
 * @returns {{ value: any, errors: string[] }}
 */
export function parseYamlLite(text) {
  const raw = String(text).replace(/\r\n?/g, "\n").split("\n");
  const errors = [];
  let i = 0;
  const indentOf = (l) => l.match(/^ */)[0].length;
  const body = (l) => stripComment(l).trim();
  const skippable = (l) => body(l) === "";
  const skip = () => {
    while (i < raw.length && skippable(raw[i])) i++;
  };
  const isSeqLine = (b) => b === "-" || b.startsWith("- ");

  function blockScalar(indicator, parentIndent) {
    const lines = [];
    while (i < raw.length && (raw[i].trim() === "" || indentOf(raw[i]) > parentIndent)) lines.push(raw[i++]);
    while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
    const ind = lines.reduce((m, l) => (l.trim() ? Math.min(m, indentOf(l)) : m), Infinity);
    const content = lines.map((l) => l.slice(Number.isFinite(ind) ? ind : 0));
    const text = indicator.startsWith(">") ? content.join(" ").replace(/ {2,}/g, " ") : content.join("\n");
    if (!content.length) return "";
    return indicator.includes("-") ? text : text + "\n";
  }

  function value(rest, parentIndent, lineNo) {
    if (rest === "") {
      skip();
      if (i < raw.length) {
        const ind = indentOf(raw[i]);
        if (ind > parentIndent) return block(ind);
        if (ind === parentIndent && isSeqLine(body(raw[i]))) return seq(ind);
      }
      return null;
    }
    if (/^[|>][-+]?\d*$/.test(rest)) return blockScalar(rest, parentIndent);
    if (rest.startsWith("[") || rest.startsWith("{")) {
      const f = parseFlow(rest);
      if (f) return f.value;
      errors.push(`line ${lineNo}: malformed flow collection ${rest}`);
      return rest;
    }
    // A quoted scalar may run over several lines; a plain one may continue
    // on more-indented lines.
    let v = rest;
    const q = v[0];
    if ((q === '"' || q === "'") && !(v.length > 1 && v.endsWith(q))) {
      while (i < raw.length) {
        v += " " + raw[i++].trim();
        if (v.endsWith(q)) break;
      }
    } else if (q !== '"' && q !== "'") {
      while (i < raw.length && !skippable(raw[i]) && indentOf(raw[i]) > parentIndent && !matchKey(body(raw[i])) && !isSeqLine(body(raw[i]))) {
        v += " " + body(raw[i++]);
      }
    }
    return scalar(v);
  }

  function map(ind, into = {}) {
    for (;;) {
      skip();
      if (i >= raw.length) return into;
      const li = indentOf(raw[i]);
      const b = body(raw[i]);
      if (li < ind || (li === ind && isSeqLine(b))) return into;
      if (li > ind) {
        errors.push(`line ${i + 1}: unexpected indentation "${b}"`);
        i++;
        continue;
      }
      const m = matchKey(b);
      if (!m) {
        errors.push(`line ${i + 1}: expected "key: value", got "${b}"`);
        i++;
        continue;
      }
      const lineNo = ++i;
      into[unquoteScalar(m[1].trim())] = value((m[2] ?? "").trim(), ind, lineNo);
    }
  }

  function seq(ind) {
    const out = [];
    for (;;) {
      skip();
      if (i >= raw.length) return out;
      const li = indentOf(raw[i]);
      const b = body(raw[i]);
      if (li !== ind || !isSeqLine(b)) {
        if (li > ind) {
          errors.push(`line ${i + 1}: unexpected indentation "${b}"`);
          i++;
          continue;
        }
        return out;
      }
      const rest = b === "-" ? "" : b.slice(2).trim();
      const lineNo = ++i;
      const m = matchKey(rest);
      if (m && !/^["'[{]/.test(rest)) {
        // "- key: value" opens a mapping whose further keys align with "key".
        const itemIndent = li + (b.length - rest.length);
        const obj = {};
        obj[unquoteScalar(m[1].trim())] = value((m[2] ?? "").trim(), itemIndent, lineNo);
        skip();
        if (i < raw.length && indentOf(raw[i]) === itemIndent && !isSeqLine(body(raw[i]))) map(itemIndent, obj);
        out.push(obj);
      } else out.push(value(rest, li, lineNo));
    }
  }

  function block(ind) {
    skip();
    if (i >= raw.length) return null;
    return isSeqLine(body(raw[i])) ? seq(ind) : map(ind);
  }

  skip();
  const out = i < raw.length ? block(indentOf(raw[i])) : null;
  skip();
  while (i < raw.length) {
    errors.push(`line ${i + 1}: unparsed "${body(raw[i])}"`);
    i++;
    skip();
  }
  return { value: out, errors };
}

/**
 * The frontmatter of a markdown artefact: YAML between --- lines at the top of
 * the file (style "dashes"), or a ```yaml code block that is the first thing in
 * the file (style "codeblock"). null when there is neither.
 * @returns {{ style: "dashes"|"codeblock", data: any, errors: string[] } | null}
 */
export function extractFrontmatter(text) {
  const t = String(text).replace(/^﻿/, "").replace(/\r\n?/g, "\n");
  let m = t.match(/^---\n([\s\S]*?)\n---[ \t]*(?:\n|$)/);
  if (m) return { style: "dashes", ...toData(parseYamlLite(m[1])) };
  m = t.match(/^\s*```ya?ml\n([\s\S]*?)\n```/);
  if (m) return { style: "codeblock", ...toData(parseYamlLite(m[1])) };
  return null;
}
const toData = ({ value, errors }) => ({ data: value, errors });

// ---------------------------------------------------------------------------
// Capability model (fixed-indent line parser, shared with build-sge-dag.mjs)
// ---------------------------------------------------------------------------

// Indentation is fixed at 2 spaces per nesting level: domain items at 2sp,
// their `name:` at 4sp; capability items at 6sp, their `name:` at 8sp;
// feature flow-mappings at 10sp. A structural change to the file's indentation
// would need this parser updated alongside it.
const DOMAIN_ID_RE = /^ {2}- id:\s*(\S+)\s*$/;
const DOMAIN_NAME_RE = /^ {4}name:(.*\S)/;
const CAP_ID_RE = /^ {6}- id:\s*(\S+)\s*$/;
const CAP_NAME_RE = /^ {8}name:(.*\S)/;
// Positional: id, name, mvp, status, spec (fixed field order). A trailing
// `# comment` is stripped first. A name may contain commas, which is why this
// is a positional regex and not a YAML flow-map parse. spec is one token, a
// quoted token or a [list], and nothing may follow it, so an extra field
// ("spec: SPEC-1, backdoor: true") fails the match instead of being absorbed
// into spec (PR #2955).
const FEATURE_RE =
  /^ {10}- \{ *id: *([^\s,]+), *name: *([^,].*?), *mvp: *(true|false), *status: *([^\s,}]+), *spec: *(\[[^\]]*\]|"[^"]*"|[^\s,{}[\]]+) *\} *$/;
// Every "- " item of a features list sits at 10 spaces. One that is not the
// strict FEATURE_RE shape is reported, whatever it starts with.
const FEATURE_ITEM_RE = /^ {10}-( |$)/;
const FEATURES_KEY_RE = /^ {8}features:/;
const VERSION_RE = /^version:(.*\S)/;

/**
 * Read the capability model as written: a name is present only when the file
 * has a `name:` line, and a feature-shaped line the regex cannot read is
 * listed in `unparsed` (each one is a schema violation).
 * @returns {{ version: string|null, domains: object[], unparsed: {line: number, text: string}[] }}
 */
export function readCapabilityModel(text) {
  const domains = [];
  const unparsed = [];
  let version = null;
  let curDomain = null;
  let curCap = null;
  let inFeatures = false; // inside a capability's "features:" list
  const lines = String(text).replace(/\r\n?/g, "\n").split("\n");
  lines.forEach((rawLine, idx) => {
    // strip `# comment` (not inside a { } flow-map); only a line with a "#" pays for it
    const line = rawLine.includes("#") ? rawLine.replace(/\s*#(?![^{]*\}).*$/, "") : rawLine;
    const v = line.match(VERSION_RE);
    if (v) {
      version = v[1].trim().replace(/^(["'])(.*)\1$/, "$2");
      return;
    }
    const d = line.match(DOMAIN_ID_RE);
    if (d) {
      curDomain = { id: d[1], capabilities: [] };
      domains.push(curDomain);
      curCap = null;
      inFeatures = false;
      return;
    }
    const dn = line.match(DOMAIN_NAME_RE);
    if (dn && curDomain) {
      curDomain.name = dn[1].trim();
      return;
    }
    const c = line.match(CAP_ID_RE);
    if (c && curDomain) {
      curCap = { id: c[1], features: [] };
      curDomain.capabilities.push(curCap);
      inFeatures = false;
      return;
    }
    const cn = line.match(CAP_NAME_RE);
    if (cn && curCap) {
      curCap.name = cn[1].trim();
      return;
    }
    if (FEATURES_KEY_RE.test(line)) {
      inFeatures = !!curCap;
      return;
    }
    const f = line.match(FEATURE_RE);
    if (f && curCap) {
      curCap.features.push({ id: f[1], name: f[2].trim(), mvp: f[3] === "true", status: f[4], spec: f[5] });
      return;
    }
    // Any other item of a features list (an extra field, a block mapping, a
    // missing field) is reported, never dropped or half-read (PR #2955).
    if (FEATURE_ITEM_RE.test(line) && (inFeatures || /^ {10}- \{/.test(line))) {
      unparsed.push({ line: idx + 1, text: line.trim() });
      return;
    }
    if (/^ {0,9}\S/.test(line)) inFeatures = false; // a shallower key ends the list
  });
  return { version, domains, unparsed };
}

/**
 * The DAG generator's view of the model (unchanged since SPEC-062): a missing
 * name defaults to the id.
 */
export function parseCapabilityModel(text) {
  const { domains } = readCapabilityModel(text);
  return {
    domains: domains.map((d) => ({
      id: d.id,
      name: d.name ?? d.id,
      capabilities: d.capabilities.map((c) => ({ id: c.id, name: c.name ?? c.id, features: c.features })),
    })),
  };
}

// ---------------------------------------------------------------------------
// Artefacts
// ---------------------------------------------------------------------------

const listDir = (root, dir, re) => {
  const abs = path.join(root, dir);
  if (!existsSync(abs)) return [];
  return readdirSync(abs)
    .filter((f) => re.test(f))
    .sort()
    .map((f) => `${dir}/${f}`);
};

/** Every artefact in `root`, as { kind, file } with a repo-relative file. */
export function discoverArtefacts(root) {
  const out = [];
  const vision = VISION_FILES.find((f) => existsSync(path.join(root, f)));
  if (vision) out.push({ kind: "vision", file: vision });
  const model = MODEL_FILES.find((f) => existsSync(path.join(root, f)));
  if (model) out.push({ kind: "capability-model", file: model });
  for (const d of SPEC_DIRS) for (const file of listDir(root, d, SPEC_FILE_RE)) out.push({ kind: "spec", file });
  for (const d of ADR_DIRS) for (const file of listDir(root, d, ADR_FILE_RE)) out.push({ kind: "adr", file });
  if (existsSync(path.join(root, ARCHITECTURE_FILE))) out.push({ kind: "architecture", file: ARCHITECTURE_FILE });
  return out;
}

// One unambiguous capture; closing #s and spaces are trimmed in code, so no
// two quantifiers compete for the same whitespace (PR #2955).
const HEADING_RE = /^#{1,6}[ \t]+([^\n]*)$/gm;
const trimHeading = (h) => {
  let t = h.trimEnd();
  const bare = t.replace(/#+$/, "");
  if (bare !== t && (bare === "" || /\s$/.test(bare))) t = bare;
  return t.trim();
};
/** Heading text with any leading "4.", "§2.1" or "1)" numbering removed, lower-cased. */
const headings = (text) =>
  [...text.matchAll(HEADING_RE)]
    .map((m) => trimHeading(m[1]))
    .filter(Boolean)
    .map((h) => h.replace(/^§?\d+(?:\.\d+)*[.)]?\s+/, "").toLowerCase());

/** x-sge-sections: each required section the schema names, unless exempt. */
function sectionViolations(schema, text, data, block) {
  const out = [];
  const hs = headings(text);
  for (const rule of schema["x-sge-sections"] || []) {
    if (rule.exemptFlag && data && data[rule.exemptFlag] === true) continue;
    if (rule.exemptStatuses && data && rule.exemptStatuses.includes(String(data.status).toLowerCase())) continue;
    const byHeading = rule.headings.some((h) => hs.some((x) => x.startsWith(h)));
    const byScenario = rule.scenarioLines && /^\s*Scenario( Outline)?:/m.test(text);
    const byKey = rule.frontmatterKey && block && typeof block === "object" && block[rule.frontmatterKey] != null;
    if (!byHeading && !byScenario && !byKey) {
      out.push({ field: `sections.${rule.name}`, message: `has no ${rule.name} section (a heading starting "${rule.headings.join('", "')}")` });
    }
  }
  return out;
}

/** The violations of one artefact: [{ field, message }]. */
function artefactViolations(root, kind, file, schema) {
  const abs = path.join(root, file);
  if (kind === "architecture") {
    const arch = loadArchitecture(root, file);
    const version = arch.version !== null && /^\d+$/.test(arch.version) ? Number(arch.version) : arch.version;
    const doc = { components: arch.components };
    if (version !== null) doc.version = version;
    return validateSchema(schema, doc);
  }
  const text = readFileSync(abs, "utf8");
  if (kind === "capability-model") {
    const { version, domains, unparsed } = readCapabilityModel(text);
    const doc = { domains };
    if (version !== null) doc.version = version;
    return [
      ...validateSchema(schema, doc),
      ...unparsed.map((u) => ({ field: `line ${u.line}`, message: `feature line does not read as "- { id, name, mvp, status, spec }" with nothing after spec: ${u.text.slice(0, 120)}` })),
    ];
  }
  const fm = extractFrontmatter(text);
  if (!fm) {
    return [
      { field: "frontmatter", message: "has no frontmatter (--- lines or a ```yaml block at the top of the file)" },
      ...sectionViolations(schema, text, null, null),
    ];
  }
  const out = fm.errors.map((e) => ({ field: "frontmatter", message: e }));
  let data = fm.data;
  if (kind === "spec" && fm.style === "codeblock") {
    data = fm.data && typeof fm.data === "object" ? fm.data.spec : undefined;
    if (!data || typeof data !== "object") {
      out.push({ field: "spec", message: "the ```yaml frontmatter block has no spec: mapping" });
      return [...out, ...sectionViolations(schema, text, null, fm.data)];
    }
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return [...out, { field: "frontmatter", message: "frontmatter is not a mapping" }];
  }
  out.push(...validateSchema(schema, data));
  if (schema["x-sge-idMatchesFilename"]) {
    const fileId = path.basename(file).match(SPEC_ID_RE)?.[0];
    for (const key of ["id", "ref"]) {
      if (typeof data[key] === "string" && fileId && data[key] !== fileId) {
        out.push({ field: key, message: `is ${data[key]}, but the file name says ${fileId}` });
      }
    }
  }
  out.push(...sectionViolations(schema, text, data, fm.data));
  return out;
}

/**
 * Validate every artefact under `root` against its schema.
 * @returns {{kind: "schema-violation", severity: "warning", subject: string, file: string, field: string, detail: string}[]}
 */
export function validateArtefacts(root, { schemas = loadSchemas() } = {}) {
  const findings = [];
  for (const { kind, file } of discoverArtefacts(root)) {
    for (const v of artefactViolations(root, kind, file, schemas[kind])) {
      findings.push({
        kind: "schema-violation",
        severity: "warning",
        subject: file,
        file,
        field: v.field,
        detail: `${v.field}: ${v.message} (${SCHEMA_FILES[kind]})`,
      });
    }
  }
  return findings;
}

/** CLI exit code: 1 only under --strict with a schema violation (SPEC-133). */
export function exitCodeFor(dagOrFindings, { strict = false } = {}) {
  const findings = Array.isArray(dagOrFindings) ? dagOrFindings : dagOrFindings.findings || [];
  return strict && findings.some((f) => f.kind === "schema-violation") ? 1 : 0;
}
