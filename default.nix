# threepp, as a callPackage-style function. Every variant the flake exposes is
# this one function with different flags.
#
# THREEPP_BUILD_EXAMPLES / _TESTS / _EDITOR default OFF, and that is what keeps
# the default build possible in the Nix sandbox at all: those options are the
# only things that make the top-level CMakeLists reach the network (FetchContent
# of threepp_data, Catch2 and pybind11). Turning one on means handing the
# corresponding source over through a FETCHCONTENT_SOURCE_DIR_* flag instead —
# see threeppData, catch2Src and pybind11Src below.
#
# physx and v-hacd have no nixpkgs attributes, so they default to the two
# derivations beside this file. The defaults are lazy and only reached by
# withPhysx = true, which is what lets `pkgs.callPackage ./default.nix { }` work
# on a plain nixpkgs; under the flake's overlay the package set supplies them
# and the defaults never run.
{
  lib,
  stdenv,
  callPackage,
  cmake,
  ninja,
  patchelf,
  addDriverRunpath,
  mesa,
  xvfb-run,
  fetchzip,
  glfw,
  libGL,
  assimp,
  python3,
  physx ? callPackage ./physx.nix { },
  v-hacd ? callPackage ./v-hacd.nix { },
  alsa-lib,
  libpulseaudio,
  libjack2,
  vulkan-headers,
  vulkan-loader,
  vulkan-memory-allocator,
  glslang,
  # miniaudio, compiled into the library. Its Linux backends are reached
  # by dlopen, so this only decides whether the code is there.
  withAudio ? true,
  # The deferred Vulkan renderer. Off by default: it is a much larger
  # build (every .comp/.rgen is compiled to SPIR-V and embedded) and
  # needs a GPU with KHR ray-query to actually run.
  withVulkan ? false,
  # A static libthreepp.a cannot carry a RUNPATH, so the dlopen'd
  # libraries below stop being found for free — see postFixup.
  withStaticLib ? false,
  # The 126 example programs. They need the asset repo, which the project
  # pulls with FetchContent — so this is the one option here that has to
  # bring its own prefetched source (see threeppData below).
  withExamples ? false,
  # The Catch2 suite. Builds it and runs ctest in checkPhase, on Mesa's
  # software rasteriser for the tests that need a GL context.
  withTests ? false,
  # The scene editor and the player, plus the two document-authoring
  # tools. Embeds CPython for the MonoBehaviour-style scripting, so it
  # also needs pybind11 — prefetched, like Catch2.
  withEditor ? false,
  # The pybind11 extension module. Unlike the editor this is imported BY
  # python rather than embedding it, and its install layout is a wheel
  # root rather than a prefix — see postInstall.
  withPython ? false,
  # NVIDIA PhysX plus V-HACD, from ./physx.nix and ./v-hacd.nix. Nothing
  # in the project asks for them by option: every site does a QUIET
  # find_package / find_path and quietly does without, so this flag only
  # has to put them where that search looks.
  withPhysx ? false,
}:
let
  onLinux = stdenv.hostPlatform.isLinux;

  # GLFW without the Wayland backend — the same shape threepp builds its own
  # vendored copy in (src/CMakeLists.txt:805 sets GLFW_BUILD_WAYLAND OFF), and
  # not an arbitrary preference.
  #
  # nixpkgs' glfw3 carries both backends, so on a Wayland session GLFW picks
  # Wayland, and there the framebuffer is not the window: on a 200%-scaled
  # output GLFW reports a 954x534 window over a 1908x1068 framebuffer. threepp
  # is not ready for that gap on Linux, in two separate places:
  #
  #   * Canvas listens to glfwSetWindowSizeCallback only and never calls
  #     glfwGetFramebufferSize, so the GL viewport is sized in logical pixels
  #     and covers a QUARTER of the buffer — the bottom-left one, GL's origin
  #     being where it is. GLRenderer does correct for this, but behind
  #     `#ifdef __APPLE__` (GLRenderer.cpp:203), because Retina was the only
  #     place the gap used to appear.
  #   * ImguiContext applies style.ScaleAllSizes(monitorContentScale) on top of
  #     the io.DisplayFramebufferScale that ImGui's own GLFW backend already
  #     sets, so the UI is scaled twice and comes out at 2x.
  #
  # On X11 the framebuffer always equals the window, both paths behave, and
  # ImguiContext's content-scale pass is exactly right. Fixing threepp instead
  # of pinning the backend is the better end state, but that patch belongs
  # upstream rather than in a packaging expression.
  glfw' =
    if onLinux then
      glfw.overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [ (lib.cmakeBool "GLFW_BUILD_WAYLAND" false) ];
      })
    else
      glfw;

  # Pulled in by name with dlopen at runtime, never linked: they appear in
  # no DT_NEEDED entry, so neither autoPatchelfHook nor the ld wrapper's
  # automatic -rpath can discover them. Resolved by hand below.
  audioLibs = lib.optionals withAudio [
    alsa-lib # libasound.so.2
    libpulseaudio # libpulse.so.0
    libjack2 # libjack.so.0
  ];

  # The example/test asset repo. Pinned to exactly the commit the
  # top-level CMakeLists FetchContent_Declare's, so this build sees the
  # same assets a normal checkout would — it is handed over through
  # FETCHCONTENT_SOURCE_DIR_THREEPP_DATA instead of being downloaded.
  # 263 MB, and DATA_FOLDER bakes this store path into every example, so
  # it is a genuine runtime dependency of the examples package.
  threeppData = fetchzip {
    name = "threepp_data-93069e76";
    url = "https://github.com/markaren/threepp_data/archive/93069e76bfd6cd75e785d0334738cb303d4f555e.tar.gz";
    hash = "sha256-tTrX8r5i5xZpQTQ4/DDPawolYkG2k9CctMHrc6aqHJU=";
  };

  # Examples and tests both compile DATA_FOLDER from the asset repo.
  needsData = withExamples || withTests;

  # Catch2, at the tag the top-level CMakeLists pins. nixpkgs' catch2_3
  # is 3.14 and is of no use here anyway: the FetchContent_Declare
  # carries no FIND_PACKAGE_ARGS, so there is no find_package path to
  # redirect — only a source tree to hand over.
  catch2Src = fetchzip {
    name = "Catch2-3.4.0";
    url = "https://github.com/catchorg/Catch2/archive/refs/tags/v3.4.0.tar.gz";
    hash = "sha256-DqGGfNjKPW9HFJrX9arFHyNYjB61uoL6NabZatTWrr0=";
  };

  # nixpkgs' pybind11 happens to be exactly the v3.0.4 that apps/editor
  # and python/ pin, so its source tarball can stand in for the fetch
  # without picking a second version. It is the SOURCE tree that is
  # wanted, not the installed package: FetchContent add_subdirectory()s
  # what it is given.
  pybind11Src = python3.pkgs.pybind11.src;

  # True for the two options that produce PROGRAMS. They share two
  # properties that the library alone does not: they link Dear ImGui
  # (which lives under examples/external, and which apps/editor pulls in
  # by itself when the examples are off), and their binaries are copied
  # out of the build tree by hand because nothing install()s them.
  buildsApps = withExamples || withEditor;

  # The Python module does not LINK libimgui — python/CMakeLists.txt
  # compiles the ImGui core and its GLFW/GL3 backends straight into the
  # extension — but it does end up with the same broken GL loader inside
  # it, so it needs the same patch.
  compilesImgui = buildsApps || withPython;

  # Anything that ships a loadable object pointing back at libthreepp.so.
  needsInstallRpath = buildsApps || withPython;

  # Both halves of the pybind11 story: the editor embeds the interpreter,
  # the module is loaded by one. Either way CPython and pybind11 are
  # needed, and from the same install.
  needsPython = withEditor || withPython;
in
stdenv.mkDerivation {
  # Distinct store-path names per variant, so two of them sitting in the
  # store can be told apart at a glance.
  pname =
    "threepp"
    + lib.optionalString withVulkan "-vulkan"
    + lib.optionalString withExamples "-examples"
    + lib.optionalString withEditor "-editor"
    + lib.optionalString withPython "-python"
    + lib.optionalString withTests "-tests"
    + lib.optionalString withPhysx "-physx";
  # The CMake package version the project exports (write_basic_package_version_file).
  version = "0.0.0";

  # The repository minus its packaging. Not the flake source as-is: with that,
  # a one-line comment change in flake.nix rebuilt all 105 examples. Every .nix
  # file is filtered rather than the three by name, so this file, physx.nix and
  # v-hacd.nix are covered too — and so is any future one. The project itself
  # ships no .nix, so nothing needed is lost.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference ./. (
      lib.fileset.unions [
        (lib.fileset.fileFilter (file: file.hasExt "nix") ./.)
        ./flake.lock
      ]
    );
  };

  outputs = [
    "out"
    "dev"
  ];

  nativeBuildInputs = [
    cmake
    ninja
  ]
  ++ lib.optionals onLinux [
    patchelf
    addDriverRunpath
  ]
  ++ lib.optionals withVulkan [ glslang ]
  # tests/renderers/gl/CMakeLists.txt find_program()s xvfb-run at
  # CONFIGURE time and only wraps the GL render tests with it if it was
  # there, so this is a build input, not just a check input.
  ++ lib.optionals withTests [ xvfb-run ];

  # glfw is propagated because the generated threepp-config.cmake calls
  # find_dependency(glfw3 CONFIG) whenever THREEPP_USE_EXTERNAL_GLFW was
  # on — a consumer cannot find_package(threepp) without it. Same story
  # for Vulkan: cmake/config.cmake.in emits find_dependency(Vulkan), and
  # the library hands out THREEPP_WITH_VULKAN plus Vulkan::Vulkan PUBLIC.
  propagatedBuildInputs = [
    glfw'
  ]
  ++ lib.optionals withVulkan [
    vulkan-headers
    vulkan-loader
  ]
  # pyproject.toml's only hard runtime dependency. Propagated so that
  # python3.withPackages (ps: [ threepp-python ]) brings it along.
  ++ lib.optionals withPython [ python3.pkgs.numpy ];

  buildInputs = [
    libGL
  ]
  ++ lib.optionals onLinux audioLibs
  ++ lib.optionals withVulkan [ vulkan-memory-allocator ]
  # Three examples (assimp_loader, assimp_bones, collada_compare) link
  # it; examples/LibConfig.cmake find_package()s it QUIET, so without
  # this they would be skipped with an AUTHOR_WARNING rather than fail.
  ++ lib.optionals withExamples [ assimp ]
  # Development.Embed, not Development.Module: the editor embeds the
  # interpreter rather than being imported by one, so it links
  # libpython itself.
  ++ lib.optionals needsPython [ python3 ]
  # physx carries the CMake package vcpkg's port would have provided, so
  # find_package(unofficial-omniverse-physx-sdk CONFIG) resolves; v-hacd
  # is a bare header that cmake/ConvexDecomposition.cmake locates with
  # find_path(VHACD.h), which reads the CMAKE_INCLUDE_PATH the cmake
  # setup hook builds out of the compiler flags.
  ++ lib.optionals withPhysx [
    physx
    v-hacd
  ];

  # threepp reaches libGL and libEGL through dlopen of its own:
  #   - glad's loader, used by GLRenderer's size-only constructor
  #     (GLRenderer.cpp -> loadGlad() with no getter)
  #   - EglContext, the display-less offscreen path
  # Both ask for a bare soname, which resolves to nothing inside a Nix
  # closure, so point them at libglvnd directly. (The GLFW path needs no
  # such patch: nixpkgs' glfw3 already links X11 explicitly and bakes
  # absolute _GLFW_*_LIBRARY paths in, which is the main reason this
  # build uses the external GLFW rather than the vendored copy.)
  postPatch =
    lib.optionalString onLinux ''
      substituteInPlace src/external/glad/glad.c \
        --replace-fail '"libGL.so.1"' '"${lib.getLib libGL}/lib/libGL.so.1"'
      substituteInPlace src/threepp/canvas/EglContext.cpp \
        --replace-fail '"libEGL.so.1"' '"${lib.getLib libGL}/lib/libEGL.so.1"'
    ''
    # Dear ImGui's bundled GL loader (imgui_impl_opengl3_loader.h) finds
    # GL the same hopeful way glad does: dlopen by bare soname, plus an
    # RTLD_NOLOAD probe for whatever the windowing library already opened.
    # Inside a Nix closure every one of those lookups fails — GLFW loaded
    # libGLX from an absolute store path, so the NOLOAD probe for
    # "libGLX.so.0" does not match it either — and the loader gives up
    # with "Failed to initialize OpenGL loader!". The program then calls
    # through a table of null pointers and segfaults in
    # ImGui_ImplOpenGL3_NewFrame on its first rendered frame.
    + lib.optionalString (compilesImgui && onLinux) ''
      substituteInPlace examples/external/imgui/imgui_impl_opengl3_loader.h \
        --replace-fail '"libGLX.so.0"' '"${lib.getLib libGL}/lib/libGLX.so.0"' \
        --replace-fail '"libOpenGL.so.0"' '"${lib.getLib libGL}/lib/libOpenGL.so.0"' \
        --replace-fail '"libEGL.so.1"' '"${lib.getLib libGL}/lib/libEGL.so.1"' \
        --replace-fail '"libGL.so.1"' '"${lib.getLib libGL}/lib/libGL.so.1"' \
        --replace-fail '"libGL.so"' '"${lib.getLib libGL}/lib/libGL.so"'
    ''
    # examples/AddExample.cmake bakes PROJECT_FOLDER as the source tree it
    # was configured from. In a sandboxed build that is /build/<name>,
    # which is gone by the time anyone runs the binary. Point it at a
    # directory that still exists afterwards; postInstall populates it.
    #
    # What reads it: capture_util's --shot path (writes aaa_caps/, so it
    # fails on a read-only store — a headless-capture flag, not a normal
    # run), mountains.cpp (terrain_configs/, never in the repo) and
    # norway_terrain.cpp (geodata/, which is installed).
    + lib.optionalString withExamples ''
      substituteInPlace examples/AddExample.cmake \
        --replace-fail 'PROJECT_FOLDER="''${PROJECT_SOURCE_DIR}"' 'PROJECT_FOLDER="${placeholder "out"}/share/threepp-examples"'

      # The same missing link edge as the editor's, one directory over.
      # examples/projects/FPS/main.cpp calls glfwSetInputMode and
      # examples/projects/Physics/granular_conveyor.cpp reaches for GLFW
      # too, but add_example() links only threepp — so with an external
      # or shared GLFW, ld reports
      #   undefined reference to symbol 'glfwSetInputMode'
      #   libglfw.so.3: error adding symbols: DSO missing from command line
      # Both files are PhysX-gated examples, which is why this stays
      # hidden until physics is enabled. Fixed in add_example() rather
      # than per example: everything it builds is already a GLFW program,
      # by way of threepp's Canvas.
      substituteInPlace examples/AddExample.cmake \
        --replace-fail 'target_link_libraries("''${arg_NAME}" PRIVATE threepp)' 'target_link_libraries("''${arg_NAME}" PRIVATE threepp glfw)'
    ''
    # Same shape, one file over: the editor bakes the path to the PEP 561
    # stub package so "Edit in VS Code" can point Pylance at it. The
    # THREEPP_PYTHON_STUBS environment variable overrides it at runtime,
    # but the default should still resolve.
    + lib.optionalString withEditor ''
      substituteInPlace apps/editor/CMakeLists.txt \
        --replace-fail 'THREEPP_EDITOR_PYTHON_STUBS="''${PROJECT_SOURCE_DIR}/python/threepp"' 'THREEPP_EDITOR_PYTHON_STUBS="${placeholder "out"}/share/threepp-editor/python-stubs"'

      # apps/editor/EditorApp.cpp:100 hand-declares
      #   extern "C" void glfwSetWindowTitle(void*, const char*);
      # to avoid including glfw3.h, and calls it at EditorApp.cpp:1013 —
      # but nothing puts GLFW on threepp_editor's link line. In the
      # project's default configuration that is invisible: the vendored
      # GLFW is an OBJECT library folded into libthreepp, so the symbol is
      # simply there. Link an external or shared GLFW instead, as this
      # build does, and GNU ld answers
      #   libglfw.so.3: error adding symbols: DSO missing from command line
      # because the symbol is only reachable through an indirect DSO.
      # Worth reporting upstream; a one-word link fix either way.
      substituteInPlace apps/editor/CMakeLists.txt \
        --replace-fail 'threepp_editor PRIVATE threepp threepp_editor_core imgui::imgui threepp_editor_examples' 'threepp_editor PRIVATE threepp threepp_editor_core imgui::imgui threepp_editor_examples glfw'
    '';

  # install() puts the exported CMake package under
  # ${CMAKE_INSTALL_DATADIR}/threepp, i.e. in $out, while the headers go
  # to $dev. threepp-targets.cmake names both, so leaving it in $out
  # makes out reference dev while dev references out — a reference cycle
  # Nix rejects outright. CMake config files belong in dev anyway.
  postInstall = ''
    moveToOutput share/threepp "$dev"
  ''
  # The project never install()s the examples or the apps: they are
  # developer binaries dropped in <builddir>/bin by
  # CMAKE_RUNTIME_OUTPUT_DIRECTORY. The working directory here is that
  # build dir, so bin/ is right here and the source tree is one level up.
  + lib.optionalString withExamples ''
    install -Dm755 bin/* -t "$out/bin"
  ''
  # Named one by one when the examples are off, rather than globbing
  # bin/ — a tests build drops its 139 Catch2 executables in the same
  # directory. The two author tools exist only when Python scripting
  # was found, so each is checked for.
  + lib.optionalString (withEditor && !withExamples) ''
    for exe in threepp_editor threepp_player hover_arena_author timber_yard_author; do
      if [ -e "bin/$exe" ]; then
        install -Dm755 "bin/$exe" -t "$out/bin"
      fi
    done
  ''
  # BUILD_SHARED_LIBS reaches examples/external too, so Dear ImGui
  # becomes libimgui.so — and nothing install()s it, because it only
  # ever existed to link the examples and the editor. Anything built
  # against it then dies at startup with "libimgui.so: cannot open
  # shared object file".
  + lib.optionalString buildsApps ''
    find . -name 'libimgui.so*' -exec install -Dm755 {} -t "$out/lib" \;
  ''
  + lib.optionalString withExamples ''
    install -d "$out/share/threepp-examples"
    cp -r ../geodata "$out/share/threepp-examples/"
  ''
  + lib.optionalString withEditor ''
    install -d "$out/share/threepp-editor"
    cp -r ../python/threepp "$out/share/threepp-editor/python-stubs"
  ''
  # python/CMakeLists.txt installs the package with
  # `DESTINATION threepp`, i.e. straight under the install prefix: that
  # is a WHEEL root, which is what scikit-build-core wants and what
  # `pip install .` consumes. Nothing imports $out/threepp, so move the
  # package to where this interpreter actually looks.
  + lib.optionalString withPython ''
    install -d "$out/${python3.sitePackages}"
    mv "$out/threepp" "$out/${python3.sitePackages}/threepp"
  '';

  cmakeFlags = [
    (lib.cmakeBool "THREEPP_BUILD_EXAMPLES" withExamples)
    (lib.cmakeBool "THREEPP_BUILD_TESTS" withTests)
    (lib.cmakeBool "THREEPP_BUILD_EDITOR" withEditor)
    (lib.cmakeBool "THREEPP_WITH_PYTHON" withPython)
    (lib.cmakeBool "THREEPP_WITH_AUDIO" withAudio)
    (lib.cmakeBool "THREEPP_WITH_VULKAN" withVulkan)
    (lib.cmakeBool "BUILD_SHARED_LIBS" (!withStaticLib))

    # Use nixpkgs' GLFW instead of src/external/glfw. Two reasons, both
    # load-bearing:
    #   1. the vendored GLFW 3.4 declares cmake_minimum_required(3.4...3.20),
    #      which CMake 4 refuses outright (compatibility with < 3.5 was
    #      removed); building it would need -DCMAKE_POLICY_VERSION_MINIMUM=3.5.
    #   2. upstream GLFW dlopens every X11 library by soname. nixpkgs'
    #      glfw3 carries the patch that links them instead, so the X11
    #      stack resolves without any runpath surgery here.
    (lib.cmakeBool "THREEPP_USE_EXTERNAL_GLFW" true)
  ]
  ++ lib.optionals withVulkan [
    # cmake/CompileVulkanShaders.cmake find_program()s this; set it
    # explicitly so the shader compiler cannot come from a stray PATH.
    (lib.cmakeFeature "GLSLANG_VALIDATOR" (lib.getExe' glslang "glslangValidator"))
  ]
  ++ lib.optionals needsData [
    # Hand FetchContent the prefetched assets. This is the ONLY reason
    # an examples or tests build does not need the network.
    (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_THREEPP_DATA" "${threeppData}")
  ]
  ++ lib.optionals withTests [
    (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_CATCH2" "${catch2Src}")
  ]
  ++ lib.optionals withPython [
    # pybind11 3.x drives FindPython rather than the deprecated
    # FindPythonInterp path; CMakePresets' "python" preset sets the same.
    (lib.cmakeBool "PYBIND11_FINDPYTHON" true)
  ]
  ++ lib.optionals needsPython [
    (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_PYBIND11" "${pybind11Src}")
    # Named explicitly rather than left to a PATH search: under strictDeps
    # the host python is not on PATH during configure, and the
    # interpreter must be the same one whose libpython gets linked.
    # pybind11 and python/ look at Python_EXECUTABLE (FindPython);
    # apps/editor calls find_package(Python3) and reads the Python3_
    # spelling, so that one is scoped to the editor — passing it for a
    # python-only build just earns an unused-variable warning.
    (lib.cmakeFeature "Python_EXECUTABLE" "${python3.interpreter}")
  ]
  ++ lib.optionals withEditor [
    (lib.cmakeFeature "Python3_EXECUTABLE" "${python3.interpreter}")
  ]
  ++ lib.optionals needsInstallRpath [
    # These binaries are copied out of the build tree by hand, so they
    # must not be carrying CMake's build-tree RUNPATH: that points into
    # the sandbox, and auditTmpdir fails the build on a $TMPDIR entry in
    # a RUNPATH ("Some binaries contain forbidden references to
    # /build/"). Building them with the install RUNPATH from the start
    # gives them $out/lib — where libthreepp.so actually ends up.
    (lib.cmakeBool "CMAKE_BUILD_WITH_INSTALL_RPATH" true)
    (lib.cmakeFeature "CMAKE_INSTALL_RPATH" "${placeholder "out"}/lib")
  ];

  # fixupPhase has already run `patchelf --shrink-rpath` by the time
  # postFixup starts, which is exactly why the dlopen-only entries are
  # added here and not through NIX_LDFLAGS: shrink-rpath would drop any
  # directory no DT_NEEDED entry points into.
  #
  # addDriverRunpath appends /run/opengl-driver/lib so an ICD or a
  # vendor GL dispatched by soname is still reachable on NixOS.
  postFixup = lib.optionalString (onLinux && !withStaticLib) ''
    for so in "$out"/lib/libthreepp.so*; do
      [ -e "$so" ] || continue
      [ -L "$so" ] && continue
      ${lib.optionalString (audioLibs != [ ]) ''
        patchelf --add-rpath "${lib.makeLibraryPath audioLibs}" "$so"
      ''}
      addDriverRunpath "$so"
    done
  '';

  # A static build keeps no RUNPATH of its own: the dlopen'd audio
  # backends then have to be resolved by whoever links libthreepp.a.
  # Say so at build time rather than letting it surface as a silent
  # "no audio devices" at runtime.
  preFixup = lib.optionalString (onLinux && withStaticLib && withAudio) ''
    echo "threepp: static build — libasound/libpulse/libjack are dlopen'd and are" >&2
    echo "         NOT recorded anywhere in libthreepp.a. The consuming executable" >&2
    echo "         must put them on its own RUNPATH for audio to initialise." >&2
  '';

  doCheck = withTests;

  nativeCheckInputs = lib.optionals withTests [ mesa ];

  # No GPU and no /dev/dri inside the sandbox, so the GL tests have to
  # run on Mesa's software rasteriser. libglvnd reaches a vendor library
  # by dlopening libGLX_mesa.so.0 under /run/opengl-driver, which does
  # not exist here — hence the explicit driver path and loader path.
  # The GL tests wrap themselves in xvfb-run (see nativeBuildInputs).
  checkPhase = lib.optionalString withTests ''
    runHook preCheck

    export LIBGL_ALWAYS_SOFTWARE=1
    export LIBGL_DRIVERS_PATH="${lib.getLib mesa}/lib/dri"
    export __EGL_VENDOR_LIBRARY_DIRS="${mesa}/share/glvnd/egl_vendor.d"
    export LD_LIBRARY_PATH="${lib.getLib mesa}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export HOME="$TMPDIR"
    export XDG_RUNTIME_DIR="$TMPDIR"

    # Serial on purpose. The 11 windowed GL tests each wrap themselves
    # in `xvfb-run -a`, and -a picks a display number by probing lock
    # files — a race that every one of them loses under -j: the tests
    # themselves pass, then one instance's cleanup kills the X server
    # another is still talking to and the run dies with
    # "XIO: fatal IO error 22 on X server :99" after the assertions
    # already succeeded. One X server at a time costs about a minute.
    ctest --output-on-failure -j 1

    runHook postCheck
  '';

  # What makes `python3.withPackages (ps: [ threepp-python ])` work on a
  # derivation that is not a buildPythonPackage. pythonModule is how the
  # env recognises a module built for THIS interpreter; without
  # requiredPythonModules the env takes the package but drops its
  # dependencies on the floor, and `import threepp` then works while
  # `import numpy` beside it raises ModuleNotFoundError.
  passthru = lib.optionalAttrs withPython {
    pythonModule = python3;
    requiredPythonModules = python3.pkgs.requiredPythonModules [ python3.pkgs.numpy ];
  };

  doInstallCheck = withPython;

  # The import is the whole claim: a pybind11 module that builds and
  # installs can still fail to load (a missing DT_NEEDED, a package dir
  # shadowing the extension). numpy is pulled in because the package's
  # __init__ reaches for it.
  installCheckPhase = lib.optionalString withPython ''
    runHook preInstallCheck

    # No bytecode: a .pyc written as a side effect of this check would
    # land in $out carrying the source mtime, for nothing.
    export PYTHONDONTWRITEBYTECODE=1

    ${python3.withPackages (ps: [ ps.numpy ])}/bin/python -c '
    import sys
    sys.path.insert(0, "${placeholder "out"}/${python3.sitePackages}")
    import threepp
    print("threepp module:", threepp.__file__)
    print("vulkan_available:", threepp.vulkan_available())
    s = threepp.Scene()
    s.add(threepp.Mesh(threepp.BoxGeometry(1, 2, 3), threepp.MeshBasicMaterial()))
    print("children:", len(s.children))
    '

    runHook postInstallCheck
  '';

  strictDeps = true;

  meta = {
    description = "C++20 port of three.js: scene graph, OpenGL renderer and optional deferred Vulkan backend";
    homepage = "https://github.com/markaren/threepp";
    # threepp itself is MIT. The vendored sources compiled into the
    # library carry their own terms — notably libwebp's BSD-3 plus the
    # separate WebM patent grant. See THIRD_PARTY.md for the full map.
    license = with lib.licenses; [
      mit
      bsd3
      isc
      zlib
      publicDomain
    ];
    platforms = lib.platforms.unix;
  }
  // lib.optionalAttrs withEditor { mainProgram = "threepp_editor"; }
  // lib.optionalAttrs (withExamples && !withEditor) { mainProgram = "demo"; };
}
