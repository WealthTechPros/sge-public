#!/usr/bin/env bash
# Explicit setup, never an implicit network operation during a commit.
# Official Gitleaks archives are pinned by version and checked-in SHA-256.
# Tracks sge#3219.
set -euo pipefail
[ "$#" -eq 0 ] || { echo "install-scanner: takes no arguments" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "install-scanner: Node.js is required" >&2; exit 2; }
version="$(cat "$HERE/gitleaks.version")"
case "$(uname -s)" in
  Linux) platform=linux; extension=tar.gz; binary=gitleaks ;;
  Darwin) platform=darwin; extension=tar.gz; binary=gitleaks ;;
  MINGW*|MSYS*|CYGWIN*) platform=windows; extension=zip; binary=gitleaks.exe ;;
  *) echo "install-scanner: unsupported operating system" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) architecture=x64 ;;
  aarch64|arm64) architecture=arm64 ;;
  *) echo "install-scanner: unsupported architecture" >&2; exit 2 ;;
esac
archive="gitleaks_${version}_${platform}_${architecture}.${extension}"
expected="$(awk -v name="$archive" '$2 == name { print $1 }' "$HERE/gitleaks.checksums")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "install-scanner: checksum pin missing" >&2; exit 2; }
destination="${HOME:?}/.cache/sge/gitleaks/$version"
if [ -x "$destination/$binary" ] && [ "$("$destination/$binary" version)" = "$version" ]; then
  echo "Gitleaks $version is already installed: $destination/$binary"
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if command -v gh >/dev/null 2>&1 \
  && gh release download "v$version" --repo gitleaks/gitleaks --pattern "$archive" --dir "$work"; then
  :
else
  curl --proto '=https' --tlsv1.2 -fsSL --retry 2 \
    "https://github.com/gitleaks/gitleaks/releases/download/v$version/$archive" -o "$work/$archive"
fi
node - "$work/$archive" "$expected" <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");
const actual = crypto.createHash("sha256").update(fs.readFileSync(process.argv[2])).digest("hex");
if (actual !== process.argv[3]) {
  console.error("install-scanner: official archive checksum mismatch");
  process.exit(2);
}
NODE
if [ "$extension" = zip ]; then
  unzip -q "$work/$archive" "$binary" -d "$work"
else
  tar -xzf "$work/$archive" -C "$work" "$binary"
fi
chmod +x "$work/$binary"
[ "$("$work/$binary" version)" = "$version" ]
mkdir -p "$destination"
cp "$work/$binary" "$destination/$binary"
echo "Installed Gitleaks $version: $destination/$binary"
