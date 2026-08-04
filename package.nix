# @path: derivations/zcode/package.nix
# @author: redskaber
# @datetime: 2026-08-04
# @description: Nix derivation for ZCode (Electron-based AI IDE by Z.ai).
#
# Supports all four platforms that ZCode ships:
#   - x86_64-linux   (deb, opt/ZCode/* layout, autoPatchelf'd)
#   - aarch64-linux  (deb, same layout)
#   - x86_64-darwin  (dmg, ZCode.app bundle)
#   - aarch64-darwin (dmg, ZCode.app bundle)
#
# Build inputs for Linux were derived from `readelf -d opt/ZCode/zcode` on
# the actual 3.6.5 linux-x64 deb. macOS uses the standard Electron app
# bundle layout and does not need patching on a real Darwin host.

{ pkgs, system, sources }:

let
  srcInfo = sources.${system} or (throw "Unsupported system: ${system}");
  version = sources.version;
  isLinux = pkgs.stdenv.isLinux;
  isDarwin = pkgs.stdenv.isDarwin;

  # Linux runtime libraries (matched against `readelf -d zcode` NEEDED list).
  linuxBuildInputs = with pkgs; [
    # --- Electron / Chromium runtime deps (direct NEEDED) ---
    alsa-lib            # libasound.so.2
    at-spi2-atk         # libatk-bridge-2.0.so.0
    at-spi2-core        # libatspi.so.0
    atk                 # libatk-1.0.so.0
    cairo               # libcairo.so.2
    cups                # libcups.so.2
    dbus                # libdbus-1.so.3
    expat               # libexpat.so.1
    fontconfig          # libfontconfig.so.1 (transitive, needed by cairo/pango)
    freetype            # libfreetype.so.6  (transitive)
    gdk-pixbuf          # libgdk_pixbuf-2.0.so.0 (transitive, needed by gtk3)
    glib                # libglib-2.0.so.0 / libgobject-2.0.so.0 / libgio-2.0.so.0
    gtk3                # libgtk-3.so.0
    libGL               # libGL.so.1 (used by libEGL/libGLESv2)
    libX11              # libX11.so.6
    libXcomposite       # libXcomposite.so.1
    libXdamage          # libXdamage.so.1
    libXext             # libXext.so.6
    libXfixes           # libXfixes.so.3
    libXi               # libXi.so.6 (transitive, used by gtk3 / electron)
    libXrandr           # libXrandr.so.2
    libXrender          # libXrender.so.1 (transitive)
    libdrm              # libdrm.so.2 (transitive, used by mesa/gbm)
    libgbm              # libgbm.so.1
    libxcb              # libxcb.so.1
    libxkbcommon        # libxkbcommon.so.0
    libxshmfence        # libxshmfence.so.1 (transitive, used by mesa)
    mesa                # libGL / gbm drivers
    nspr                # libnspr4.so
    nss                 # libnss3.so / libnssutil3.so / libsmime3.so
    pango               # libpango-1.0.so.0
    systemd             # libudev.so.1
    zlib                # libz.so.1 (transitive)

    # --- Common Electron extras that the binary may dlopen at runtime ---
    libnotify           # libnotify.so.4 (desktop notifications)
    libsecret           # libsecret-1.so.0 (keyring integration)
    libuuid             # libuuid.so.1
    libxkbfile          # libxkbfile.so.1 (vscode-style keymap loading)
    libkrb5             # libgssapi_krb5.so.2 (remote auth)
    util-linux          # libmount.so.1 (transitive, used by glib)

    # --- Deep-link / URL scheme registration (zcode:// OAuth callback) ---
    # ZCode calls `update-desktop-database` and `xdg-mime` at startup to
    # register the `zcode://` scheme handler. Without these in PATH, the
    # browser cannot find the app after OAuth approval.
    desktop-file-utils  # update-desktop-database
    shared-mime-info    # update-mime-database (transitive)
    xdg-utils           # xdg-mime, xdg-open
  ];

  # On Linux we need autoPatchelfHook + dpkg + makeWrapper.
  linuxNativeBuildInputs = with pkgs; [
    autoPatchelfHook
    dpkg
    makeWrapper
  ];

  # On Darwin we need 7zz (or p7zip) to extract the .dmg, plus makeWrapper
  # to construct the launcher script. We do NOT use autoPatchelf on Darwin
  # (Mach-O binaries are pre-linked against @rpath and Apple's frameworks).
  darwinNativeBuildInputs = with pkgs; [
    _7zz
    makeWrapper
  ];

in pkgs.stdenv.mkDerivation rec {
  pname = "zcode";
  inherit version;

  src = pkgs.fetchurl {
    url = srcInfo.url;
    sha256 = srcInfo.sha256;
  };

  nativeBuildInputs = if isLinux then linuxNativeBuildInputs else darwinNativeBuildInputs;
  buildInputs = if isLinux then linuxBuildInputs else [ ];

  # autoPatchelf recurses into ALL ELF files in $out, including bundled
  # native node modules under resources/app.asar.unpacked. The ssh2 native
  # module in some ZCode builds ships an ARM64 binary even inside the x64
  # deb (upstream packaging bug); we ignore unresolved musl/aarch64 deps
  # so the build doesn't fail on that.
  autoPatchelfIgnoreMissingDeps = if isLinux then [
    "libc.musl-x86_64.so.1"
    "libc.musl-aarch64.so.1"
    "ld-musl-x86_64.so.1"
    "ld-musl-aarch64.so.1"
  ] else [ ];

  # ----------------------------------------------------------------- Linux
  unpackPhase = if isLinux then ''
    runHook preUnpack
    ar x $src
    tar -xvf data.tar.* --no-same-permissions --no-same-owner
    runHook postUnpack
  '' else ''
    runHook preUnpack
    # 7zz extracts the HFS+ payload of the dmg. The .app bundle ends up at
    # "ZCode 3.6.5/ZCode.app/" (x64) or "ZCode 3.6.5-arm64/ZCode.app/".
    # The dmg also contains a symlink to /Applications which 7zz refuses to
    # extract by default; we don't need it anyway.
    7zz x -y "$src" -o"$TMPDIR/dmg-extract" || true
    runHook postUnpack
  '';

  installPhase = if isLinux then ''
    runHook preInstall

    mkdir -p $out/bin $out/share/zcode
    mkdir -p $out/share/icons/hicolor $out/share/applications $out/share/doc/zcode

    # 1. Main Electron application payload.
    #    The deb layout is `opt/ZCode/*`; we relocate it under $out/share/zcode.
    if [ -d "opt/ZCode" ]; then
      cp -av opt/ZCode/* $out/share/zcode/
    elif [ -d "opt/zcode" ]; then
      cp -av opt/zcode/* $out/share/zcode/
    else
      echo "ERROR: expected opt/ZCode or opt/zcode in the deb" >&2
      exit 1
    fi

    # 1b. Remove chrome-sandbox (the setuid sandbox helper).
    #
    # ZCode writes `~/.local/share/applications/zcode.desktop` at runtime
    # with `Exec=<process.execPath> %U` — i.e. the RAW binary, not our
    # $out/bin/zcode wrapper. When the browser launches that desktop entry
    # to handle a `zcode://callback` URL, the binary starts WITHOUT
    # `--no-sandbox`. If chrome-sandbox is present, Electron tries to use
    # it as a setuid helper, which fails in the read-only /nix/store.
    # Removing chrome-sandbox forces Electron to fall back to the
    # user-namespace sandbox (kernel.unprivileged_userns_clone=1 on most
    # NixOS installs), which works without setuid.
    rm -f $out/share/zcode/chrome-sandbox

    # 2. Desktop entry, icons, changelog from usr/share/.
    if [ -d "usr/share/applications" ]; then
      cp -av usr/share/applications/* $out/share/applications/ 2>/dev/null || true
    fi
    if [ -d "usr/share/icons" ]; then
      cp -av usr/share/icons/* $out/share/icons/ 2>/dev/null || true
    fi
    if [ -d "usr/share/doc/zcode" ]; then
      cp -av usr/share/doc/zcode/* $out/share/doc/zcode/ 2>/dev/null || true
    fi

    # 3. Rewrite the desktop entry's Exec= line to point at our wrapper.
    for f in $out/share/applications/*.desktop; do
      [ -e "$f" ] || continue
      sed -i \
        -e "s|^Exec=.*|Exec=$out/bin/zcode %U|g" \
        -e "s|^TryExec=.*|TryExec=$out/bin/zcode|g" \
        -e "s|^Icon=.*|Icon=zcode|g" \
        "$f"
    done

    # 4. Wrapper script. We use `--no-sandbox` because Electron's setuid
    #    sandbox chrome-sandbox helper cannot survive the read-only store;
    #    `--enable-features=UseOzonePlatform` + `--ozone-platform-hint=auto`
    #    lets it run on Wayland out of the box and fall back to X11.
    #
    #    The PATH prefix is critical: ZCode's deep-link registration code
    #    calls `update-desktop-database` and `xdg-mime` at startup; without
    #    these tools in PATH, the `zcode://` scheme is never registered and
    #    the OAuth callback silently fails (browser can't find the app).
    makeWrapper $out/share/zcode/zcode $out/bin/zcode \
      --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath linuxBuildInputs}" \
      --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.desktop-file-utils pkgs.shared-mime-info pkgs.xdg-utils ]}" \
      --add-flags "--no-sandbox" \
      --add-flags "--enable-features=UseOzonePlatform" \
      --add-flags "--ozone-platform-hint=auto" \
      --set ZCODE_USER_DATA_DIR "$HOME/.zcode"

    runHook postInstall
  '' else ''
    runHook preInstall

    # Locate the extracted .app bundle.
    app_dir="$(find "$TMPDIR/dmg-extract" -name "ZCode.app" -type d -print -quit)"
    if [ -z "$app_dir" ]; then
      echo "ERROR: ZCode.app not found in dmg extraction" >&2
      exit 1
    fi

    # macOS layout: $out/Applications/ZCode.app
    mkdir -p "$out/Applications"
    cp -av "$app_dir" "$out/Applications/ZCode.app"

    # Strip Apple Extended Attributes / code-signature noise that 7zz
    # materializes as `*:com.apple.cs.*` pseudo-files; they confuse some
    # launchers and are not needed for ad-hoc use.
    find "$out/Applications/ZCode.app" -type f -name "*:com.apple.cs.*" -delete 2>/dev/null || true

    # Convenience launcher: $out/bin/zcode -> open -a ZCode.app
    mkdir -p "$out/bin"
    makeWrapper "${pkgs.writeShellScript "zcode-launcher" ''
      exec "/Applications/ZCode.app/Contents/MacOS/ZCode" "$@"
    ''}" "$out/bin/zcode" \
      --set ZCODE_USER_DATA_DIR "$HOME/.zcode"

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    homepage = "https://zcode.z.ai/";
    description = "ZCode — AI coding IDE by Z.ai (Electron desktop app)";
    longDescription = ''
      ZCode is an agentic AI coding IDE developed by Z.ai. It bundles a
      curated set of MCP servers, in-app skills, and model providers
      (GLM family) for code generation, refactoring, and project
      automation. This package wraps the official Linux deb and macOS
      dmg releases.
    '';
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    license = licenses.unfree;
    mainProgram = "zcode";
    maintainers = with lib.maintainers; [ redskaber ];
  };
}
