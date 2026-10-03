{
  description = "threepp — a C++20 port of three.js: library, examples, tests, editor and Python bindings";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        # x86_64-darwin is being removed from nixpkgs and no longer evaluates
        # on unstable; aarch64-darwin is kept but is untested here.
        "aarch64-darwin"
      ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # physx and v-hacd join the package set, so a plain
      # callPackage ./default.nix finds them by name the way it finds glfw.
      overlays.default = final: _prev: {
        physx = final.callPackage ./physx.nix { };
        v-hacd = final.callPackage ./v-hacd.nix { };
        threepp = final.callPackage ./default.nix { };
      };

      packages = eachSystem (
        pkgs:
        let
          # default.nix defaults physx and v-hacd to these same two files, so
          # there is nothing to thread through — the derivations below and the
          # two exposed here are the same ones.
          threepp' = pkgs.callPackage ./default.nix;
        in
        rec {
          physx = pkgs.callPackage ./physx.nix { };
          v-hacd = pkgs.callPackage ./v-hacd.nix { };

          threepp = threepp' { };
          threepp-static = threepp' { withStaticLib = true; };
          threepp-vulkan = threepp' { withVulkan = true; };
          threepp-examples = threepp' { withExamples = true; };
          threepp-tests = threepp' { withTests = true; };
          threepp-editor = threepp' { withEditor = true; };
          threepp-python = threepp' { withPython = true; };
          threepp-vulkan-examples = threepp' {
            withVulkan = true;
            withExamples = true;
          };

          # The physics-enabled halves. Each one unlocks code the others cannot
          # reach: the examples gain Vehicle/FPS/Spot/RobotCell/Drive/Physics,
          # the editor gains its Play physics session, and the suite gains the
          # PhysX tests under tests/extras and tests/renderers.
          threepp-examples-physx = threepp' {
            withExamples = true;
            withPhysx = true;
          };
          threepp-editor-physx = threepp' {
            withEditor = true;
            withPhysx = true;
          };
          threepp-tests-physx = threepp' {
            withTests = true;
            withPhysx = true;
          };
          # The Python module as upstream actually ships it: the wheel CI builds
          # it with vcpkg's physx feature (.github/workflows/wheels.yml), and
          # python/examples assumes it — imu_demo.py, physics_demo.py and the
          # cartpole scripts all open with `if not tp.HAS_PHYSX: ... sys.exit`.
          threepp-python-physx = threepp' {
            withPython = true;
            withPhysx = true;
            withVulkan = true;
          };

          default = threepp;
        }
      );

      checks = eachSystem (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system})
          threepp
          threepp-static
          # Builds the Catch2 suite and runs all 139 of them. The heaviest thing
          # `nix flake check` does here, and the point of having checks at all.
          threepp-tests
          ;
      });

      devShells = eachSystem (
        pkgs:
        let
          inherit (pkgs) lib;
          # The dlopen'd set again, for an interactive build: nothing runs
          # postFixup there, so the loader has to be told where they are.
          runtimeLibs = lib.optionals pkgs.stdenv.hostPlatform.isLinux (
            with pkgs;
            [
              libGL
              alsa-lib
              libpulseaudio
              libjack2
              vulkan-loader
            ]
          );
        in
        {
          # For the scripts under python/examples. They are written for an
          # in-tree build: hello_cube.py:11 does
          #   sys.path.insert(0, dirname(dirname(abspath(__file__))))
          # which puts the SOURCE python/ directory ahead of site-packages. That
          # directory has threepp/__init__.py but no compiled extension, so the
          # import resolves to the source package, `from .threepp import *`
          # lands on the .pyi stub directory (a namespace package — it has no
          # __init__.py), and the first call fails with
          #   AttributeError: module 'threepp' has no attribute 'Canvas'
          # An env with threepp installed is therefore NOT enough on its own.
          # Linking the built extension into python/threepp/ is what
          # python/CMakeLists.txt:220 does for a normal dev build, and it is
          # what makes the examples' own path trick resolve.
          python =
            let
              # The PhysX-enabled module, not the plain one: without it every
              # physics example in python/examples/ exits immediately with
              # "This build has no PhysX backend."
              threeppPython = self.packages.${pkgs.stdenv.hostPlatform.system}.threepp-python-physx;

              # NVIDIA Warp from ./warp.nix, CPU-only. cudaSupport = false also
              # settles libmathdxSupport, which defaults to cudaSupport; what
              # stays on is standaloneSupport, the LLVM/Clang JIT that makes
              # wp.launch(..., device="cpu") work at all — without it Warp
              # imports and allocates but cannot launch a kernel.
              #
              # warp-lang is passed to itself because the expression takes a
              # self-reference for passthru.tests. Left to callPackage it would
              # resolve to nixpkgs' warp-lang (1.15.0), so the tests would
              # exercise a different package than the one being built.
              warp-lang = pkgs.python3Packages.callPackage ./warp.nix {
                cudaSupport = false;
                inherit warp-lang;
              };

              pythonEnv = pkgs.python3.withPackages (ps: [
                threeppPython
                warp-lang
                # numpy arrives with threepp-python (demo_common.py needs it).
                # pillow is imported by 31 of the example scripts — every
                # headless-capture one, from textured_box.py to the warp_* set.
                ps.pillow
                ps.matplotlib # warp_wheel_testbed, snake_panels, multiview_bench
                ps.scipy # calico_collider
                # imageio-ffmpeg is not optional alongside imageio: the scripts
                # that write video import it by name (warp_sailboat.py,
                # spot/spot_slam.py, warp_mudsnow_drive.py), not just through
                # imageio's plugin lookup.
                ps.imageio
                ps.imageio-ffmpeg
                # Still unprovided: torch, for the RL scripts under spot/,
                # tendon_hand/ and calico/ — a multi-gigabyte closure, so it is
                # left to an explicit ask. The Omniverse/Blender/Gazebo
                # integrations (omni, isaacsim, bpy, pxr, gz) are out of reach.
                ps.torch
              ]);
            in
            pkgs.mkShell {
              packages = [ pythonEnv ];

              shellHook =
                lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
                  export LD_LIBRARY_PATH="/run/opengl-driver/lib:${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                ''
                + ''
                  _ext=$(echo ${threeppPython}/${pkgs.python3.sitePackages}/threepp/threepp.*.so)
                  if [ -e "$_ext" ] && [ -d python/threepp ]; then
                    ln -sfn "$_ext" "python/threepp/$(basename "$_ext")"
                    echo "threepp python shell"
                    echo "  linked $(basename "$_ext") into python/threepp/"
                    echo "  (python/.gitignore already covers *.so, so it stays out of git)"
                    echo
                    echo "  cd python/examples && python hello_cube.py"
                  else
                    echo "threepp python shell — run me from the repository root."
                  fi
                  unset _ext
                '';
            };

          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.threepp ];

            packages =
              with pkgs;
              [
                cmake
                ninja
                pkg-config
                clang-tools
              ]
              ++ lib.optionals stdenv.hostPlatform.isLinux [ gdb ];

            shellHook =
              lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
                export LD_LIBRARY_PATH="/run/opengl-driver/lib:${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''
              + ''
                echo "threepp dev shell — library-only configure:"
                echo "  cmake -B build -G Ninja \\"
                echo "    -DTHREEPP_BUILD_EXAMPLES=OFF -DTHREEPP_BUILD_TESTS=OFF \\"
                echo "    -DTHREEPP_BUILD_EDITOR=OFF -DTHREEPP_USE_EXTERNAL_GLFW=ON"
                echo
                echo "Turning examples or tests back on needs network: pass a prefetched"
                echo "FETCHCONTENT_SOURCE_DIR_THREEPP_DATA / _CATCH2 instead."
              '';
          };
        }
      );

      formatter = eachSystem (pkgs: pkgs.nixfmt-tree);
    };
}
