#!/usr/bin/env node
/**
 * capture-design-evidence.mjs — pre-capture design-review evidence (#2648).
 *
 * `agents/design-reviewer.md` can review a UI either LIVE (Playwright MCP
 * tools) or from STATIC EVIDENCE: a directory of viewport screenshots plus a
 * `measurements.json` manifest. This script produces that directory with
 * Playwright used directly as a library — no Playwright MCP server needed —
 * so the design gate can run in a session that has no browser MCP at all.
 *
 * The dispatching agent (which has Bash) runs this against a running app,
 * then dispatches design-reviewer naming the output directory. The reviewer
 * itself never runs this script (its tool allowlist has no Bash — SPEC-115).
 *
 * Commands (`--help` prints this whole contract and exits 0)
 * --------
 *   node capture-design-evidence.mjs capture --base-url <url>
 *        [--routes </,/pricing,...> | --plan <plan.json>]
 *        [--viewports 1440x900,768x1024,375x812] [--out <dir>]
 *        [--commit <sha>] [--tab-presses <n>] [--full-page] [--channel msedge|chrome]
 *        [--timeout-ms <nav-timeout, default 30000>]
 *     Captures every route x state x viewport. Stdout: the output dir.
 *     Exit 0 when every capture succeeded, 1 when any capture failed (the
 *     failures are recorded in the manifest's `errors[]`; partial evidence is
 *     still written), 2 on bad arguments / Playwright not installed.
 *     --channel msedge|chrome uses an installed system browser instead of
 *     Playwright's downloaded chromium. --timeout-ms bounds each navigation.
 *
 *   node capture-design-evidence.mjs discover --base-url <url>
 *        [--routes /,/pricing] [--viewports 1440x900] [--out <file.json>]
 *        [--channel msedge|chrome] [--timeout-ms <ms>]
 *     Lists every visible button, link and input on each route with its role,
 *     accessible name and a suggested selector (`unique` = it matches exactly
 *     one element), so `--plan` actions are built from the rendered page
 *     instead of written blind. Prints `sge-design-discovery/v1` JSON:
 *       { schema, baseUrl, routes: [{ route, url, httpStatus, error?,
 *         elements: [{ kind: button|link|input, role, name, tag, type,
 *                      selector, unique }] }] }
 *     to stdout (or --out). Exit 0, 1 if any route failed to load, 2 bad args.
 *
 *   node capture-design-evidence.mjs validate <dir>
 *     Checks <dir>/measurements.json against the v1 format below and that
 *     every referenced screenshot exists inside <dir>. Dependency-free (no
 *     Playwright). Exit 0 valid, 1 invalid (problems on stderr), 2 bad args.
 *
 * Static output (sge-dashboard, docs): skip the dev server and pass
 *   --base-url file:///abs/path/to/site . A route ending in "/" loads its
 *   index.html; an extensionless route loads <route>.html when it exists,
 *   else <route>/index.html. httpStatus is null for file:// pages.
 *
 * Plan file (optional; `--routes` is shorthand for one `default` state each):
 *   {
 *     "viewports": [{ "width": 1440, "height": 900 }, ...],      // optional
 *     "routes": [
 *       { "path": "/", "states": [
 *           { "name": "default" },
 *           { "name": "menu-open", "actions": [
 *               { "click": "button[aria-label='Menu']" },
 *               { "wait": 300 } ] } ] }
 *     ]
 *   }
 *   Actions (run in order after navigation): { "click": sel }, { "hover": sel },
 *   { "fill": [sel, value] }, { "press": key }, { "wait": ms },
 *   { "waitFor": sel }.
 *
 * Output format — `sge-design-evidence/v1` (documented for design-reviewer in
 * agents/design-reviewer.md "Static evidence mode"):
 *   <dir>/measurements.json
 *   <dir>/<route-slug>/<state>@<W>x<H>.png          viewport screenshot
 *   <dir>/<route-slug>/<state>@<W>x<H>-focus.png    after N x Tab (first viewport only)
 *   <dir>/<route-slug>/<state>@<W>x<H>-full.png     full page (--full-page only)
 *
 *   measurements.json = {
 *     schema: "sge-design-evidence/v1", capturedAt, baseUrl, commit|null,
 *     tool: { name, playwrightVersion }, viewports: [{width,height}],
 *     captures: [{
 *       route, state, viewport: {width,height}, url, httpStatus,
 *       screenshot, focusScreenshot?, fullPageScreenshot?,   // paths relative to <dir>
 *       measurements: {
 *         scrollWidth, clientWidth, scrollHeight, horizontalOverflow,
 *         overflowingElements: [{ el, right }],                // right edge > clientWidth
 *         console: { errors: [], warnings: [] }, pageErrors: [],
 *         network: { failed: [{ url, method, status, failure }] },  // optional in validate:
 *                      // requestfailed (status null) + responses with status >= 400
 *         focus: [{ step, el, text, outline, boxShadow, visible }] | null,
 *         smallTouchTargets: [{ el, width, height }],          // interactive < 44px
 *         typography: { body|h1|h2|h3|p|a|button: {fontFamily, fontSize,
 *                       fontWeight, lineHeight, color, background} },
 *         palette: { color: [[value, count]], background: [[value, count]] },
 *         animations: { running, runningWithReducedMotion } | null
 *       } }],
 *     errors: [{ route, state, viewport, message }]
 *   }
 *   `focus` and `animations` are measured at the first viewport only (null
 *   elsewhere) — they are properties of the page, not of the width.
 *
 * Playwright resolution: `import("playwright")`, then `playwright` /
 * `@playwright/test` resolved from the current working directory (run this
 * from the target repo, which typically already has Playwright installed).
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { isAbsolute, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const SCHEMA = "sge-design-evidence/v1";
export const DISCOVERY_SCHEMA = "sge-design-discovery/v1";
export const DEFAULT_VIEWPORTS = [
  { width: 1440, height: 900 },
  { width: 768, height: 1024 },
  { width: 375, height: 812 },
];
const REQUIRED_MEASUREMENTS = [
  "scrollWidth",
  "clientWidth",
  "horizontalOverflow",
  "console",
  "smallTouchTargets",
  "typography",
];

// ─── Pure helpers (unit-tested, no Playwright) ───────────────────────────────

/** Parse `argv.slice(2)` into { command, positional, flags }. */
export function parseArgs(args) {
  const [command, ...rest] = args;
  const flags = {};
  const positional = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = rest[i + 1];
      flags[key] = next !== undefined && !next.startsWith("--") ? rest[++i] : true;
    } else {
      positional.push(a);
    }
  }
  return { command, positional, flags };
}

/** "1440x900,375x812" -> [{width,height}, ...]; throws on a malformed entry. */
export function parseViewports(spec) {
  return String(spec)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      const m = /^(\d{2,5})x(\d{2,5})$/.exec(s);
      if (!m) throw new Error(`bad viewport "${s}" — expected WIDTHxHEIGHT, e.g. 1440x900`);
      return { width: Number(m[1]), height: Number(m[2]) };
    });
}

/** Route path -> filesystem-safe directory name ("/" -> "root"). */
export function routeSlug(path) {
  const clean = String(path)
    .replace(/[?#].*$/, "")
    .replace(/^\/+|\/+$/g, "")
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return clean || "root";
}

/** State name -> filesystem-safe token. */
export function stateSlug(name) {
  return String(name || "default").replace(/[^A-Za-z0-9._-]+/g, "-") || "default";
}

/** Relative screenshot path for a capture (forward slashes, portable). */
export function shotPath(route, state, vp, suffix = "") {
  return `${routeSlug(route)}/${stateSlug(state)}@${vp.width}x${vp.height}${suffix}.png`;
}

/**
 * Build the normalised plan from CLI flags (+ an optional plan object).
 * Returns { viewports, routes: [{ path, states: [{ name, actions }] }] }.
 */
export function buildPlan(flags, planObj = null) {
  let viewports = DEFAULT_VIEWPORTS;
  if (planObj?.viewports?.length) viewports = planObj.viewports;
  if (typeof flags.viewports === "string") viewports = parseViewports(flags.viewports);
  for (const vp of viewports) {
    if (!Number.isInteger(vp.width) || !Number.isInteger(vp.height)) {
      throw new Error(`viewport needs integer width/height: ${JSON.stringify(vp)}`);
    }
  }

  let routes;
  if (planObj?.routes?.length) {
    routes = planObj.routes.map((r) => {
      const path = typeof r === "string" ? r : r.path;
      if (typeof path !== "string" || !path.startsWith("/")) {
        throw new Error(`route path must start with "/": ${JSON.stringify(r)}`);
      }
      const states = (typeof r === "object" && r.states?.length ? r.states : [{ name: "default" }]).map(
        (s) => ({ name: s.name || "default", actions: Array.isArray(s.actions) ? s.actions : [] })
      );
      return { path, states };
    });
  } else if (typeof flags.routes === "string") {
    routes = flags.routes
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((path) => {
        if (!path.startsWith("/")) throw new Error(`route must start with "/": ${path}`);
        return { path, states: [{ name: "default", actions: [] }] };
      });
  } else {
    routes = [{ path: "/", states: [{ name: "default", actions: [] }] }];
  }
  return { viewports, routes };
}

/**
 * Full URL for a route. http(s) bases just concatenate; a file:// base maps
 * "/x/" -> "/x/index.html" and "/x" -> "/x.html" when it exists, else
 * "/x/index.html" (a static build has no server to do that routing).
 */
export function resolveRouteUrl(baseUrl, path) {
  const base = String(baseUrl).replace(/\/+$/, "");
  if (!/^file:/i.test(base)) return base + path;
  const cut = String(path).search(/[?#]/);
  const p = cut === -1 ? String(path) : String(path).slice(0, cut);
  const rest = cut === -1 ? "" : String(path).slice(cut); // keeps ?query AND #fragment
  // A route must stay inside the static site: no ".." segment and no encoded
  // slash (raw or percent-encoded), and the resolved file must sit under the base dir.
  if (p.split("/").some((seg) => /^\.\.$|[\\/]/.test(safeDecode(seg)))) {
    throw new Error(`route escapes the static site: ${path}`);
  }
  const root = resolve(fileURLToPath(base));
  let target = p;
  if (target.endsWith("/")) target += "index.html";
  else if (!/\.[A-Za-z0-9]+$/.test(target.split("/").pop())) {
    target = existsSync(fileURLToPath(base + target + ".html")) ? target + ".html" : target + "/index.html";
  }
  const full = resolve(fileURLToPath(base + target));
  if (full !== root && !full.startsWith(root + sep)) throw new Error(`route escapes the static site: ${path}`);
  return base + target + rest;
}

function safeDecode(s) {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

const INPUT_ROLES = {
  button: "button", submit: "button", reset: "button", image: "button",
  checkbox: "checkbox", radio: "radio", range: "slider", number: "spinbutton",
  search: "searchbox", email: "textbox", tel: "textbox", text: "textbox", url: "textbox", password: "textbox",
};

/** ARIA role of a discovered element: explicit role wins, else the implicit one. */
export function implicitRole({ tag, type, role, href }) {
  if (role) return role.split(/\s+/)[0];
  if (tag === "a") return href != null ? "link" : null;
  if (tag === "button") return "button";
  if (tag === "select") return "combobox";
  if (tag === "textarea") return "textbox";
  if (tag === "input") return INPUT_ROLES[(type || "text").toLowerCase()] ?? "textbox";
  return null;
}

/** button | link | input, from the role (a role=button div is a button). */
export function elementKind(el) {
  const role = implicitRole(el);
  if (role === "link") return "link";
  if (role === "button") return "button";
  return "input";
}

const cssString = (v) => JSON.stringify(String(v));
const CSS_IDENT = /^-?[A-Za-z_][A-Za-z0-9_-]*$/;

/**
 * Suggested selector, most stable first: data-testid, #id, form-field name,
 * Playwright role+name, then the bare tag (ambiguous; `unique` reports it).
 * All forms are accepted by Playwright's page.click/fill, i.e. by --plan.
 */
export function suggestSelector(el) {
  const role = implicitRole(el);
  if (el.testId) return `[data-testid=${cssString(el.testId)}]`;
  if (el.id && CSS_IDENT.test(el.id)) return `#${el.id}`;
  if (el.nameAttr && ["input", "select", "textarea"].includes(el.tag)) return `${el.tag}[name=${cssString(el.nameAttr)}]`;
  if (role && el.name) return `role=${role}[name=${cssString(el.name)}]`;
  return el.tag + (el.type ? `[type=${cssString(el.type)}]` : "");
}

/** True when `rel` is a relative path that stays inside its base dir. */
function isContainedRelative(rel) {
  if (typeof rel !== "string" || rel === "" || isAbsolute(rel) || /^[A-Za-z]:/.test(rel)) return false;
  const n = normalize(rel);
  return n !== ".." && !n.startsWith(".." + sep) && !n.startsWith("../");
}

/**
 * Validate an evidence directory. Returns { ok, problems[], manifest|null }.
 * Dependency-free; the dispatching agent runs this before handing the
 * directory to design-reviewer.
 */
export function validateEvidenceDir(dir) {
  const problems = [];
  const mf = join(dir, "measurements.json");
  if (!existsSync(mf)) return { ok: false, problems: [`missing ${mf}`], manifest: null };
  let m;
  try {
    m = JSON.parse(readFileSync(mf, "utf8"));
  } catch (e) {
    return { ok: false, problems: [`measurements.json is not valid JSON: ${e.message}`], manifest: null };
  }
  if (m.schema !== SCHEMA) problems.push(`schema must be "${SCHEMA}" (got ${JSON.stringify(m.schema)})`);
  if (typeof m.baseUrl !== "string" || !m.baseUrl) problems.push("baseUrl missing");
  if (typeof m.capturedAt !== "string") problems.push("capturedAt missing");
  if (!("commit" in m)) problems.push("commit missing (use null when unknown)");
  if (!Array.isArray(m.captures) || m.captures.length === 0) {
    problems.push("captures[] missing or empty — no evidence to review");
  } else {
    m.captures.forEach((c, i) => {
      const where = `captures[${i}] (${c?.route} ${c?.state} ${c?.viewport?.width}x${c?.viewport?.height})`;
      if (typeof c.route !== "string" || !c.route.startsWith("/")) problems.push(`${where}: bad route`);
      if (typeof c.state !== "string" || !c.state) problems.push(`${where}: bad state`);
      if (!Number.isInteger(c.viewport?.width) || !Number.isInteger(c.viewport?.height)) {
        problems.push(`${where}: bad viewport`);
      }
      for (const key of ["screenshot", "focusScreenshot", "fullPageScreenshot"]) {
        if (c[key] == null) {
          if (key === "screenshot") problems.push(`${where}: screenshot missing`);
          continue;
        }
        if (!isContainedRelative(c[key])) {
          problems.push(`${where}: ${key} must be a relative path inside the evidence dir (got ${c[key]})`);
        } else if (!existsSync(join(dir, c[key])) || statSync(join(dir, c[key])).size === 0) {
          problems.push(`${where}: ${key} file not found or empty: ${c[key]}`);
        }
      }
      const ms = c.measurements;
      if (!ms || typeof ms !== "object") {
        problems.push(`${where}: measurements missing`);
      } else {
        for (const k of REQUIRED_MEASUREMENTS) if (!(k in ms)) problems.push(`${where}: measurements.${k} missing`);
        if (ms.console && (!Array.isArray(ms.console.errors) || !Array.isArray(ms.console.warnings))) {
          problems.push(`${where}: measurements.console needs errors[] and warnings[]`);
        }
        // optional (older evidence predates it), but well-formed when present
        if ("network" in ms && !Array.isArray(ms.network?.failed)) {
          problems.push(`${where}: measurements.network needs failed[]`);
        }
      }
    });
  }
  if (m.errors != null && !Array.isArray(m.errors)) problems.push("errors must be an array");
  return { ok: problems.length === 0, problems, manifest: m };
}

// ─── Browser-side measurement (serialised into the page) ─────────────────────

/* c8 ignore start — runs inside the browser via page.evaluate */
function measurePage() {
  const de = document.documentElement;
  const describe = (el) => {
    if (!el || el === document.body) return el ? "body" : null;
    let s = el.tagName.toLowerCase();
    if (el.id) s += `#${el.id}`;
    else if (typeof el.className === "string" && el.className.trim()) {
      s += "." + el.className.trim().split(/\s+/).slice(0, 2).join(".");
    }
    return s;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none";
  };
  const effectiveBg = (el) => {
    for (let n = el; n; n = n.parentElement) {
      const bg = getComputedStyle(n).backgroundColor;
      if (bg && bg !== "transparent" && !/rgba\([^)]*,\s*0\)$/.test(bg)) return bg;
    }
    return "rgb(255, 255, 255)";
  };

  const clientWidth = de.clientWidth;
  const all = Array.from(document.body ? document.body.querySelectorAll("*") : []);
  const overflowingElements = [];
  for (const el of all) {
    if (overflowingElements.length >= 10) break;
    const r = el.getBoundingClientRect();
    if (r.width > 0 && r.right > clientWidth + 1) {
      overflowingElements.push({ el: describe(el), right: Math.round(r.right) });
    }
  }

  const interactive = Array.from(
    document.querySelectorAll("a[href], button, input, select, textarea, [role=button], [tabindex]:not([tabindex='-1'])")
  );
  const smallTouchTargets = [];
  for (const el of interactive) {
    if (smallTouchTargets.length >= 20) break;
    if (!visible(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 44 || r.height < 44) {
      smallTouchTargets.push({ el: describe(el), width: Math.round(r.width), height: Math.round(r.height) });
    }
  }

  const typography = {};
  for (const sel of ["body", "h1", "h2", "h3", "p", "a", "button"]) {
    const el = document.querySelector(sel);
    if (!el) continue;
    const cs = getComputedStyle(el);
    typography[sel] = {
      fontFamily: cs.fontFamily,
      fontSize: cs.fontSize,
      fontWeight: cs.fontWeight,
      lineHeight: cs.lineHeight,
      color: cs.color,
      background: effectiveBg(el),
    };
  }

  const colorCounts = new Map();
  const bgCounts = new Map();
  for (const el of all) {
    if (!visible(el)) continue;
    const cs = getComputedStyle(el);
    colorCounts.set(cs.color, (colorCounts.get(cs.color) || 0) + 1);
    const bg = cs.backgroundColor;
    if (bg && bg !== "transparent" && !/rgba\([^)]*,\s*0\)$/.test(bg)) bgCounts.set(bg, (bgCounts.get(bg) || 0) + 1);
  }
  const top = (m) => Array.from(m.entries()).sort((a, b) => b[1] - a[1]).slice(0, 20);

  return {
    scrollWidth: de.scrollWidth,
    clientWidth,
    scrollHeight: de.scrollHeight,
    horizontalOverflow: de.scrollWidth > clientWidth,
    overflowingElements,
    smallTouchTargets,
    typography,
    palette: { color: top(colorCounts), background: top(bgCounts) },
  };
}

const COUNT_RUNNING_ANIMATIONS = () =>
  document.getAnimations ? document.getAnimations().filter((a) => a.playState === "running").length : null;

function describeFocus(step) {
  const el = document.activeElement;
  if (!el || el === document.body) return { step, el: "body", text: "", outline: null, boxShadow: null, visible: false };
  const cs = getComputedStyle(el);
  const outline = `${cs.outlineStyle} ${cs.outlineWidth} ${cs.outlineColor}`;
  const hasOutline = cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0;
  const hasShadow = cs.boxShadow && cs.boxShadow !== "none";
  let s = el.tagName.toLowerCase();
  if (el.id) s += `#${el.id}`;
  return {
    step,
    el: s,
    text: (el.innerText || el.getAttribute("aria-label") || el.value || "").trim().slice(0, 60),
    outline,
    boxShadow: cs.boxShadow,
    visible: Boolean(hasOutline || hasShadow),
  };
}
/** Raw facts about each visible interactive element; Node derives role/name/selector. */
function collectInteractive() {
  const text = (n) => (n ? (n.innerText || n.textContent || "").replace(/\s+/g, " ").trim() : "");
  const nameOf = (el) => {
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const labelled = by.split(/\s+/).map((id) => text(document.getElementById(id))).join(" ").trim();
      if (labelled) return labelled;
    }
    const aria = el.getAttribute("aria-label");
    if (aria) return aria.trim();
    if (el.labels && el.labels.length) return text(el.labels[0]);
    if (el.tagName === "INPUT" && ["submit", "button", "reset"].includes(el.type)) return el.value || "";
    const t = text(el) || (el.querySelector("img[alt]")?.getAttribute("alt") ?? "");
    return (t || el.getAttribute("title") || el.getAttribute("placeholder") || "").trim();
  };
  const sel = "a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=link], [role=checkbox], [role=tab], [role=menuitem]";
  return Array.from(document.querySelectorAll(sel))
    .filter((el) => {
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none";
    })
    .slice(0, 200)
    .map((el) => ({
      tag: el.tagName.toLowerCase(),
      type: el.getAttribute("type"),
      role: el.getAttribute("role"),
      href: el.getAttribute("href"),
      id: el.id || null,
      testId: el.getAttribute("data-testid"),
      nameAttr: el.getAttribute("name"),
      name: nameOf(el).slice(0, 80),
    }));
}
/* c8 ignore stop */

// ─── Playwright-driven capture ───────────────────────────────────────────────

async function loadPlaywright() {
  // A CJS package imported from ESM exposes its exports on `default`.
  const pick = (m) => (m?.chromium ? m : m?.default?.chromium ? m.default : null);
  try {
    const m = pick(await import("playwright"));
    if (m) return m;
  } catch {
    /* fall through to cwd resolution */
  }
  const req = createRequire(join(process.cwd(), "noop.js"));
  for (const name of ["playwright", "@playwright/test"]) {
    try {
      const m = pick(await import(pathToFileURL(req.resolve(name)).href));
      if (m) return m;
    } catch {
      /* try next */
    }
  }
  return null;
}

async function runActions(page, actions) {
  for (const a of actions) {
    if (a.click) await page.click(a.click);
    else if (a.hover) await page.hover(a.hover);
    else if (a.fill) await page.fill(a.fill[0], a.fill[1]);
    else if (a.press) await page.keyboard.press(a.press);
    else if (a.waitFor) await page.waitForSelector(a.waitFor);
    else if (a.wait) await page.waitForTimeout(Number(a.wait));
    else throw new Error(`unknown action ${JSON.stringify(a)}`);
  }
}

async function cmdCapture(flags) {
  if (typeof flags["base-url"] !== "string") return usage("--base-url is required");
  let planObj = null;
  if (typeof flags.plan === "string") planObj = JSON.parse(readFileSync(flags.plan, "utf8"));
  const plan = buildPlan(flags, planObj);
  const baseUrl = flags["base-url"].replace(/\/+$/, "");
  const commit = typeof flags.commit === "string" ? flags.commit : null;
  const tabPresses = flags["tab-presses"] ? parseInt(flags["tab-presses"], 10) : 6;
  const navTimeout = flags["timeout-ms"] ? parseInt(flags["timeout-ms"], 10) : 30000;
  const label = (commit || new Date().toISOString()).replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 40);
  const out = resolve(typeof flags.out === "string" ? flags.out : join(tmpdir(), `sge-design-evidence-${label}`));
  mkdirSync(out, { recursive: true });

  const pw = await loadPlaywright();
  if (!pw?.chromium) {
    process.stderr.write(
      "capture-design-evidence: Playwright not found. Install it in the target repo (npm i -D playwright && npx playwright install chromium) and run this from that repo.\n"
    );
    process.exit(2);
  }
  let playwrightVersion = null;
  try {
    const req = createRequire(join(process.cwd(), "noop.js"));
    playwrightVersion = JSON.parse(readFileSync(req.resolve("playwright/package.json"), "utf8")).version;
  } catch {
    /* version is informational only */
  }

  const manifest = {
    schema: SCHEMA,
    capturedAt: new Date().toISOString(),
    baseUrl,
    commit,
    tool: { name: "sge/scripts/capture-design-evidence.mjs", playwrightVersion },
    viewports: plan.viewports,
    captures: [],
    errors: [],
  };

  // --channel msedge / chrome uses an installed system browser instead of the
  // Playwright-downloaded chromium (handy when browser binaries are not installed).
  const browser = await pw.chromium.launch(typeof flags.channel === "string" ? { channel: flags.channel } : {});
  try {
    for (const route of plan.routes) {
      for (const state of route.states) {
        for (const [vi, vp] of plan.viewports.entries()) {
          const first = vi === 0;
          const context = await browser.newContext({ viewport: vp });
          const page = await context.newPage();
          const errors = [];
          const warnings = [];
          const pageErrors = [];
          page.on("console", (msg) => {
            if (msg.type() === "error") errors.push(msg.text());
            else if (msg.type() === "warning") warnings.push(msg.text());
          });
          page.on("pageerror", (err) => pageErrors.push(String(err?.message || err)));
          const networkFailed = [];
          page.on("requestfailed", (req) =>
            networkFailed.push({ url: req.url(), method: req.method(), status: null, failure: req.failure()?.errorText ?? "failed" })
          );
          page.on("response", (res) => {
            if (res.status() >= 400) {
              networkFailed.push({ url: res.url(), method: res.request().method(), status: res.status(), failure: null });
            }
          });
          try {
            const resp = await page.goto(resolveRouteUrl(baseUrl, route.path), { waitUntil: "load", timeout: navTimeout });
            // networkidle never settles on dev servers with HMR/long-poll sockets;
            // best-effort wait, then continue.
            await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
            await runActions(page, state.actions);
            const rel = shotPath(route.path, state.name, vp);
            mkdirSync(join(out, routeSlug(route.path)), { recursive: true });
            await page.screenshot({ path: join(out, rel) });
            const capture = {
              route: route.path,
              state: state.name,
              viewport: vp,
              url: page.url(),
              httpStatus: resp && !/^file:/i.test(baseUrl) ? resp.status() : null,
              screenshot: rel,
            };
            if (flags["full-page"]) {
              capture.fullPageScreenshot = shotPath(route.path, state.name, vp, "-full");
              await page.screenshot({ path: join(out, capture.fullPageScreenshot), fullPage: true });
            }
            const measurements = await page.evaluate(measurePage);
            measurements.focus = null;
            measurements.animations = null;
            if (first) {
              const running = await page.evaluate(COUNT_RUNNING_ANIMATIONS);
              const focus = [];
              for (let i = 1; i <= tabPresses; i++) {
                await page.keyboard.press("Tab");
                focus.push(await page.evaluate(describeFocus, i));
              }
              measurements.focus = focus;
              capture.focusScreenshot = shotPath(route.path, state.name, vp, "-focus");
              await page.screenshot({ path: join(out, capture.focusScreenshot) });
              // Separate context with prefers-reduced-motion: reduce (R6/R7):
              // a fresh load, so no state from the Tab walk above leaks in.
              const rmContext = await browser.newContext({ viewport: vp, reducedMotion: "reduce" });
              let runningReduced = null;
              try {
                const rmPage = await rmContext.newPage();
                await rmPage.goto(resolveRouteUrl(baseUrl, route.path), { waitUntil: "load" });
                await runActions(rmPage, state.actions);
                runningReduced = await rmPage.evaluate(COUNT_RUNNING_ANIMATIONS);
              } finally {
                await rmContext.close();
              }
              measurements.animations = { running, runningWithReducedMotion: runningReduced };
            }
            measurements.console = { errors, warnings };
            measurements.pageErrors = pageErrors;
            measurements.network = { failed: [...networkFailed] }; // snapshot: close() can still fire requestfailed
            capture.measurements = measurements;
            manifest.captures.push(capture);
          } catch (err) {
            manifest.errors.push({ route: route.path, state: state.name, viewport: vp, message: String(err?.message || err) });
          } finally {
            await context.close();
          }
        }
      }
    }
  } finally {
    // Write the manifest BEFORE closing the browser, and bound the close:
    // browser.close() on a system channel (msedge) has been observed to hang
    // intermittently on Windows. The evidence is complete at this point.
    writeFileSync(join(out, "measurements.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
    await Promise.race([browser.close().catch(() => {}), new Promise((r) => setTimeout(r, 10_000).unref())]);
  }

  process.stdout.write(out + "\n");
  if (manifest.errors.length) {
    process.stderr.write(`capture-design-evidence: ${manifest.errors.length} capture(s) failed — see errors[] in measurements.json\n`);
    process.exit(1);
  }
  process.exit(0); // never wait on a lingering browser process
}

async function cmdDiscover(flags) {
  if (typeof flags["base-url"] !== "string") return usage("--base-url is required");
  const plan = buildPlan(flags);
  const baseUrl = flags["base-url"].replace(/\/+$/, "");
  const navTimeout = flags["timeout-ms"] ? parseInt(flags["timeout-ms"], 10) : 30000;
  const pw = await loadPlaywright();
  if (!pw?.chromium) {
    process.stderr.write("capture-design-evidence: Playwright not found (see --help).\n");
    process.exit(2);
  }
  const out = { schema: DISCOVERY_SCHEMA, baseUrl, viewport: plan.viewports[0], routes: [] };
  const browser = await pw.chromium.launch(typeof flags.channel === "string" ? { channel: flags.channel } : {});
  try {
    const context = await browser.newContext({ viewport: plan.viewports[0] });
    const page = await context.newPage();
    for (const route of plan.routes) {
      const entry = { route: route.path, url: resolveRouteUrl(baseUrl, route.path), httpStatus: null, elements: [] };
      try {
        const resp = await page.goto(entry.url, { waitUntil: "load", timeout: navTimeout });
        await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
        if (resp && !/^file:/i.test(baseUrl)) entry.httpStatus = resp.status();
        for (const raw of await page.evaluate(collectInteractive)) {
          const selector = suggestSelector(raw);
          const count = await page.locator(selector).count().catch(() => 0);
          entry.elements.push({
            kind: elementKind(raw),
            role: implicitRole(raw),
            name: raw.name,
            tag: raw.tag,
            type: raw.type,
            selector,
            unique: count === 1,
          });
        }
      } catch (err) {
        entry.error = String(err?.message || err);
      }
      out.routes.push(entry);
    }
  } finally {
    await Promise.race([browser.close().catch(() => {}), new Promise((r) => setTimeout(r, 10_000).unref())]);
  }
  const json = JSON.stringify(out, null, 2) + "\n";
  if (typeof flags.out === "string") writeFileSync(flags.out, json, "utf8");
  else process.stdout.write(json);
  process.exit(out.routes.some((r) => r.error) ? 1 : 0);
}

function cmdValidate(positional) {
  const dir = positional[0];
  if (!dir) return usage("validate needs a directory");
  const { ok, problems } = validateEvidenceDir(resolve(dir));
  if (ok) {
    process.stdout.write(`ok - ${resolve(dir)} is valid ${SCHEMA} evidence\n`);
    return;
  }
  for (const p of problems) process.stderr.write(`invalid: ${p}\n`);
  process.exit(1);
}

/** The header comment of this file: the full CLI contract, printed by --help. */
export function helpText() {
  return readFileSync(fileURLToPath(import.meta.url), "utf8")
    .match(/\/\*\*([\s\S]*?)\*\//)[1]
    .split("\n")
    .map((l) => l.replace(/^ \* ?/, "").replace(/^ \*$/, ""))
    .join("\n")
    .trim();
}

function usage(msg) {
  process.stderr.write(
    `capture-design-evidence: ${msg}\n` +
      "Usage: capture-design-evidence.mjs capture --base-url <url> [--routes /,/x | --plan plan.json] [--viewports 1440x900,375x812] [--out dir] [--commit sha] [--tab-presses n] [--full-page] [--channel msedge|chrome] [--timeout-ms ms]\n" +
      "       capture-design-evidence.mjs discover --base-url <url> [--routes /,/x] [--viewports WxH] [--out file.json] [--channel msedge|chrome] [--timeout-ms ms]\n" +
      "       capture-design-evidence.mjs validate <dir>\n" +
      "Run with --help for the full contract (output format, plan file, file:// static sites).\n"
  );
  process.exit(2);
}

// ─── Entry point (only when run directly, so tests can import the helpers) ──

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const { command, positional, flags } = parseArgs(argv);
  if (argv.includes("--help") || argv.includes("-h") || command === "help") {
    process.stdout.write(helpText() + "\n");
    process.exit(0);
  }
  try {
    if (command === "capture") await cmdCapture(flags);
    else if (command === "discover") await cmdDiscover(flags);
    else if (command === "validate") cmdValidate(positional);
    else usage(`unknown command: ${command ?? "(none)"}`);
  } catch (err) {
    process.stderr.write(`capture-design-evidence: ${err?.message || err}\n`);
    process.exit(2);
  }
}
