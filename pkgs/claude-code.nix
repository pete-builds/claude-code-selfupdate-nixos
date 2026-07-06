# The pinned, reproducible Claude Code package.
#
# Fetches Anthropic's OFFICIAL native binary and pins it to Anthropic's OWN
# published sha256 (see ../data/sources.json, transcribed from the release
# manifest.json). No third-party flake, no third-party binary cache. This is
# the deterministic baseline; the self-updating wrapper (../lib) layers on top.
{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  # Allow callers to inject a different sources.json (used by the updater/tests).
  sources ? builtins.fromJSON (builtins.readFile ../data/sources.json),
}:

let
  inherit (sources) version;
  system = stdenvNoCC.hostPlatform.system;

  # nix system -> Anthropic platform key
  platformKey =
    {
      "x86_64-linux" = "linux-x64";
      "aarch64-linux" = "linux-arm64";
      "x86_64-darwin" = "darwin-x64";
      "aarch64-darwin" = "darwin-arm64";
    }
    .${system} or (throw "claude-code: unsupported system '${system}'");

  sha256 = sources.platforms.${platformKey};
  isLinux = stdenvNoCC.hostPlatform.isLinux;

  # GCS bucket mirror kept as a verbatim fallback for the official CDN.
  bucket = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819";
in
stdenvNoCC.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    urls = [
      "https://downloads.claude.ai/claude-code-releases/${version}/${platformKey}/claude"
      "${bucket}/claude-code-releases/${version}/${platformKey}/claude"
    ];
    inherit sha256;
  };

  dontUnpack = true;
  dontStrip = true; # Bun single-file exe: stripping corrupts its appended trailer.

  nativeBuildInputs = lib.optionals isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/claude
    runHook postInstall
  '';

  passthru = {
    inherit platformKey;
    inherit (sources) platforms;
  };

  meta = {
    description = "Claude Code CLI (official Anthropic native binary, own-hash pinned)";
    homepage = "https://github.com/pete-builds/claude-code-selfupdate-nixos";
    downloadPage = "https://claude.ai/code";
    license = lib.licenses.unfree; # Claude Code itself is unfree; this packaging is MIT.
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "claude";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
