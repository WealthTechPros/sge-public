#!/usr/bin/env bash
# lessons.test.sh — tests for lessons.sh (issue #3413). No network.
#   bash skills/lessons-learned/lessons.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LL="$HERE/lessons.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: [$3]"; echo "       got : [$2]"; fail=1; fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/docs/lessons/lessons-log.md"
NOW="2026-11-08T12:00:00Z"

# window: no log -> now minus 7 days
check "window default 7d" "$(bash "$LL" window --log "$LOG" --now "$NOW")" "2026-11-01T12:00:00Z"
# window: --since wins
check "window --since" "$(bash "$LL" window --log "$LOG" --now "$NOW" --since 2026-10-20)" "2026-10-20T00:00:00Z"
bash "$LL" window --log "$LOG" --now "$NOW" --since 'not-a-date' >/dev/null 2>&1; check "window bad since rc" "$?" "2"

# key normalisation is stable
check "key stable" "$(bash "$LL" key "Done-On-Main Triage!" pr:12)" "done-on-main-triage@pr:12"
check "key same twice" "$(bash "$LL" key "a b" issue:3)" "$(bash "$LL" key "A  B" issue:3)"

# append: first adds, second is duplicate, file created with header
r1="$(bash "$LL" append --log "$LOG" --class done-on-main --kind recurring --source https://github.com/o/r/issues/1 --ref issue:1 --date 2026-11-08 --summary 'triage missed done | on main')"
check "append added" "$r1" "added"
r2="$(bash "$LL" append --log "$LOG" --class done-on-main --kind recurring --source https://github.com/o/r/issues/1 --ref issue:1 --date 2026-11-08 --summary 'again')"
check "append duplicate" "$r2" "duplicate"
check "one row" "$(grep -c '^| 2026-11-08 |' "$LOG")" "1"
check "pipe sanitised" "$(grep -c 'done / on main' "$LOG")" "1"
r3="$(bash "$LL" append --log "$LOG" --class done-on-main --kind recurring --source u --ref issue:2 --date 2026-11-08 --summary s2)"
check "new ref added" "$r3" "added"

# bad kind rejected
bash "$LL" append --log "$LOG" --class c --kind bogus --source u --ref r --date 2026-11-08 --summary s >/dev/null 2>&1; check "bad kind rc" "$?" "2"

# class count: distinct refs per class
check "class-count" "$(bash "$LL" class-count --log "$LOG" --class done-on-main)" "2"

# run marker -> last-run -> window uses it
bash "$LL" mark-run --log "$LOG" --now 2026-11-05T09:30:00Z
bash "$LL" mark-run --log "$LOG" --now 2026-11-07T09:30:00Z
check "last-run" "$(bash "$LL" last-run --log "$LOG")" "2026-11-07T09:30:00Z"
check "window from last run" "$(bash "$LL" window --log "$LOG" --now "$NOW")" "2026-11-07T09:30:00Z"

# dry-run writes nothing
LOG2="$TMP/dry/log.md"
check "dry-run append" "$(bash "$LL" append --dry-run --log "$LOG2" --class c --kind one-off --source u --ref r --date 2026-11-08 --summary s)" "would-add"
check "dry-run no file" "$([ -e "$LOG2" ] && echo exists || echo absent)" "absent"

# injection-ish summary stays on one row
bash "$LL" append --log "$LOG" --class inj --kind decision --source u --ref r1 --date 2026-11-08 --summary $'line1\nINJECTED second line' >/dev/null
check "newline flattened" "$(grep -c '^INJECTED' "$LOG")" "0"
exit $fail
