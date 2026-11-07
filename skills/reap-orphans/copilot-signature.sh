#!/usr/bin/env bash
# Shared GitHub Copilot CLI process signature (issue #3367) — sourced by
# reap-orphans.sh and copilot-session-record.sh so the reaper and the record
# writer can never disagree about what a Copilot client is. The Windows twin is
# copilot-signature.ps1; keep the two in step (the behavioural tests pin both).
#
# classify_table: reads "pid ppid etimes args" rows on stdin, writes
# "pid ppid etimes kind args" where kind is none | client | server | related, in
# ONE awk pass. Only the EXECUTABLE and script/package path are matched — never
# prompt text or other arguments (except the server flags below).
#   client  a recognised Copilot CLI (native `copilot`, or node-hosted @github/copilot)
#   server  a recognised client launched as an ACP/server/headless host
#   related anything else whose executable or package looks Copilot-ish (VS Code
#           extension, language server, helper): kept, never reaped
classify_table() {
  awk '
    function norm(s) { gsub(/\\/, "/", s); return tolower(s) }
    function bname(s) { s = norm(s); sub(/.*\//, "", s); sub(/\.exe$/, "", s); return s }
    {
      args = $0
      sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", args)
      n = split(args, w, " "); base = bname(w[1]); kind = "none"
      if (base == "copilot") kind = "client"
      else if (base == "node" || base == "nodejs" || base == "bun" || base == "deno") {
        script = ""
        for (i = 2; i <= n; i++) {
          if (norm(w[i]) ~ /(^|\/)@github\/copilot(\/|$)/) kind = "client"
          if (script == "" && substr(w[i], 1, 1) != "-") script = w[i]
        }
        if (kind == "none") {
          s = norm(script)
          if (s ~ /(^|\/)@github\/copilot|(^|\/)github\.copilot/) kind = "related"
          else if (bname(script) ~ /copilot/) kind = "related"
        }
      }
      else if (base ~ /copilot/) kind = "related"
      else if (norm(w[1]) ~ /(^|\/)github\.copilot|(^|\/)@github\/copilot/) kind = "related"
      if (kind == "client") {
        low = " " norm(args) " "
        if (low ~ / --(acp|server|headless|ui-server|stdio|port|daemon)([= ]|$)/) kind = "server"
      }
      printf "%s %s %s %s %s\n", $1, $2, $3, kind, args
    }'
}
