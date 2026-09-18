{
  pkgs,
  lib,
  version,
  src,
  ...
}:
pkgs.python3Packages.buildPythonApplication {
  pname = "unsloth";
  inherit version src;
  pyproject = true;

  build-system = with pkgs.python3Packages; [
    setuptools
    setuptools-scm
  ];
  # pyproject.toml pins exact setuptools / setuptools-scm versions that
  # nixpkgs does not carry; the newer ones build the wheel the same way.
  pypaBuildFlags = ["--skip-dependency-check"];

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

  # The suites need the studio extra and a GPU.
  doCheck = false;
  pythonImportsCheck = ["unsloth_cli"];
  postInstallCheck = ''
    $out/bin/unsloth --help >/dev/null
  '';

  meta = {
    description = "Unsloth CLI: train, export, chat and run Unsloth Studio";
    homepage = "https://unsloth.ai";
    license = lib.licenses.asl20;
    mainProgram = "unsloth";
  };
}
