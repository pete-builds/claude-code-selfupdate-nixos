# The self-updating variant: wraps the pinned `claude-code` with a launcher
# (../lib/claude-selfupdate.sh) that refreshes itself on launch. The pinned
# binary stays the guaranteed fallback; the launcher only ever runs a binary it
# has verified against Anthropic's own published checksum.
{
  lib,
  stdenvNoCC,
  stdenv,
  makeWrapper,
  claude-code,
  curl,
  jq,
  coreutils,
  util-linux, # flock (Linux); wrapper degrades gracefully without it
}:

let
  isLinux = stdenvNoCC.hostPlatform.isLinux;
  ld = stdenv.cc.bintools.dynamicLinker;
  # Raw downloads are run unmodified through this loader + library path (no patchelf,
  # so the checksum-verified bytes are never rewritten).
  libraryPath = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    stdenv.cc.libc
  ];

  runtimeBins =
    [ curl jq coreutils ]
    ++ lib.optionals isLinux [ util-linux ];
in
stdenvNoCC.mkDerivation {
  pname = "claude-code-selfupdate";
  inherit (claude-code) version;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ${../lib/claude-selfupdate.sh} $out/libexec/claude-selfupdate.sh
    makeWrapper $out/libexec/claude-selfupdate.sh $out/bin/claude \
      --set CLAUDE_PINNED_BIN ${claude-code}/bin/claude \
      --set CLAUDE_PINNED_VERSION ${claude-code.version} \
      --set CLAUDE_PLATFORM ${claude-code.passthru.platformKey} \
      --set CLAUDE_OS ${if isLinux then "linux" else "darwin"} \
      ${lib.optionalString isLinux "--set CLAUDE_DYNAMIC_LINKER ${ld} --set CLAUDE_LIBRARY_PATH ${libraryPath}"} \
      --prefix PATH : ${lib.makeBinPath runtimeBins}
    runHook postInstall
  '';

  passthru = { pinned = claude-code; };

  meta = claude-code.meta // {
    description = "Claude Code that self-updates on launch, verified against Anthropic's own checksums";
    mainProgram = "claude";
  };
}
