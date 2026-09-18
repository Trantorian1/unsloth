{
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
    formatter = forAllSystems (pkgs: pkgs.alejandra);

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

        # What the sandbox adds on top of buildFHSEnv's base set (glibc,
        # libstdc++, bash, coreutils, gawk, sed, grep, tar, gzip, bzip2, xz):
        # the tools install.sh / setup.sh and the desktop app exec and never
        # fetch themselves, plus the two libraries the downloaded binaries
        # still link against (zlib for the wheels, libvulkan for the Vulkan
        # llama.cpp prebuilt on AMD and Intel GPUs).
        targetPkgs = _:
          with pkgs; [
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
            zlib
            vulkan-loader
          ];

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

          executableName = ".unsloth-desktop-fhs";
          extraBwrapArgs = [
            ''''${UNSLOTH_DESKTOP_EXE:+--ro-bind ${unsloth-desktop-unwrapped}/bin/.unsloth-desktop-real "$UNSLOTH_DESKTOP_EXE"}''
          ];
          extraInstallCommands = ''
            cat > $out/bin/unsloth-desktop <<EOF
            #!${pkgs.runtimeShell}
            export UNSLOTH_DESKTOP_EXE=$out/bin/unsloth-desktop
            exec $out/bin/.unsloth-desktop-fhs "\$@"
            EOF
            chmod +x $out/bin/unsloth-desktop
            ln -s ${unsloth-desktop-unwrapped}/lib $out/lib
            ln -s ${unsloth-desktop-unwrapped}/share $out/share
          '';
        };

        default = unsloth-desktop;
      }
    );

    apps = forAllSystems (
      pkgs: let
        inherit (pkgs) lib;
        packages = self.packages.${pkgs.stdenv.hostPlatform.system};
      in rec {
        unsloth-desktop = {
          type = "app";
          program = lib.getExe packages.unsloth-desktop;
          meta = packages.unsloth-desktop.meta;
        };

        default = unsloth-desktop;
      }
    );
  };
}
