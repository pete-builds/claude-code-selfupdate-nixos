#!/usr/bin/env bash
# update.sh — regenerate data/sources.json from Anthropic's release channel.
#
# Fetches the latest version and its manifest.json, VERIFIES Anthropic's GPG
# signature over that manifest against the pinned release key, then transcribes
# Anthropic's OWN published sha256 for every platform and rewrites
# data/sources.json. Run by CI (hourly) and available as `nix run .#update`. No
# third-party data; every hash comes straight from a signature-verified manifest.
set -euo pipefail

RELEASES="https://downloads.claude.ai/claude-code-releases"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SRC="$ROOT/data/sources.json"
SIGNING_KEY="$ROOT/data/claude-code-signing-key.asc"
SIGNING_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
# NOTE: there used to be a SIG_FLOOR here, below which the signature check was
# skipped ("predates signed manifests"). It is gone deliberately. The floor was
# compared against the version string the network had just handed us, so the
# attacker chose whether verification ran: answer "2.1.88" and the whole check
# was skipped by design, and the resulting checksums were auto-committed and
# pushed to a public repo by the hourly workflow. The pinned key is this
# project's one differentiator, and that branch handed it back on request.
# The pinned version is far above the old floor, so nothing legitimate needs it.

latest="$(curl -fsS "$RELEASES/latest" | tr -d '[:space:]')"
case "$latest" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "update: unexpected version string '$latest'" >&2; exit 1 ;;
esac

# Verify a detached signature with ONLY the pinned key, in a throwaway keyring,
# requiring the signer's primary-key fingerprint to equal SIGNING_FPR.
verify_sig() { # verify_sig <signed-file> <detached-sig>
  command -v gpg >/dev/null 2>&1 || { echo "update: gpg not found" >&2; return 1; }
  [ -r "$SIGNING_KEY" ] || { echo "update: pinned key missing at $SIGNING_KEY" >&2; return 1; }
  local gh sfd
  gh="$(mktemp -d)"; chmod 700 "$gh"
  if ! GNUPGHOME="$gh" gpg --batch --quiet --import "$SIGNING_KEY" 2>/dev/null; then
    rm -rf "$gh"; echo "update: key import failed" >&2; return 1
  fi
  sfd="$(GNUPGHOME="$gh" gpg --batch --status-fd 1 --verify "$2" "$1" 2>/dev/null)"
  rm -rf "$gh"
  printf '%s\n' "$sfd" | grep -q "^\[GNUPG:\] VALIDSIG .* ${SIGNING_FPR}\$"
}

manifest_file="$(mktemp)"; sig_file="$(mktemp)"
trap 'rm -f "$manifest_file" "$sig_file"' EXIT
curl -fsS -o "$manifest_file" "$RELEASES/$latest/manifest.json"

# Signature verification is unconditional and fails closed. No version-derived
# escape hatch: the version comes from the network, so any such hatch is the
# attacker's to open.
curl -fsS -o "$sig_file" "$RELEASES/$latest/manifest.json.sig"
if ! verify_sig "$manifest_file" "$sig_file"; then
  echo "update: manifest signature verification FAILED for $latest, refusing to write sources.json" >&2
  exit 1
fi
echo "update: manifest signature verified for $latest" >&2

manifest="$(cat "$manifest_file")"

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
