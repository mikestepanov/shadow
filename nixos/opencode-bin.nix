{ stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation rec {
  pname = "opencode";
  version = "1.3.15";

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
    hash = "sha256-7plxyuvcHasaP2A0nyMGh16Xp933E2KM+JuCwoKA6XE=";
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
