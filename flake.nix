{
  description = "docling.rs — a Rust port of docling (document conversion to Markdown / docling-JSON / DCLX)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
      version = cargoToml.workspace.package.version;
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          inherit (pkgs) lib;

          # `ort`'s default `download-binaries` fetches ONNX Runtime at build
          # time, which the Nix sandbox forbids. The `ort-load-dynamic` feature
          # (#504) skips that step and `dlopen`s the runtime instead; the
          # wrapper points it at nixpkgs' onnxruntime through ORT_DYLIB_PATH.
          ortLib = "${pkgs.onnxruntime}/lib/libonnxruntime${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";

          mkDocling =
            {
              pname,
              cargoPackage,
              bins,
              extraFeatures ? [ ],
              extraBuildInputs ? [ ],
            }:
            pkgs.rustPlatform.buildRustPackage {
              inherit pname version;

              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./Cargo.toml
                  ./Cargo.lock
                  ./crates
                  # README.md is `readme =` in several manifests and some
                  # crates `include_str!` docs from the repo root.
                  ./README.md
                  ./docs
                ];
              };

              cargoLock.lockFile = ./Cargo.lock;

              cargoBuildFlags = [
                "-p"
                cargoPackage
              ];
              buildFeatures = [ "ort-load-dynamic" ] ++ extraFeatures;

              nativeBuildInputs = [
                pkgs.pkg-config
                pkgs.makeWrapper
              ];
              # `onig_sys` (tokenizers) links the system oniguruma: nixpkgs sets
              # RUSTONIG_SYSTEM_LIBONIG, so its vendored copy is not built.
              buildInputs = [
                pkgs.openssl
                pkgs.oniguruma
              ]
              ++ extraBuildInputs;

              # The test suites need `.models/` (and the docling-parse shim for
              # the PDF baselines); run them from the dev shell instead.
              doCheck = false;

              postInstall = ''
                for bin in ${lib.concatStringsSep " " bins}; do
                  wrapProgram $out/bin/$bin \
                    --set-default ORT_DYLIB_PATH ${ortLib} \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.ffmpeg-headless ]}
                done
              '';

              meta = {
                description = cargoToml.workspace.package.description or "Rust port of docling";
                homepage = "https://github.com/docling-project/docling.rs";
                license = lib.licenses.mit;
                mainProgram = builtins.head bins;
              };
            };
        in
        rec {
          docling-rs = mkDocling {
            pname = "docling-rs";
            cargoPackage = "docling-cli";
            bins = [ "docling-rs" ];
            extraFeatures = [ "serve" ];
          };
          docling-serve = mkDocling {
            pname = "docling-serve";
            cargoPackage = "docling-serve";
            bins = [ "docling-serve" ];
          };
          # Default features: SQLite (+ sqlite-vec) store, HTTP
          # embedders (Ollama & co.); conversion runs through the same
          # dynamically loaded ONNX Runtime.
          docling-rag = mkDocling {
            pname = "docling-rag";
            cargoPackage = "docling-rag";
            bins = [ "docling-rag" ];
            # libsqlite3-sys is built without its `bundled` feature here, so
            # it links the system libsqlite3.
            extraBuildInputs = [ pkgs.sqlite ];
          };
          default = docling-rs;
        }
      );

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.docling-rs;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.docling-rs ];

          packages = with pkgs; [
            # Toolchain: nixpkgs' stable rustc is above the 1.92 MSRV; CI
            # lints on 1.96.
            cargo
            rustc
            clippy
            rustfmt
            rust-analyzer

            # Bindings: maturin for crates/docling-py, node for docling-node,
            # wasm-bindgen + lld for docling-wasm.
            maturin
            python3
            nodejs
            wasm-bindgen-cli
            lld

            # Runtime tools the pipeline shells out to / the scripts use.
            ffmpeg-headless
            onnxruntime
            libheif # `heif` feature
            curl
            jq
          ];

          # In the shell the default `download-binaries` path works (it runs
          # outside the sandbox); build with `--features ort-load-dynamic` to
          # use nixpkgs' runtime instead, which this variable points at.
          ORT_DYLIB_PATH = "${pkgs.onnxruntime}/lib/libonnxruntime${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          # See CLAUDE.md "Disk discipline".
          CARGO_INCREMENTAL = "0";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
