# NVIDIA PhysX 5 (Omniverse), built from source, packaged to look like vcpkg's
# `physx` port.
#
# Looking like that port is the whole point, not an accident: threepp finds PhysX
# with find_package(unofficial-omniverse-physx-sdk CONFIG) and links
# unofficial::omniverse-physx-sdk::sdk — vcpkg-specific names that upstream
# PhysX does not provide. cmake/PhysxStaticLinkFix.cmake then reaches INTO that
# imported target, so the shape it expects is a hard contract:
#
#   * IMPORTED_LOCATION_RELEASE on ::sdk is libPhysX_static_64.a — it tests the
#     path for "_static_" to tell a static build from a dynamic one
#   * the seven component archives hang off ::sdk's INTERFACE_LINK_LIBRARIES
#   * lib/libPhysXVehicle2_static_64.a exists, so the fix-up can add it by path
#   * headers resolve from include/physx
#
# Upstream's build system is driven through physx/compiler/public, which is what
# generate_projects.sh ends up invoking; the options below are the ones vcpkg's
# portfile passes for x64-linux.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  cmake,
  ninja,
  p7zip,
  # The GPU solver. It is NOT part of this repository and is not built here:
  # NVIDIA ships it as a prebuilt libPhysXGpu_64.so under its own proprietary
  # terms, which is why it is off by default. Without it PhysX runs CPU-only —
  # enough for everything threepp does except PhysxWorld(gpu_dynamics=True),
  # direct-GPU RL and soft bodies (which only have a GPU solver).
  withGpu ? false,
}:

let
  # Named by the archive rather than by the SDK version: this blob is versioned
  # independently of the source tag it pairs with.
  physxGpuArchive = fetchurl {
    name = "PhysXGpu-5.5.0.2aa3c8a3-linux-x86_64.7z";
    url = "https://d4i3qtqj3r0z5.cloudfront.net/PhysXGpu%405.5.0.2aa3c8a3-release-106.4-linux-x86_64-public.7z";
    hash = "sha256-7zTsM7qulb6zvQEzmVzDB4z2LXqDRb83drFqbmK7zr0=";
  };
in

stdenv.mkDerivation (finalAttrs: {
  pname = "physx";
  version = "5.5.0";

  src = fetchFromGitHub {
    owner = "NVIDIA-Omniverse";
    repo = "PhysX";
    # The tag carries the Omniverse release as well as the SDK version; it is
    # the ref vcpkg's portfile pins.
    tag = "106.4-physx-5.5.0";
    hash = "sha256-W3xeoc5dDWLTeuSws0tbQQys+NtGpg4epCyn+Dzy/f0=";
  };

  nativeBuildInputs = [
    cmake
    ninja
  ]
  ++ lib.optionals withGpu [ p7zip ];

  # physx/compiler/public is the entry point. It reads PHYSX_ROOT_DIR and pulls
  # in source/compiler/cmake from there, so the top-level CMakeLists of the
  # repository is never used.
  cmakeDir = "../physx/compiler/public";

  # PhysX turns off -Wformat on purpose (-Wno-format is in its GCC warning set),
  # and nixpkgs' `format` hardening turns on -Wformat -Werror=format-security.
  # The two together are immediately fatal, before a single real warning:
  #   cc1plus: error: '-Wformat-security' ignored without '-Wformat'
  #                   [-Werror=format-security]
  # A -Wno-error cannot rescue this — GCC documents -Wno-error as having no
  # effect on a diagnostic requested as an error through -Werror=<name>. The
  # hardening flag itself has to go.
  hardeningDisable = [ "format" ];

  # PhysX's own warning set ends in -Werror, tuned for the compilers of 2024; a
  # newer GCC finds more to say and every new diagnostic is then fatal.
  # NIX_CFLAGS_COMPILE lands after the flags CMake puts on the command line,
  # which is what lets this win against that -Werror.
  env.NIX_CFLAGS_COMPILE = "-Wno-error";

  preConfigure = ''
    # Absolute, and only knowable here: the configure phase has not yet entered
    # the build directory, so $PWD is still the unpacked source root.
    physxRoot="$PWD/physx"
    cmakeFlagsArray+=(
      "-DPHYSX_ROOT_DIR=$physxRoot"
      "-DPX_OUTPUT_LIB_DIR=$physxRoot"
      "-DPX_OUTPUT_BIN_DIR=$physxRoot"
    )
  ''
  + lib.optionalString withGpu ''
    mkdir -p "$NIX_BUILD_TOP/physxgpu"
    7z x ${physxGpuArchive} "-o$NIX_BUILD_TOP/physxgpu" -y -bso0 -bsp0
    cmakeFlagsArray+=( "-DPHYSX_PHYSXGPU_PATH=$NIX_BUILD_TOP/physxgpu/bin" )
  '';

  cmakeFlags = [
    (lib.cmakeFeature "TARGET_BUILD_PLATFORM" "linux")
    (lib.cmakeFeature "PX_OUTPUT_ARCH" "x86")
    (lib.cmakeBool "PX_GENERATE_STATIC_LIBRARIES" true)
    (lib.cmakeBool "PX_BUILDSNIPPETS" false)
    (lib.cmakeBool "PX_BUILDPVDRUNTIME" false)
  ]
  ++ lib.optionals (!withGpu) [
    # physx/compiler/public/CMakeLists.txt hardcodes SET(PUBLIC_RELEASE 1), and
    # the linux platform file then does a configure-time FILE(COPY ...) of
    # libPhysXGpu_64.so out of PHYSX_PHYSXGPU_PATH — a hard error when the blob
    # is absent, with no option to turn it off. The copy block is wrapped in
    # IF(NOT GPU_LIB_COPIED), so claiming it has already happened is the lever
    # that skips it. Nothing else reads the variable.
    (lib.cmakeFeature "GPU_LIB_COPIED" "1")
  ];

  # PhysX's install() rules stage a layout of their own under
  # install/linux/PhysX; vcpkg ignores them and lifts the artifacts straight out
  # of the build tree, because that is where the archives actually are. Same
  # here. The compiler name in the path (linux.clang even under GCC) is
  # upstream's to choose, hence the glob.
  installPhase = ''
    runHook preInstall

    install -d "$out/lib" "$out/include"

    local found=0
    for a in ../physx/bin/*/release/*.a; do
      [ -e "$a" ] || continue
      install -Dm644 "$a" -t "$out/lib"
      found=1
    done
    if [ "$found" != 1 ]; then
      echo "physx: no release archives under physx/bin/*/release — the output" >&2
      echo "       layout changed upstream. Found instead:" >&2
      find ../physx/bin -maxdepth 3 -type d >&2 || true
      exit 1
    fi

    # The config file resolves headers as <prefix>/include/physx, matching how
    # the port renames the directory on its way in.
    cp -r ../physx/include "$out/include/physx"

    # Not in lib/: the GPU solver is dlopen'd by soname at runtime, never
    # linked, and the imported target for it is deliberately a late binding.
    # tools/ is where the port puts it and where the config file looks.
    ${lib.optionalString withGpu ''
      install -d "$out/tools"
      find "$NIX_BUILD_TOP/physxgpu" -name 'libPhysXGpu_64.so' -path '*release*' \
        -exec install -Dm755 {} -t "$out/tools" \;
    ''}

    install -Dm644 ../LICENSE.md "$out/share/doc/${finalAttrs.pname}/LICENSE.md"

    install -d "$out/share/unofficial-omniverse-physx-sdk"
    cp "$cmakeConfig" \
      "$out/share/unofficial-omniverse-physx-sdk/unofficial-omniverse-physx-sdk-config.cmake"

    runHook postInstall
  '';

  # Release-only, so this is a trimmed rewrite of the port's config rather than
  # a copy of it: no debug/lib half, no VCPKG_LIBRARY_LINKAGE, and absolute
  # paths instead of a find_library sweep. The target graph is identical, which
  # is what threepp_fix_physx_static_link_order() actually depends on.
  cmakeConfig = builtins.toFile "unofficial-omniverse-physx-sdk-config.cmake" ''
    # Generated by physx.nix. Presents a source-built PhysX 5 under the target
    # names vcpkg's `physx` port uses, which is what consumers look for.
    if(NOT TARGET unofficial::omniverse-physx-sdk)
        get_filename_component(_physx_prefix "''${CMAKE_CURRENT_LIST_FILE}" PATH)
        get_filename_component(_physx_prefix "''${_physx_prefix}" PATH)
        get_filename_component(_physx_prefix "''${_physx_prefix}" PATH)

        set(OMNIVERSE-PHYSX-SDK_INCLUDE_DIRS "''${_physx_prefix}/include/physx")

        add_library(unofficial::omniverse-physx-sdk::sdk UNKNOWN IMPORTED)
        set_target_properties(unofficial::omniverse-physx-sdk::sdk PROPERTIES
            IMPORTED_CONFIGURATIONS "RELEASE"
            IMPORTED_LOCATION_RELEASE "''${_physx_prefix}/lib/libPhysX_static_64.a"
            INTERFACE_INCLUDE_DIRECTORIES "''${OMNIVERSE-PHYSX-SDK_INCLUDE_DIRS}")

        # Mirrors the port's list. PhysXVehicle2 is absent on purpose: the port
        # only names it on WIN32, and threepp's link fix-up adds the archive by
        # path on Linux precisely because no target exists for it.
        foreach(name IN ITEMS
                PhysXExtensions
                PhysXPvdSDK
                PhysXCharacterKinematic
                PhysXCooking
                PhysXCommon
                PhysXFoundation
                PhysXVehicle)
            add_library(unofficial::omniverse-physx-sdk::''${name} UNKNOWN IMPORTED)
            set_target_properties(unofficial::omniverse-physx-sdk::''${name} PROPERTIES
                IMPORTED_CONFIGURATIONS "RELEASE"
                IMPORTED_LOCATION_RELEASE "''${_physx_prefix}/lib/lib''${name}_static_64.a")
            set_property(TARGET unofficial::omniverse-physx-sdk::sdk APPEND PROPERTY
                INTERFACE_LINK_LIBRARIES unofficial::omniverse-physx-sdk::''${name})
        endforeach()

        # Present only when this build was given the GPU solver. A consumer is
        # expected to test for the target rather than assume it (threepp and the
        # port's own usage file both do).
        if(EXISTS "''${_physx_prefix}/tools/libPhysXGpu_64.so")
            add_library(unofficial::omniverse-physx-sdk::gpu-library SHARED IMPORTED)
            set_target_properties(unofficial::omniverse-physx-sdk::gpu-library PROPERTIES
                IMPORTED_LOCATION "''${_physx_prefix}/tools/libPhysXGpu_64.so")
        endif()
    endif()
  '';

  meta = {
    description = "NVIDIA PhysX 5 SDK, packaged under vcpkg's unofficial-omniverse-physx-sdk CMake names";
    homepage = "https://github.com/NVIDIA-Omniverse/PhysX";
    license = [
      lib.licenses.bsd3
    ]
    # The prebuilt GPU solver is not BSD-3 and is not redistributable on those
    # terms; it travels under NVIDIA's own license.
    ++ lib.optionals withGpu [ lib.licenses.unfree ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    maintainers = [ ];
  };
})
