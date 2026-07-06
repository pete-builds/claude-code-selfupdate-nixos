#!/usr/bin/env bash
# claude-selfupdate.sh — a Claude Code launcher that keeps itself current.
#
# On every launch it execs the best binary it already has (instant, works
# offline), and in the BACKGROUND checks Anthropic's release channel. If a
# newer version exists it downloads it, verifies it against Anthropic's OWN
# published sha256, and stages it so the NEXT launch is current. A downloaded
# binary is run UNMODIFIED (byte-identical to what we verified) via Nix's
# dynamic loader, so nothing is ever run without a checksum match, and the
# verified bytes are never rewritten. The Nix-pinned build is the permanent
# fallback, so `claude` always works even if every network step fails.
#
# Environment (set by the Nix wrapper; do not hand-edit):
#   CLAUDE_PINNED_BIN       reproducible Nix-built binary (fallback, runs directly)
#   CLAUDE_PINNED_VERSION   its version
#   CLAUDE_PLATFORM         Anthropic platform key, e.g. linux-x64 / darwin-arm64
#   CLAUDE_OS               linux | darwin
#   CLAUDE_DYNAMIC_LINKER   (linux) ELF interpreter used to run raw downloads
#   CLAUDE_LIBRARY_PATH     (linux) --library-path for raw downloads
#   CLAUDE_SELFUPDATE       0 disables the update check (just runs pinned)
set -uo pipefail

RELEASES="https://downloads.claude.ai/claude-code-releases"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-selfupdate"
STATE="$CACHE/current" # "<version>\t<path>" of the newest verified download

log() { [ -n "${CLAUDE_SELFUPDATE_DEBUG:-}" ] && printf 'claude-selfupdate: %s\n' "$*" >&2; return 0; }

# ver_gt A B -> true if A is strictly newer than B (semantic sort).
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Raw downloads (not Nix-patched) run through the loader on Linux; native elsewhere.
run_raw() {
  if [ "$CLAUDE_OS" = "linux" ]; then
    "$CLAUDE_DYNAMIC_LINKER" --library-path "$CLAUDE_LIBRARY_PATH" "$@"
  else
    "$@"
  fi
}

# Resolve the best local binary: newest verified download, else the pinned build.
best_bin="$CLAUDE_PINNED_BIN"
best_ver="$CLAUDE_PINNED_VERSION"
best_raw=0
if [ -r "$STATE" ]; then
  IFS=$'\t' read -r cver cpath <"$STATE" || true
  if [ -n "${cpath:-}" ] && [ -x "${cpath:-/nonexistent}" ] && ver_gt "${cver:-0}" "$best_ver"; then
    best_bin="$cpath"
    best_ver="$cver"
    best_raw=1
  fi
fi

# Background: check for and stage a newer release. Best-effort, always silent.
selfupdate() {
  command -v curl >/dev/null 2>&1 || return 0
  local latest
  latest="$(curl -fsS --max-time 3 "$RELEASES/latest" 2>/dev/null | tr -d '[:space:]')" || return 0
  case "$latest" in [0-9]*.[0-9]*.[0-9]*) ;; *) return 0 ;; esac
  ver_gt "$latest" "$best_ver" || { log "already current ($best_ver)"; return 0; }

  local dest="$CACHE/versions/$latest/claude"
  if [ -x "$dest" ]; then printf '%s\t%s\n' "$latest" "$dest" >"$STATE"; return 0; fi
  mkdir -p "$CACHE/versions/$latest"

  # Lock so concurrent launches do not race the same download.
  exec 9>"$CACHE/.lock" 2>/dev/null || return 0
  if command -v flock >/dev/null 2>&1; then flock -n 9 || return 0; fi

  local sum
  sum="$(curl -fsS --max-time 10 "$RELEASES/$latest/manifest.json" 2>/dev/null \
    | jq -r --arg p "$CLAUDE_PLATFORM" '.platforms[$p].checksum // empty' 2>/dev/null)" || return 0
  [ -n "$sum" ] || { log "no checksum for $CLAUDE_PLATFORM"; return 0; }

  curl -fsS --max-time 300 -o "$dest.tmp" "$RELEASES/$latest/$CLAUDE_PLATFORM/claude" 2>/dev/null \
    || { rm -f "$dest.tmp"; return 0; }

  # VERIFY against Anthropic's own published checksum before trusting the file.
  local got
  got="$(sha256sum "$dest.tmp" 2>/dev/null | cut -d' ' -f1)"
  if [ "$got" != "$sum" ]; then log "checksum mismatch, discarding"; rm -f "$dest.tmp"; return 0; fi
  chmod +x "$dest.tmp"

  # Only publish if the staged binary actually runs (through the loader on Linux).
  if run_raw "$dest.tmp" --version >/dev/null 2>&1; then
    mv -f "$dest.tmp" "$dest"
    printf '%s\t%s\n' "$latest" "$dest" >"$STATE"
    log "staged $latest for next launch"
  else
    log "staged binary failed smoke test, discarding"
    rm -f "$dest.tmp"
  fi
}

if [ "${CLAUDE_SELFUPDATE:-1}" = "1" ]; then
  ( selfupdate >/dev/null 2>&1 & ) 2>/dev/null
fi

if [ "$best_raw" = "1" ] && [ "$CLAUDE_OS" = "linux" ]; then
  exec "$CLAUDE_DYNAMIC_LINKER" --library-path "$CLAUDE_LIBRARY_PATH" "$best_bin" "$@"
fi
exec "$best_bin" "$@"
