#!/usr/bin/env bash
# claude-selfupdate.sh — a Claude Code launcher that keeps itself current.
#
# On every launch it execs the best binary it already has (instant, works
# offline), and in the BACKGROUND checks Anthropic's release channel. If a
# newer version exists it downloads it, verifies it against Anthropic's OWN
# published sha256, then (on Linux) patches ONLY the ELF interpreter so the
# binary can be exec'd directly, exactly like the Nix-built pinned package.
# Nothing is ever patched or run before its checksum matches. The Nix-pinned
# build is the permanent fallback, so `claude` always works even if every
# network step fails.
#
# Why we exec the binary directly instead of launching it through ld-linux
# (`$CLAUDE_DYNAMIC_LINKER --library-path ... binary`): under the loader
# trick, /proc/self/exe (Bun's process.execPath) is the LOADER, and Claude
# Code exports CLAUDE_CODE_EXECPATH=process.execPath into every shell it
# spawns; its built-in grep/rg shell shims then exec the bare loader and
# every `grep` inside a Claude Code session fails. process.execPath is only
# correct when the claude ELF itself is what the kernel execs.
#
# Environment (set by the Nix wrapper; do not hand-edit):
#   CLAUDE_PINNED_BIN       reproducible Nix-built binary (fallback, runs directly)
#   CLAUDE_PINNED_VERSION   its version
#   CLAUDE_PLATFORM         Anthropic platform key, e.g. linux-x64 / darwin-arm64
#   CLAUDE_OS               linux | darwin
#   CLAUDE_DYNAMIC_LINKER   (linux) ELF interpreter patched into downloads
#   CLAUDE_LIBRARY_PATH     (linux) --library-path for the legacy loader fallback
#   CLAUDE_PATCHELF         (linux) patchelf binary used on verified downloads
#   CLAUDE_SELFUPDATE       0 disables the update check (just runs pinned)
set -uo pipefail

RELEASES="https://downloads.claude.ai/claude-code-releases"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-selfupdate"
STATE="$CACHE/current" # "<version>\t<path>" of the newest verified download

log() { [ -n "${CLAUDE_SELFUPDATE_DEBUG:-}" ] && printf 'claude-selfupdate: %s\n' "$*" >&2; return 0; }

# ver_gt A B -> true if A is strictly newer than B (semantic sort).
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Legacy fallback only: run an UNPATCHED download through the loader. Breaks
# process.execPath (see header), so it is used only if patching ever fails.
run_raw() {
  if [ "$CLAUDE_OS" = "linux" ]; then
    "$CLAUDE_DYNAMIC_LINKER" --library-path "$CLAUDE_LIBRARY_PATH" "$@"
  else
    "$@"
  fi
}

# is_patched FILE -> true if FILE's ELF interpreter is already the Nix one.
is_patched() {
  [ "$("$CLAUDE_PATCHELF" --print-interpreter "$1" 2>/dev/null)" = "$CLAUDE_DYNAMIC_LINKER" ]
}

# patch_interp FILE: set ONLY the ELF interpreter (what autoPatchelfHook does
# to the pinned build; its DT_NEEDED is glibc-only so no rpath is required).
# Do NOT add --set-rpath: growing the rpath shifts the Bun single-file
# trailer and the binary segfaults (verified empirically on 2.1.202).
patch_interp() {
  "$CLAUDE_PATCHELF" --set-interpreter "$CLAUDE_DYNAMIC_LINKER" "$1" 2>/dev/null
}

# migrate_cached FILE: patch a cache entry left by an older launcher version,
# via copy + atomic rename so any running session keeps its old inode.
migrate_cached() {
  local tmp="$1.migrate.$$"
  cp -f "$1" "$tmp" 2>/dev/null || return 1
  if patch_interp "$tmp" && "$tmp" --version >/dev/null 2>&1; then
    mv -f "$tmp" "$1" && return 0
  fi
  rm -f "$tmp"
  return 1
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

  # Patch the interpreter AFTER verification so it execs directly (Linux only).
  if [ "$CLAUDE_OS" = "linux" ] && ! patch_interp "$dest.tmp"; then
    log "patchelf failed, discarding"; rm -f "$dest.tmp"; return 0
  fi

  # Only publish if the staged binary actually runs.
  if "$dest.tmp" --version >/dev/null 2>&1; then
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

# Downloads staged by an older launcher version are unpatched: patch them
# once, in place. If that fails, fall back to the legacy loader launch
# (works, but breaks Claude Code's in-session grep shims; see header).
if [ "$best_raw" = "1" ] && [ "$CLAUDE_OS" = "linux" ] && ! is_patched "$best_bin"; then
  if ! migrate_cached "$best_bin"; then
    log "migration failed, falling back to loader launch"
    exec "$CLAUDE_DYNAMIC_LINKER" --library-path "$CLAUDE_LIBRARY_PATH" "$best_bin" "$@"
  fi
fi
exec "$best_bin" "$@"
