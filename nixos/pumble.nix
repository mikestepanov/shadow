{ pkgs ? import <nixpkgs> {} }:

let
  pname = "pumble";
  version = "1.4.6";

  src = pkgs.fetchurl {
    url = "https://pumble.com/download/desktop/linux/Pumble-linux-${version}.deb";
    sha256 = "1rgj5m1jsx9v6bgrsa8x6rbqxvb523s404845bvf3k0hz0p7njy2";
  };

  runtimeLibs = with pkgs; [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libdrm
    libgbm
    libglvnd
    libxkbcommon
    mesa
    nspr
    nss
    pango
    systemd
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb
  ];

in pkgs.stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = with pkgs; [
    autoPatchelfHook
    dpkg
    makeWrapper
  ];

  buildInputs = runtimeLibs;

  unpackPhase = ''
    dpkg-deb -x $src .
  '';

  installPhase = ''
    mkdir -p $out/bin $out/opt $out/share/applications $out/share/icons

    cp -r opt/Pumble $out/opt/
    cp -r usr/share/icons/* $out/share/icons/

    # Create desktop file with correct path and URL handler
    cat > $out/share/applications/pumble-desktop.desktop << EOF
    [Desktop Entry]
    Name=Pumble
    Exec=$out/bin/pumble %U
    Terminal=false
    Type=Application
    Icon=pumble-desktop
    StartupWMClass=Pumble
    MimeType=x-scheme-handler/pumble;
    Categories=Network;Office;
    EOF

    makeWrapper $out/opt/Pumble/pumble-desktop $out/bin/pumble \
      --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath runtimeLibs}"
  '';

  meta = with pkgs.lib; {
    description = "Pumble - Team communication app";
    homepage = "https://pumble.com";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
  };
}
