{
  # For working on the rules and the persistent worker (tools/ghc-worker),
  # with each GHC the worker supports (those of its cabal file's tested-with,
  # which CI tests too):
  #
  # - `nix flake check -L`: one check per GHC, in parallel, of each of
  #   - the worker (worker-ghc9124, say): built, with -Werror and its
  #     benchmark, and its tests run;
  #   - the rules (rules-ghc9124): tests/rules/run.sh;
  #   - the rules with the worker (rules-worker-ghc9124);
  #   Each check runs several compiles at once, so on a machine with less
  #   memory than the checks need together, run fewer (`--max-jobs 2`).
  # - `nix develop .#ghc9141` (say): a shell with that GHC and cabal, the
  #   default shell's GHC being 9.12.
  description = "haskell-buck2: buck2 rules for Haskell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Keep in step with tested-with in tools/ghc-worker/ghc-worker.cabal and
      # the matrices of .github/workflows/ghc-worker.yml and rules.yml.
      ghcs = [ "ghc967" "ghc984" "ghc9103" "ghc9124" "ghc9141" ];
    in
    {
      checks = forAllSystems (pkgs:
        let
          inherit (nixpkgs) lib;
          inherit (pkgs.haskell.lib.compose) appendConfigureFlags doBenchmark doCheck overrideCabal;
          # Without the build directories of a checkout (cabal's dist-*,
          # buck2's buck-out), which `nix build path:.` would copy too.
          clean = src: lib.cleanSourceWith {
            inherit src;
            filter = path: type: !(lib.hasPrefix "dist-" (baseNameOf path) || baseNameOf path == "buck-out");
          };
          # The binary cache has little of a GHC's package set but the
          # default one's, so the worker's dependencies are built here: without
          # their tests or documentation, which the worker doesn't need.
          packages = ghc: pkgs.haskell.packages.${ghc}.override {
            overrides = self: super: {
              mkDerivation = args: super.mkDerivation (args // { doCheck = false; doHaddock = false; });
            };
          };
          # The test runs the worker it was built with, which `Setup test`
          # doesn't put on PATH as `cabal test` does.
          worker = ghc:
            overrideCabal (old: { preCheck = (old.preCheck or "") + "export GHC_WORKER=$PWD/dist/build/ghc-worker/ghc-worker\n"; })
              (appendConfigureFlags [ "--ghc-option=-Werror" ]
                (doCheck (doBenchmark ((packages ghc).callCabal2nix "ghc-worker" (clean ./tools/ghc-worker) { }))));
          rules = ghc: withWorker: pkgs.runCommandCC "rules-tests-${lib.optionalString withWorker "worker-"}${ghc}"
            {
              # clang: the C compiler of buck2's default C toolchain.
              nativeBuildInputs = [ pkgs.buck2 pkgs.python3 pkgs.clang ];
              GHC_WORKER = lib.optionalString withWorker "${worker ghc}/bin/ghc-worker";
              # Without the worker's sources (it comes in built, as
              # GHC_WORKER) or CI's, so that editing them doesn't rerun the
              # checks that don't use it.
              src = clean (lib.cleanSourceWith {
                src = ./.;
                filter = path: type: !(lib.hasPrefix (toString ./tools) path || lib.hasPrefix (toString ./.github) path);
              });
            } ''
            export HOME=$TMPDIR
            # The buck2 daemon reads them as it starts, though nothing here
            # goes to the network.
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            cp -r $src repo
            chmod -R u+w repo
            cd repo
            patchShebangs tests
            tests/rules/run.sh ${pkgs.haskell.compiler.${ghc}}/bin $TMPDIR/work
            touch $out
          '';
        in
        # The rules' tests on Linux alone, as CI runs them: their prebuilt
        # packages and LD_LIBRARY_PATH are Linux's.
        lib.listToAttrs (lib.concatMap (ghc: [
          { name = "worker-${ghc}"; value = worker ghc; }
        ] ++ lib.optionals pkgs.stdenv.isLinux [
          { name = "rules-${ghc}"; value = rules ghc false; }
          { name = "rules-worker-${ghc}"; value = rules ghc true; }
        ]) ghcs));

      devShells = forAllSystems (pkgs:
        let
          shell = ghc: pkgs.mkShell {
            packages = [ pkgs.haskell.compiler.${ghc} pkgs.cabal-install ];
          };
        in
        nixpkgs.lib.genAttrs ghcs shell // { default = shell "ghc9124"; });
    };
}
