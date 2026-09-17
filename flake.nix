{
  # Nix flake for the `unsloth` CLI and the Unsloth desktop app, built from
  # this checkout. Three derivations, sharing one frontend build:
  #
  #   unsloth-frontend  studio/frontend  ->  the Vite `dist/` the other two embed
  #   unsloth           the Python CLI (pip's `unsloth` wheel, base extras only)
  #   unsloth-desktop   studio/src-tauri, the Tauri app that ships as the .deb
  #
  # Both leaves reuse the upstream build path (npm run build, python -m build's
  # setuptools backend, cargo tauri build --bundles deb) instead of re-describing
  # it. What the app installs for itself on first launch (uv-managed Python,
  # torch, llama.cpp / whisper.cpp prebuilts, node) is still downloaded into
  # ~/.unsloth/studio by install.sh / setup.sh exactly as on any other distro;
  # the wrappers below only put the tools those scripts probe for on PATH and
  # libvulkan where the Vulkan llama.cpp prebuilt (AMD/Intel GPUs) can dlopen it.
  # Those downloaded binaries are foreign ELF, so on NixOS run with
  # `programs.nix-ld.enable = true` (plus the GPU's driver in NIX_LD_LIBRARY_PATH).
  description = "Unsloth CLI and Unsloth Desktop, built from source";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # pyproject.toml reads the version from this attribute too.
      version = builtins.head (
        builtins.match ".*__version__ = \"([^\"]+)\".*" (builtins.readFile ./unsloth/_version.py)
      );
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          inherit (pkgs) lib;

          # What install.sh / setup.sh and the desktop app exec on Linux and never
          # fetch themselves: a POSIX userland, a download transport, the GPU probe
          # (lspci decides AMD/Intel vs NVIDIA and picks the ROCm/Vulkan bundles),
          # a port checker (ss), uv for the managed venv, and xdg-open.
          runtimeTools = with pkgs; [
            bash
            coreutils
            findutils
            gawk
            gnugrep
            gnused
            gnutar
            gzip
            getent
            procps
            util-linux
            curl
            git
            pciutils
            iproute2
            uv
            python3
            xdg-utils
          ];
          runtimeLibs = with pkgs; [
            vulkan-loader
          ];
          wrapperArgs = [
            "--prefix"
            "PATH"
            ":"
            (lib.makeBinPath runtimeTools)
            "--prefix"
            "LD_LIBRARY_PATH"
            ":"
            (lib.makeLibraryPath runtimeLibs)
          ];
        in
        rec {
          unsloth-frontend = pkgs.buildNpmPackage {
            pname = "unsloth-frontend";
            inherit version;
            src = ./studio/frontend;

            # Every tarball comes straight from package-lock.json, so there is no
            # npmDepsHash to bump when the lockfile moves.
            npmDeps = pkgs.importNpmLock {
              npmRoot = ./studio/frontend;
              # importNpmLock rewrites each dependency spec to a store path, and npm
              # then rejects an `overrides` entry that no longer matches its direct
              # dependency (EOVERRIDE). Point those at the dependency itself (npm's
              # `$name` form); the transitive overrides stay as written.
              package =
                let
                  manifest = lib.importJSON ./studio/frontend/package.json;
                  direct = manifest.dependencies // (manifest.devDependencies or { });
                in
                manifest
                // {
                  overrides = lib.mapAttrs (
                    name: spec: if direct ? ${name} then "$" + name else spec
                  ) manifest.overrides;
                };
            };
            npmConfigHook = pkgs.importNpmLock.npmConfigHook;

            # `npm run build` (tsc -b && vite build) writes dist/.
            installPhase = ''
              runHook preInstall
              cp -r dist $out
              runHook postInstall
            '';
          };

          unsloth = pkgs.python3Packages.buildPythonApplication {
            pname = "unsloth";
            inherit version;
            pyproject = true;
            src = self;

            build-system = with pkgs.python3Packages; [
              setuptools
              setuptools-scm
            ];
            # pyproject.toml pins exact setuptools / setuptools-scm versions that
            # nixpkgs does not carry; the newer ones build the wheel the same way.
            pypaBuildFlags = [ "--skip-dependency-check" ];

            # pyproject.toml [project.dependencies]. The `studio` extra (torch,
            # fastapi, ...) is not installed here: `unsloth studio setup` builds
            # that stack into ~/.unsloth/studio with uv, and `unsloth studio run`
            # re-execs into it, the same as a plain `pip install unsloth`.
            dependencies = with pkgs.python3Packages; [
              typer
              rich
              pydantic
              pyyaml
              nest-asyncio
              huggingface-hub
              structlog
              click
            ];

            # The wheel ships studio/frontend/dist (see [tool.setuptools.package-data]).
            postPatch = ''
              cp -r --no-preserve=mode ${unsloth-frontend} studio/frontend/dist
            '';

            makeWrapperArgs = wrapperArgs;

            # The suites need the studio extra and a GPU.
            doCheck = false;
            pythonImportsCheck = [ "unsloth_cli" ];
            postInstallCheck = ''
              $out/bin/unsloth --help >/dev/null
            '';

            meta = {
              description = "Unsloth CLI: train, export, chat and run Unsloth Studio";
              homepage = "https://unsloth.ai";
              license = lib.licenses.asl20;
              mainProgram = "unsloth";
            };
          };

          unsloth-desktop = pkgs.stdenv.mkDerivation {
            pname = "unsloth-desktop";
            inherit version;
            src = self;

            cargoDeps = pkgs.rustPlatform.importCargoLock {
              lockFile = ./studio/src-tauri/Cargo.lock;
              # fix-path-env is a git dependency; let Nix fetch it by the locked
              # rev instead of maintaining an outputHashes entry.
              allowBuiltinFetchGit = true;
            };
            cargoRoot = "studio/src-tauri";
            buildAndTestSubdir = "studio/src-tauri";

            nativeBuildInputs = with pkgs; [
              cargo-tauri.hook
              rustPlatform.cargoSetupHook
              cargo
              rustc
              pkg-config
              jq
              wrapGAppsHook3
            ];

            buildInputs = with pkgs; [
              webkitgtk_4_1
              gtk3
              libsoup_3
              openssl
              glib-networking # TLS for the webview (huggingface.co, updater manifest)
              libayatana-appindicator # tray icon
              # H.264 playback and capture in the webview, mirroring the CI apt list.
              gst_all_1.gst-plugins-base
              gst_all_1.gst-plugins-good
              gst_all_1.gst-plugins-bad
              gst_all_1.gst-libav
            ];

            postPatch = ''
              # The frontend is already built; drop the `npm run build` Tauri would
              # run and give it the dist it expects at ../frontend/dist.
              cp -r --no-preserve=mode ${unsloth-frontend} studio/frontend/dist
              jq 'del(.build.beforeBuildCommand) | .bundle.createUpdaterArtifacts = false' \
                studio/src-tauri/tauri.conf.json > tauri.conf.json.tmp
              mv tauri.conf.json.tmp studio/src-tauri/tauri.conf.json

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
              find $out -maxdepth 3 -not -path '*/icons/*'
              # Tauri keeps cargo's binary name (unsloth-studio); ship it as
              # unsloth-desktop next to the CLI's bin/unsloth.
              mv $out/bin/unsloth-studio $out/bin/unsloth-desktop
              sed -i -E 's|^Exec=\S+|Exec=unsloth-desktop|; s|^StartupWMClass=.*|StartupWMClass=unsloth-desktop|' \
                $out/share/applications/*.desktop
              # The first-run installer the app resolves through Tauri's resource dir.
              test -f $out/lib/*/install.sh
            '';

            preFixup = ''
              gappsWrapperArgs+=(${lib.escapeShellArgs wrapperArgs})
            '';

            meta = {
              description = "Unsloth Desktop: the Tauri app around Unsloth Studio";
              homepage = "https://unsloth.ai";
              license = lib.licenses.agpl3Only;
              mainProgram = "unsloth-desktop";
            };
          };

          default = unsloth-desktop;
        }
      );
    };
}
