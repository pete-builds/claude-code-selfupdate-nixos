#!/usr/bin/env bash
# update.sh — regenerate data/sources.json from Anthropic's release channel.
#
# Fetches the latest version and its manifest.json, transcribes Anthropic's OWN
# published sha256 for every platform, and rewrites data/sources.json. Run by CI
# (hourly) and available as `nix run .#update`. No third-party data; every hash
# comes straight from Anthropic's manifest.
set -euo pipefail

RELEASES="https://downloads.claude.ai/claude-code-releases"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SRC="$ROOT/data/sources.json"

latest="$(curl -fsS "$RELEASES/latest" | tr -d '[:space:]')"
case "$latest" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "update: unexpected version string '$latest'" >&2; exit 1 ;;
esac

manifest="$(curl -fsS "$RELEASES/$latest/manifest.json")"

platforms='{}'
for k in darwin-arm64 darwin-x64 linux-arm64 linux-x64 linux-arm64-musl linux-x64-musl win32-x64 win32-arm64; do
  sum="$(printf '%s' "$manifest" | jq -r --arg p "$k" '.platforms[$p].checksum // empty')"
  if [ -n "$sum" ]; then
    platforms="$(printf '%s' "$platforms" | jq --arg k "$k" --arg v "$sum" '. + {($k): $v}')"
  fi
done

jq -n --arg v "$latest" --argjson p "$platforms" '{
  version: $v,
  _comment: "Anthropic'"'"'s own published sha256 checksums, transcribed verbatim from https://downloads.claude.ai/claude-code-releases/<version>/manifest.json. Regenerate with lib/update.sh.",
  platforms: $p
}' >"$SRC"

echo "update: data/sources.json -> $latest"
