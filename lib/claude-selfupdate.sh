#!/usr/bin/env bash
# claude-selfupdate.sh — a Claude Code launcher that keeps itself current.
#
# On every launch it execs the best binary it already has (instant, works
# offline), and in the BACKGROUND checks Anthropic's release channel. If a
# newer version exists it verifies Anthropic's GPG signature over the release
# manifest, then downloads the binary and verifies it against the sha256 in
# that signed manifest, and stages it so the NEXT launch is current. A
# downloaded binary is run UNMODIFIED (byte-identical to what we verified) via
# Nix's dynamic loader, so nothing is ever run without a signature-anchored
# checksum match, and the verified bytes are never rewritten. The Nix-pinned
# build is the permanent fallback, so `claude` always works even if every
# network or verification step fails (fail-closed: no verify, no stage).
#
# Environment (set by the Nix wrapper; do not hand-edit):
#   CLAUDE_PINNED_BIN       reproducible Nix-built binary (fallback, runs directly)
#   CLAUDE_PINNED_VERSION   its version
#   CLAUDE_PLATFORM         Anthropic platform key, e.g. linux-x64 / darwin-arm64
#   CLAUDE_OS               linux | darwin
#   CLAUDE_DYNAMIC_LINKER   (linux) ELF interpreter used to run raw downloads
#   CLAUDE_LIBRARY_PATH     (linux) --library-path for raw downloads
#   CLAUDE_SIGNING_KEY      pinned Anthropic release public key (ASCII-armored)
#   CLAUDE_SIGNING_FPR      expected primary-key fingerprint of that key
#   CLAUDE_SELFUPDATE       0 disables the update check (just runs pinned)
set -uo pipefail

RELEASES="https://downloads.claude.ai/claude-code-releases"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-selfupdate"
STATE="$CACHE/current" # "<version>\t<path>" of the newest verified download

log() { [ -n "${CLAUDE_SELFUPDATE_DEBUG:-}" ] && printf 'claude-selfupdate: %s\n' "$*" >&2; return 0; }

# ver_gt A B -> true if A is strictly newer than B (semantic sort).
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Verify a detached GPG signature over a file using ONLY the pinned Anthropic
# key, in a throwaway keyring, and require the signer's primary-key fingerprint
# to equal CLAUDE_SIGNING_FPR. Returns 0 only on a cryptographically good
# signature from exactly that key. Fail-closed: any missing tool, missing key,
# or unexpected output is a non-zero return.
verify_sig() { # verify_sig <signed-file> <detached-sig>
  command -v gpg >/dev/null 2>&1 || { log "gpg unavailable, cannot verify"; return 1; }
  [ -n "${CLAUDE_SIGNING_KEY:-}" ] && [ -r "$CLAUDE_SIGNING_KEY" ] || { log "no pinned key"; return 1; }
  [ -n "${CLAUDE_SIGNING_FPR:-}" ] || { log "no pinned fingerprint"; return 1; }
  local gh sfd
  gh="$(mktemp -d "${TMPDIR:-/tmp}/ccsu-gpg.XXXXXX")" || return 1
  chmod 700 "$gh"
  if ! GNUPGHOME="$gh" gpg --batch --quiet --import "$CLAUDE_SIGNING_KEY" 2>/dev/null; then
    rm -rf "$gh"; log "key import failed"; return 1
  fi
  sfd="$(GNUPGHOME="$gh" gpg --batch --status-fd 1 --verify "$2" "$1" 2>/dev/null)"
  rm -rf "$gh"
  # A VALIDSIG line whose trailing token is the pinned primary-key fingerprint.
  printf '%s\n' "$sfd" | grep -q "^\[GNUPG:\] VALIDSIG .* ${CLAUDE_SIGNING_FPR}\$" \
    || { log "signature not valid for pinned key"; return 1; }
  return 0
}

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

  # Fetch the manifest AND its detached signature, then verify the signature
  # with the pinned Anthropic key before trusting anything the manifest says.
  local mdir man sig
  mdir="$CACHE/versions/$latest"
  man="$mdir/manifest.json"
  sig="$mdir/manifest.json.sig"
  curl -fsS --max-time 10 -o "$man" "$RELEASES/$latest/manifest.json" 2>/dev/null \
    || { log "manifest fetch failed"; return 0; }
  curl -fsS --max-time 10 -o "$sig" "$RELEASES/$latest/manifest.json.sig" 2>/dev/null \
    || { log "signature fetch failed"; rm -f "$man" "$sig"; return 0; }
  if ! verify_sig "$man" "$sig"; then
    log "manifest signature verification failed, refusing update"
    rm -f "$man" "$sig"; return 0
  fi

  # The checksum now comes from a SIGNATURE-VERIFIED manifest, not a raw fetch.
  local sum
  sum="$(jq -r --arg p "$CLAUDE_PLATFORM" '.platforms[$p].checksum // empty' "$man" 2>/dev/null)" || return 0
  [ -n "$sum" ] || { log "no checksum for $CLAUDE_PLATFORM"; rm -f "$man" "$sig"; return 0; }

  curl -fsS --max-time 300 -o "$dest.tmp" "$RELEASES/$latest/$CLAUDE_PLATFORM/claude" 2>/dev/null \
    || { rm -f "$dest.tmp"; return 0; }

  # VERIFY the binary against the checksum from the signed manifest.
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
