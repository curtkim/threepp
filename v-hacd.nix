# V-HACD — approximate convex decomposition, header-only.
#
# threepp reaches it the way vcpkg's `v-hacd` port presents it: a bare VHACD.h on
# the include path, found with find_path(V_HACD_INCLUDE_DIRS "VHACD.h") in
# cmake/ConvexDecomposition.cmake. There is no CMake package and no library to
# link — the single translation unit that defines ENABLE_VHACD_IMPLEMENTATION
# lives in threepp (src/threepp/extras/physx/ConvexDecomposition.cpp).
{
  lib,
  stdenv,
  fetchFromGitHub,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "v-hacd";
  version = "4.1.0";

  src = fetchFromGitHub {
    owner = "kmammou";
    repo = "v-hacd";
    tag = "v${finalAttrs.version}";
    hash = "sha256-GqMhxDfkxC4HLfq92tS00ANmVM0B3lWUui5D700Vhuw=";
  };

  # The repo ships an app/ CMake project that builds the standalone decomposer.
  # Nothing here wants it: the library itself is one header.
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 include/VHACD.h "$out/include/VHACD.h"
    install -Dm644 LICENSE "$out/share/doc/${finalAttrs.pname}/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Approximate convex decomposition of 3D meshes (header-only)";
    homepage = "https://github.com/kmammou/v-hacd";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.all;
    maintainers = [ ];
  };
})
