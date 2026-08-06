#!/usr/bin/env bash
# scan.sh — deterministic, read-only heuristic scanner for /sge:atomic-audit.
#
# Usage: bash scan.sh [path]
#
# Emits stable `key=value` lines that anchor the audit's evidence cells and
# its idempotency claim (same repo state -> same output). Heuristic by
# design: it counts common atomic-design signals with grep/find only, makes
# no stack assumptions beyond widely used naming patterns, and every probe
# degrades to 0 when its pattern is absent. It never writes anything.

set -u
LC_ALL=C
export LC_ALL

ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "error=path_not_found root=$ROOT"; exit 1; }

# Directories never worth scanning (generated/vendored).
PRUNE="-name node_modules -o -name .git -o -name dist -o -name build -o -name out -o -name vendor -o -name Pods -o -name .next -o -name .nuxt -o -name coverage -o -name .dart_tool -o -name DerivedData"
GREPX="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude-dir=out --exclude-dir=vendor --exclude-dir=Pods --exclude-dir=.next --exclude-dir=.nuxt --exclude-dir=coverage --exclude-dir=.dart_tool --exclude-dir=DerivedData"

# Find files (ff) / dirs (fd) under ROOT with pruning; output sorted for determinism.
ff() { find . \( $PRUNE \) -prune -o -type f \( "$@" \) -print 2>/dev/null | sort -u; }
fd() { find . \( $PRUNE \) -prune -o -type d \( "$@" \) -print 2>/dev/null | sort -u; }
nl_count() { grep -c . 2>/dev/null || true; }   # count non-empty lines; 0 on empty input

echo "scan_version=1"
echo "root=$ROOT"

# ---------------------------------------------------------------- 1. tokens
TOKEN_CONFIGS=$( { ff -name 'tailwind.config.js' -o -name 'tailwind.config.ts' -o -name 'tailwind.config.cjs' -o -name 'tailwind.config.mjs'; \
                   ff -name '*.tokens.*' -o -name 'tokens.json' -o -name 'style-dictionary.config.*'; } | sort -u )
echo "tokens.config_files=$(printf '%s' "$TOKEN_CONFIGS" | nl_count)"

# CSS/SCSS files declaring custom properties (--var: ...)
# Pass /dev/null to grep so it always gets a file argument (xargs -r is GNU-only).
CSS_TOKEN_FILES=$( ff -name '*.css' -o -name '*.scss' | xargs grep -l -E -- '--[A-Za-z][A-Za-z0-9_-]*[[:space:]]*:' /dev/null 2>/dev/null | grep -v '^/dev/null$' | sort -u )
echo "tokens.css_custom_prop_files=$(printf '%s' "$CSS_TOKEN_FILES" | nl_count)"

# Dirs conventionally holding token/theme definitions
TOKEN_DIRS=$( fd -name 'tokens' -o -name 'theme' -o -name 'themes' -o -name 'design-tokens' )
echo "tokens.dirs=$(printf '%s' "$TOKEN_DIRS" | nl_count)"

# Native theme signals (SwiftUI asset catalogs, Compose/Flutter themes)
echo "tokens.asset_catalogs=$(fd -name '*.xcassets' | nl_count)"
echo "tokens.native_theme_refs=$(grep -r $GREPX -l -E 'MaterialTheme|ThemeData\(' --include='*.kt' --include='*.kts' --include='*.dart' . 2>/dev/null | sort -u | nl_count)"

# ------------------------------------------------------- 2. component files
# Web component sources, excluding tests and stories.
WEB_COMPONENTS=$( ff -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \
  | grep -v -E '\.(test|spec|stories)\.|__tests__/|\.storybook/' | sort -u )
# Native view sources (heuristic: SwiftUI views, Compose composables, Flutter widgets).
NATIVE_COMPONENTS=$( { grep -r $GREPX -l 'some View' --include='*.swift' . 2>/dev/null; \
                       grep -r $GREPX -l '@Composable' --include='*.kt' . 2>/dev/null; \
                       grep -r $GREPX -l -E 'extends (StatelessWidget|StatefulWidget)' --include='*.dart' . 2>/dev/null; } \
  | grep -v -E '(_test\.dart|Tests?\.swift|Test\.kt)$' | sort -u )
COMPONENT_FILES=$( printf '%s\n%s' "$WEB_COMPONENTS" "$NATIVE_COMPONENTS" | sort -u | grep -c . || true )
echo "components.files=$COMPONENT_FILES"

# ------------------------------------------------------ 3. primitive layer
PRIM_DIRS=$( fd -name 'ui' -o -name 'atoms' -o -name 'molecules' -o -name 'primitives' -o -name 'design-system' )
echo "primitives.dirs=$(printf '%s' "$PRIM_DIRS" | nl_count)"
printf '%s\n' "$PRIM_DIRS" | grep . | head -10 | sed 's/^/primitives.dir=/'
PRIM_FILES=0
if [ -n "$PRIM_DIRS" ]; then
  PRIM_FILES=$( printf '%s\n%s' "$WEB_COMPONENTS" "$NATIVE_COMPONENTS" | grep . \
    | grep -E -f <(printf '%s\n' "$PRIM_DIRS" | grep . | sed 's![].[^$*\\+?{}()|]!\\&!g; s!$!/!') 2>/dev/null \
    | sort -u | grep -c . || true )
fi
echo "primitives.files=$PRIM_FILES"

# -------------------------------------------------------- 4. raw literals
# Raw hex colours and px values inside component files, outside token sources.
RAW_HEX=0; RAW_PX=0; FILES_WITH_HEX=0
if [ -n "$WEB_COMPONENTS" ]; then
  RAW_HEX=$( printf '%s\n' "$WEB_COMPONENTS" | xargs grep -o -E '#[0-9a-fA-F]{3,8}\b' /dev/null 2>/dev/null | grep -v '^/dev/null:' | grep -c . || true )
  RAW_PX=$( printf '%s\n' "$WEB_COMPONENTS" | xargs grep -o -E '[^a-zA-Z0-9][0-9]+px' /dev/null 2>/dev/null | grep -v '^/dev/null:' | grep -c . || true )
  FILES_WITH_HEX=$( printf '%s\n' "$WEB_COMPONENTS" | xargs grep -l -E '#[0-9a-fA-F]{3,8}\b' /dev/null 2>/dev/null | grep -v '^/dev/null$' | sort -u | grep -c . || true )
fi
echo "literals.raw_hex=$RAW_HEX"
echo "literals.raw_px=$RAW_PX"
echo "literals.files_with_hex=$FILES_WITH_HEX"
if [ "$COMPONENT_FILES" -gt 0 ]; then
  echo "literals.density_per_component_file=$(awk -v l=$((RAW_HEX + RAW_PX)) -v f="$COMPONENT_FILES" 'BEGIN { printf "%.2f", l / f }')"
else
  echo "literals.density_per_component_file=0.00"
fi

# ------------------------------------------------------------- 5. catalog
echo "catalog.story_files=$(ff -name '*.stories.*' | nl_count)"
echo "catalog.swift_previews=$(grep -r $GREPX -l -E '#Preview|PreviewProvider' --include='*.swift' . 2>/dev/null | sort -u | nl_count)"
echo "catalog.compose_previews=$(grep -r $GREPX -l '@Preview' --include='*.kt' . 2>/dev/null | sort -u | nl_count)"
echo "catalog.widgetbook=$( { grep -l 'widgetbook' pubspec.yaml 2>/dev/null || true; } | nl_count)"

# --------------------------------------------------------------- 6. tests
TEST_FILES=$( ff -name '*.test.*' -o -name '*.spec.*' -o -name '*_test.dart' -o -name '*Tests.swift' -o -name '*Test.kt' )
echo "tests.total_test_files=$(printf '%s' "$TEST_FILES" | nl_count)"
PRIM_TEST_FILES=0
if [ -n "$PRIM_DIRS" ] && [ -n "$TEST_FILES" ]; then
  PRIM_TEST_FILES=$( printf '%s\n' "$TEST_FILES" | grep . \
    | grep -E -f <(printf '%s\n' "$PRIM_DIRS" | grep . | sed 's![].[^$*\\+?{}()|]!\\&!g; s!$!/!') 2>/dev/null \
    | sort -u | grep -c . || true )
fi
echo "tests.primitive_test_files=$PRIM_TEST_FILES"

# ---------------------------------------------------------- 7. enforcement
echo "enforce.import_rule_files=$(grep -r $GREPX -l -E 'no-restricted-imports|no-restricted-paths|eslint-plugin-boundaries|dependency-cruiser|importLinter|Konsist|ArchUnit' \
  --include='*.json' --include='*.js' --include='*.cjs' --include='*.mjs' --include='*.ts' --include='*.yml' --include='*.yaml' --include='*.kt' --include='*.gradle*' --include='*.cfg' --include='*.toml' . 2>/dev/null | sort -u | nl_count)"

exit 0
