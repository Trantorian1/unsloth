{
  pkgs,
  lib,
  version,
  src,
  unsloth-frontend,
  ...
}:
pkgs.stdenv.mkDerivation {
  pname = "unsloth-desktop";
  inherit version src;

  cargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = "${src}/studio/src-tauri/Cargo.lock";
    # fix-path-env is a git dependency; let Nix fetch it by the locked
    # rev instead of maintaining an outputHashes entry.
    allowBuiltinFetchGit = true;
  };
  cargoRoot = "studio/src-tauri";
  buildAndTestSubdir = "studio/src-tauri";

  nativeBuildInputs = with pkgs; [
    cargo-tauri.hook # brings cargo
    rustPlatform.cargoSetupHook
    rustc
    pkg-config
    wrapGAppsHook3
  ];

  buildInputs = with pkgs; [
    webkitgtk_4_1 # propagates gtk3 and libsoup_3
    glib-networking # TLS for the webview (huggingface.co, updater manifest)
    libayatana-appindicator # tray icon; the deb bundler also looks it up
    # H.264 playback and capture in the webview, mirroring the CI apt list.
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-libav
  ];

  # Merged into tauri.conf.json (RFC 7396, so null deletes): the frontend is
  # already built, so drop the `npm run build` Tauri would run and point it at
  # the dist directly; updater artifacts would need a signing key.
  tauriBuildFlags = [
    "--config"
    (builtins.toJSON {
      build = {
        beforeBuildCommand = null;
        frontendDist = "${unsloth-frontend}";
      };
      bundle.createUpdaterArtifacts = false;
    })
  ];

  postPatch = ''
    # The tray icon crate dlopens the appindicator library by soname.
    substituteInPlace $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
      --replace-fail "libayatana-appindicator3.so.1" \
        "${pkgs.libayatana-appindicator}/lib/libayatana-appindicator3.so.1"
  '';

  # cargo-tauri.hook builds `--bundles deb` and installs the .deb's
  # data/usr tree into $out. That keeps Tauri's Linux layout intact:
  # bin/<app>, lib/<app>/install.sh (the resource the first-run installer
  # runs, from tauri.linux.conf.json), the .desktop entry and the icons.
  # Only the binary is renamed so it does not clash with the CLI's
  # bin/unsloth when both are installed into one profile.
  postInstall = ''
    # Tauri keeps cargo's binary name (unsloth-studio); ship it as
    # unsloth-desktop next to the CLI's bin/unsloth.
    mv $out/bin/unsloth-studio $out/bin/.unsloth-desktop-real
    # The app records its own /proc/self/exe for launch-at-login and
    # the unsloth:// handler. The sandbox launcher (flake.nix) binds the real
    # binary over its own path and names it here, so what gets recorded
    # is a path that starts the sandbox. Unset, this runs the binary.
    cat > $out/bin/unsloth-desktop <<EOF
    #!${pkgs.runtimeShell}
    exec "\''${UNSLOTH_DESKTOP_EXE:-$out/bin/.unsloth-desktop-real}" "\$@"
    EOF
    chmod +x $out/bin/unsloth-desktop
    sed -i -E 's|^Exec=\S+|Exec=unsloth-desktop|; s|^StartupWMClass=.*|StartupWMClass=unsloth-desktop|' \
      $out/share/applications/*.desktop
    # The first-run installer the app resolves through Tauri's resource dir.
    test -f $out/lib/*/install.sh
  '';

  # Wrap the shim (GIO modules, GStreamer, schemas), not the binary too.
  dontWrapGApps = true;
  preFixup = ''
    wrapGApp $out/bin/unsloth-desktop
  '';

  meta = {
    description = "Unsloth Desktop: the Tauri app around Unsloth Studio";
    homepage = "https://unsloth.ai";
    license = lib.licenses.agpl3Only;
    mainProgram = "unsloth-desktop";
  };
}
