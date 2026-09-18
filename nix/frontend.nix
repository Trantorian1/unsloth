{
  pkgs,
  lib,
  version,
  src,
  ...
}:
pkgs.buildNpmPackage {
  pname = "unsloth-frontend";
  inherit version;
  src = "${src}/studio/frontend";

  # Every tarball comes straight from package-lock.json, so there is no
  # npmDepsHash to bump when the lockfile moves.
  npmDeps = pkgs.importNpmLock {
    npmRoot = "${src}/studio/frontend";
    # importNpmLock rewrites each dependency spec to a store path, and npm
    # then rejects an `overrides` entry that no longer matches its direct
    # dependency (EOVERRIDE). Point those at the dependency itself (npm's
    # `$name` form); the transitive overrides stay as written.
    package = let
      manifest = lib.importJSON "${src}/studio/frontend/package.json";
      direct = manifest.dependencies // (manifest.devDependencies or {});
    in
      manifest
      // {
        overrides =
          lib.mapAttrs (
            name: spec:
              if direct ? ${name}
              then "$" + name
              else spec
          )
          manifest.overrides;
      };
  };
  npmConfigHook = pkgs.importNpmLock.npmConfigHook;

  # `npm run build` (tsc -b && vite build) writes dist/.
  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';
}
