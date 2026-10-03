# callPackage-style expression for NVIDIA Warp (warp-lang) v1.17.0.
#
#   pkgs.python3Packages.callPackage ./default.nix { }
#
# Notes on how this differs from the nixpkgs 1.7.x / 1.11.x expressions:
#   * `warp/build_dll.py` moved to `warp/_src/build_dll.py`.
#   * `build_lib.py` switched from underscore to dash flags
#     (`--cuda_path` -> `--cuda-path`, `--no_standalone` -> `--no-standalone`, ...).
#   * `build_lib.py` gained `--use-dynamic-cuda`, so the `-lcudart_static` ->
#     `-lcudart` substitutions are no longer needed.
#   * `build_lib.py` gained `--no-cuda` for a genuinely CPU-only build.
#   * `build_llvm.py`/`build_warp_clang_for_arch()` gained `--llvm-path`, which is how
#     the Packman download of NVIDIA's prebuilt Clang/LLVM SDK is bypassed.
#   * Warp is Apache-2.0 since 1.6, not the NVIDIA SLA.
{
  lib,
  config,
  buildPythonPackage,
  fetchFromGitHub,
  fetchurl,
  autoAddDriverRunpath,
  cudaPackages,
  # Warp 1.17.0 pins LLVM 22.1.8 (see deps/llvm-deps.packman.xml); nixpkgs
  # llvmPackages_22 is exactly 22.1.8. Bump this together with the Warp version.
  llvmPackages_22,
  numpy,
  pkgsBuildHost,
  python,
  runCommand,
  setuptools,
  stdenv,
  stdenvNoCC,
  symlinkJoin,
  warp-lang, # self-reference, for passthru.tests
  writableTmpDirAsHomeHook,
  zlib,

  # Build warp-clang, the LLVM/Clang JIT that compiles kernels for the "cpu"
  # device. Without it Warp still imports and still allocates CPU arrays, but
  # `wp.launch(..., device="cpu")` fails. Keep this on for machines with no GPU.
  standaloneSupport ? true,

  # Build the CUDA backend ("cuda:N" devices).
  cudaSupport ? config.cudaSupport,

  # cuBLASDx/cuFFTDx/cuSOLVERDx, needed by the tile ops (tile_matmul, tile_fft,
  # tile_cholesky, ...). Requires CUDA.
  libmathdxSupport ? cudaSupport,
}@args:

assert libmathdxSupport -> cudaSupport;
assert lib.assertMsg (standaloneSupport || cudaSupport)
  "warp-lang: at least one of standaloneSupport (CPU) or cudaSupport (GPU) must be enabled";

let
  effectiveStdenv = if cudaSupport then cudaPackages.backendStdenv else args.stdenv;

  llvmPackages = llvmPackages_22;

  # `--llvm-path DIR` makes build_llvm.py read headers from DIR/include and
  # libraries from DIR/lib, so LLVM and Clang have to look like one prefix.
  llvmJoined = symlinkJoin {
    name = "warp-llvm-${llvmPackages.llvm.version}";
    paths = [
      llvmPackages.llvm.dev
      llvmPackages.llvm.lib
      llvmPackages.libclang.dev
      llvmPackages.libclang.lib
    ];
  };

  # Warp 1.17.0 wants libmathdx 0.3.1 for CUDA 12 and 0.4.1 for CUDA 13
  # (deps/libmathdx-deps.packman.xml).
  libmathdx = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "libmathdx";
    version = if cudaPackages.cudaMajorVersion == "13" then "0.4.1" else "0.3.1";

    outputs = [
      "out"
      "static"
    ];

    src =
      let
        cudaMajorVersion = cudaPackages.cudaMajorVersion;
        name = "libmathdx-Linux-${stdenvNoCC.hostPlatform.parsed.cpu.name}-${finalAttrs.version}-cuda${cudaMajorVersion}.0";
        hashes = {
          "12" = {
            x86_64-linux = "sha256-soL5XwAos5iA5+dxVezQFXAJBShq/Yi9YxByiUCQ+dk=";
            aarch64-linux = "sha256-hm7VbDNncnPxCmUoW3RglUHPiTdFWOJDSsn7XUyd47o=";
          };
          "13" = {
            x86_64-linux = "sha256-fOCytY3TT0LS2mMcFNl/YzvpcoenSMq1ewVdYRgjB00=";
            aarch64-linux = "sha256-JpLDb4AgQX4TYWVIirfF25Q8pKN48ftgQNY0LgfTjVw=";
          };
        };
      in
      lib.mapNullable (
        hash:
        fetchurl {
          inherit hash;
          name = "${name}.tar.gz";
          url = "https://developer.nvidia.com/downloads/compute/cublasdx/redist/cublasdx/cuda${cudaMajorVersion}/${name}.tar.gz";
        }
      ) (hashes.${cudaMajorVersion}.${stdenvNoCC.hostPlatform.system} or null);

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      tar -xzf "$src" -C "$out"

      # libmathdx >= 0.4.0 wraps the payload in a single top-level directory one
      # level above the layout Warp compiles against. Flatten it so that
      # `--libmathdx-path $out` finds $out/include and $out/lib directly.
      if [[ ! -d "$out/include" ]]; then
        nested="$(echo "$out"/libmathdx-*)"
        shopt -s dotglob
        mv "$nested"/* "$out/"
        rmdir "$nested"
        shopt -u dotglob
      fi

      mkdir -p "$static"
      moveToOutput "lib/libmathdx_static.a" "$static"

      runHook postInstall
    '';

    meta = {
      description = "Library used to integrate cuBLASDx, cuFFTDx and cuSOLVERDx into Warp";
      homepage = "https://developer.nvidia.com/cublasdx-downloads";
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
      license = {
        fullName = "NVIDIA Math SDK Software License Agreement";
        url = "https://docs.nvidia.com/cuda/eula/index.html";
        free = false;
        redistributable = true;
      };
      platforms = [
        "aarch64-linux"
        "x86_64-linux"
      ];
    };
  });
in
buildPythonPackage.override { stdenv = effectiveStdenv; } (finalAttrs: {
  pname = "warp-lang";
  version = "1.17.0";
  pyproject = true;

  # Some CUDA setup hooks misbehave without this, producing missing math symbols
  # (expf and friends) when linking against nvptxcompiler_static.
  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "warp";
    tag = "v${finalAttrs.version}";
    hash = "sha256-/yjEArKTjVGcCZgHegBoKJYDX/nvot2bFsCoQcC/uIg=";
  };

  postPatch =
    # Warp targets the pre-C++11 libstdc++ ABI because its release binaries are
    # built on an ancient toolchain. Nixpkgs' libstdc++, LLVM and Clang all use
    # the new ABI, so keep every translation unit on the new one.
    ''
      nixLog "patching $PWD/warp/_src/build_dll.py to use the C++11 libstdc++ ABI"
      substituteInPlace "$PWD/warp/_src/build_dll.py" \
        --replace-fail '-D_GLIBCXX_USE_CXX11_ABI=0' '-D_GLIBCXX_USE_CXX11_ABI=1'
    ''
    + lib.optionalString standaloneSupport
      # build_warp_clang_for_arch() globs every .a in <llvm-path>/lib and links
      # them statically. Nixpkgs ships libLLVM.so / libclang-cpp.so instead, so
      # link those two dynamically.
      ''
        nixLog "patching $PWD/build_llvm.py to link libLLVM/libclang-cpp dynamically"
        substituteInPlace "$PWD/build_llvm.py" \
          --replace-fail \
            'libs = [f"-l{lib[3:-2]}" for lib in libs if os.path.splitext(lib)[1] == ".a"]' \
            'libs = ["-lLLVM", "-lclang-cpp"]' \
          --replace-fail \
            'libs.append(f"-L{libpath}")' \
            'libs.extend([f"-L{libpath}", "-lz"])'
      ''
    + lib.optionalString cudaSupport (
      let
        gencodeOpts = lib.concatMapStringsSep ", " (
          gencodeString: ''"${gencodeString}"''
        ) cudaPackages.flags.gencode;
        clangArchFlags = lib.concatMapStringsSep ", " (
          realArch: ''"--cuda-gpu-arch=${realArch}"''
        ) cudaPackages.flags.realArches;
      in
      # Build for the architectures nixpkgs was configured for rather than
      # NVIDIA's very broad defaults.
      ''
        nixLog "patching $PWD/warp/_src/build_dll.py to use our gencode flags"
        substituteInPlace "$PWD/warp/_src/build_dll.py" \
          --replace-fail '*gencode_opts,' '${gencodeOpts},' \
          --replace-fail '*clang_arch_flags,' '${clangArchFlags},'
      ''
    )
    # Reloading a module writes into the installed package directory, which is
    # read-only in the store.
    + ''
      nixLog "patching $PWD/warp/tests/test_reload.py to disable tests that write to the store"
      substituteInPlace "$PWD/warp/tests/test_reload.py" \
        --replace-fail \
          'add_function_test(TestReload, "test_reload", test_reload, devices=devices)' \
          "" \
        --replace-fail \
          'add_function_test(TestReload, "test_reload_references", test_reload_references, devices=get_test_devices("basic"))' \
          ""
    '';

  build-system = [ setuptools ];

  dependencies = [ numpy ];

  nativeBuildInputs = lib.optionals cudaSupport [
    # Warp dlopen()s the driver at runtime, so the video driver path has to be
    # injected even though this is a from-source build.
    autoAddDriverRunpath
  ];

  buildInputs =
    lib.optionals standaloneSupport [
      llvmPackages.llvm
      llvmPackages.libclang
      zlib
    ]
    ++ lib.optionals cudaSupport [
      (lib.getStatic cudaPackages.cuda_nvcc) # nvptxcompiler_static has no shared counterpart
      cudaPackages.cuda_cccl # <cub/cub.cuh>
      cudaPackages.cuda_cudart
      cudaPackages.cuda_nvcc
      cudaPackages.cuda_nvrtc
    ]
    ++ lib.optionals libmathdxSupport [
      libmathdx
      # build_dll.py links -lnvJitLink next to -lmathdx.
      cudaPackages.libnvjitlink
      # NOTE: host-side libcublas/libcufft/libcusolver are deliberately NOT here.
      # cuBLASDx/cuFFTDx/cuSOLVERDx are device-side (LTO-IR) libraries shipped
      # inside libmathdx; `patchelf --print-needed libmathdx.so` lists only
      # libnvrtc. Pulling the host libraries in costs ~1.8 GiB for nothing.
    ];

  # Run the offline build that produces warp/bin/warp.so (and warp-clang.so)
  # before setuptools collects package data for the wheel.
  preBuild =
    let
      buildOptions = [
        "--jobs=$NIX_BUILD_CORES"
      ]
      ++ (
        if standaloneSupport then
          # Bypasses the Packman download of NVIDIA's prebuilt Clang/LLVM SDK,
          # which the sandbox has no network access for.
          [ "--llvm-path=${llvmJoined}" ]
        else
          [ "--no-standalone" ]
      )
      ++ (
        if cudaSupport then
          [
            # --cuda-path is the prefix containing bin/nvcc.
            "--cuda-path=${lib.getBin pkgsBuildHost.cudaPackages.cuda_nvcc}"
            # Link the CUDA runtime, NVRTC and nvJitLink dynamically instead of
            # embedding the static archives.
            "--use-dynamic-cuda"
          ]
        else
          [ "--no-cuda" ]
      )
      ++ (
        if libmathdxSupport then
          [
            "--use-libmathdx"
            "--libmathdx-path=${libmathdx}"
          ]
        else
          [ "--no-use-libmathdx" ]
      );
    in
    ''
      export HOME="$(mktemp -d)"
      nixLog "running $PWD/build_lib.py to create components necessary to build the wheel"
      "${python.pythonOnBuildForHost.interpreter}" "$PWD/build_lib.py" ${lib.concatStringsSep " " buildOptions}
    '';

  pythonImportsCheck = [ "warp" ];

  # The test suite needs a writable HOME and, for the CUDA backend, a GPU.
  # See passthru.tests.
  doCheck = false;

  passthru = {
    inherit libmathdx llvmJoined;

    tests = {
      # Proves the package is usable on a machine with no GPU: it runs the full
      # suite with CUDA disabled, which exercises warp-clang (the "cpu" device).
      cpu =
        let
          warp-lang' = warp-lang.override {
            cudaSupport = false;
            libmathdxSupport = false;
            standaloneSupport = true;
            warp-lang = warp-lang';
          };
          pythonEnv = python.withPackages (_: [ warp-lang' ]);
        in
        runCommand "warp-lang-tests-cpu"
          {
            nativeBuildInputs = [
              pythonEnv
              writableTmpDirAsHomeHook
            ];
          }
          ''
            python3 -m warp.tests -s default
            touch "$out"
          '';

      # Smoke test: import and launch one kernel on the CPU device.
      smoke =
        runCommand "warp-lang-smoke"
          {
            nativeBuildInputs = [
              (python.withPackages (_: [ warp-lang ]))
              writableTmpDirAsHomeHook
            ];
          }
          ''
            cat > smoke.py <<'EOF'
            import warp as wp

            @wp.kernel
            def double(x: wp.array(dtype=float)):
                i = wp.tid()
                x[i] = x[i] * 2.0

            wp.init()
            wp.print_diagnostics()
            a = wp.array([1.0, 2.0, 3.0], dtype=float, device="cpu")
            wp.launch(double, dim=3, inputs=[a], device="cpu")
            assert a.numpy().tolist() == [2.0, 4.0, 6.0], a.numpy()
            print("ok")
            EOF
            python3 smoke.py
            touch "$out"
          '';
    };
  };

  meta = {
    description = "Python framework for high performance GPU simulation and graphics";
    longDescription = ''
      Warp is a Python framework for writing high-performance simulation and
      graphics code. Warp takes regular Python functions and JIT compiles them to
      efficient kernel code that can run on the CPU or GPU.
    '';
    homepage = "https://github.com/NVIDIA/warp";
    changelog = "https://github.com/NVIDIA/warp/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.asl20;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
})
