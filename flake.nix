{
  # Nix flake for the `unsloth` CLI and the Unsloth desktop app, built from
  # this checkout. Three builds, sharing one frontend build:
  #
  #   unsloth-frontend          studio/frontend  ->  the Vite `dist/` the other two embed
  #   unsloth-unwrapped         the Python CLI (pip's `unsloth` wheel, base extras only)
  #   unsloth-desktop-unwrapped studio/src-tauri, the Tauri app that ships as the .deb
  #
  # Both leaves reuse the upstream build path (npm run build, python -m build's
  # setuptools backend, cargo tauri build --bundles deb) instead of re-describing
  # it. What the app installs for itself on first launch (uv-managed Python,
  # torch, llama.cpp / whisper.cpp prebuilts, node) is still downloaded into
  # ~/.unsloth/studio by install.sh / setup.sh exactly as on any other distro.
  #
  # Those downloads are ordinary Linux binaries that expect /lib64/ld-linux*.so
  # and libstdc++ in /usr/lib, which a Nix store does not have. So the public
  # `unsloth` and `unsloth-desktop` outputs run the unwrapped builds inside a
  # buildFHSEnv sandbox: an FHS view of the libraries and tools those binaries
  # and the install scripts need, on top of the real home, /tmp, /run, /dev and
  # /run/opengl-driver (Vulkan ICDs, libGL). No nix-ld or host setup required.
  description = "Unsloth CLI and Unsloth Desktop, built from source";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    # pyproject.toml reads the version from this attribute too.
    version = builtins.head (
      builtins.match ".*__version__ = \"([^\"]+)\".*" (builtins.readFile ./unsloth/_version.py)
    );
  in {
    packages = forAllSystems (
      pkgs: let
        inherit (pkgs) lib;

        # Ignores nix files, so editing them does not rebuild the frontend, the
        # wheel or the Tauri crate.
        src = nixpkgs.lib.fileset.toSource {
          root = ./.;
          fileset = nixpkgs.lib.fileset.difference ./. (
            nixpkgs.lib.fileset.unions [
              ./flake.nix
              ./flake.lock
              ./nix
            ]
          );
        };

        # Runtime dependencies which unsloth or unsloth-desktop won't autofetch
        # on their own
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
          desktop-file-utils
        ];

        runtimeLibs = with pkgs; [
          stdenv.cc.cc.lib # libstdc++, libgcc_s, libgomp
          zlib
          bzip2
          xz
          libffi
          libxcrypt-legacy
          ncurses
          openssl
          expat
          vulkan-loader
          libGL
          libdrm
          numactl
          elfutils
        ];

        targetPkgs = _: runtimeTools ++ runtimeLibs;

        # Bundles the resulting executables in a FHS sandbox to accomodate for
        # Unsloth's runtime dependency fetching
        wrapPackage = package: attrs:
          pkgs.buildFHSEnv ({
              inherit targetPkgs;

              runScript = lib.getExe package;
              meta = package.meta;
            }
            // attrs);
      in rec {
        unsloth-frontend = pkgs.callPackage ./nix/frontend.nix {
          inherit version src;
        };

        unsloth-unwrapped = pkgs.callPackage ./nix/unsloth-unwrapped.nix {
          inherit version src;
        };

        unsloth-desktop-unwrapped = pkgs.callPackage ./nix/unsloth-desktop-unwrapped.nix {
          inherit version src unsloth-frontend;
        };

        unsloth = wrapPackage unsloth-unwrapped {
          name = "unsloth";
        };

        unsloth-desktop = wrapPackage unsloth-desktop-unwrapped {
          name = "unsloth-desktop";
        };

        default = unsloth-desktop;
      }
    );
  };
}
