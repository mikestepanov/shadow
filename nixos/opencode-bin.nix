{ stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation rec {
  pname = "opencode";
  version = "1.14.25";

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
    hash = "sha256-ZULblz+/QEcH0nXYJPzX7vIKgAN4gRTrhQZ0Atr3MNs=";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    tar -xzf "$src"
    install -Dm755 opencode "$out/bin/opencode"
    runHook postInstall
  '';
}
