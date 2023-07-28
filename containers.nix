{
  lib,
  stdenv,
  dpkg,
  debs,
  autoPatchelfHook,
  autoAddOpenGLRunpathHook,
  libcap,
  libseccomp,
  writeShellScriptBin,
  coreutils,
}:

let
  debsForSourcePackage = srcPackageName: lib.filter (pkg: (pkg.source or "") == srcPackageName) (builtins.attrValues debs.common);

  buildFromDebs =
    { name, srcs, version ? debs.common.${name}.version,
      sourceRoot ? "source", buildInputs ? [], nativeBuildInputs ? [],
      postPatch ? "", postFixup ? "", autoPatchelf ? true, ...
    }@args:
    stdenv.mkDerivation ((lib.filterAttrs (n: v: !(builtins.elem n [ "name" "autoPatchelf" ])) args) // {
      pname = name;
      inherit version srcs;

      nativeBuildInputs = [ dpkg autoPatchelfHook autoAddOpenGLRunpathHook ] ++ nativeBuildInputs;
      buildInputs = [ stdenv.cc.cc.lib ] ++ buildInputs;

      unpackCmd = "for src in $srcs; do dpkg-deb -x $src source; done";

      dontConfigure = true;
      dontBuild = true;
      noDumpEnvVars = true;

      # In cross-compile scenarios, the directory containing `libgcc_s.so` and other such
      # libraries is actually under a target-specific directory such as
      # `${stdenv.cc.cc.lib}/aarch64-unknown-linux-gnu/lib/` rather than just plain `/lib` which
      # makes `autoPatchelfHook` fail at finding them libraries.
      postFixup = (lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
        addAutoPatchelfSearchPath ${stdenv.cc.cc.lib}/*/lib/
      '') + postFixup;

      postPatch = ''
        if [[ -d usr ]]; then
          cp -r usr/. .
          rm -rf usr
        fi

        if [[ -d local ]]; then
          cp -r local/. .
          rm -rf local
        fi

        if [[ -d targets ]]; then
          cp -r targets/*/* .
          rm -rf targets
        fi

        if [[ -d etc ]]; then
          rm -rf etc/ld.so.conf.d
          rmdir --ignore-fail-on-non-empty etc
        fi

        if [[ -d include/aarch64-linux-gnu ]]; then
          cp -r include/aarch64-linux-gnu/. include/
          rm -rf include/aarch64-linux-gnu
        fi

        if [[ -d lib/aarch64-linux-gnu ]]; then
          cp -r lib/aarch64-linux-gnu/. lib/
          rm -rf lib/aarch64-linux-gnu
        fi

        rm -f lib/ld.so.conf

        ${postPatch}
      '';

      installPhase = ''
        cp -r . $out
      '';

      meta = {
        platforms = [ "aarch64-linux" ];
      } // (args.meta or {});
    });

  # Combine all the debs that originated from the same source package and build
  # from that
  buildFromSourcePackage = { name, ...}@args: buildFromDebs ({
    inherit name;
    # Just using the first package for the version seems fine
    version = (lib.head (debsForSourcePackage name)).version;
    srcs = builtins.map (deb: deb.src) (debsForSourcePackage name);
  } // args);
  libnvidia_container0 = buildFromDebs {
    name = "libnvidia-container0";
    buildInputs = [ libcap libseccomp ];
    srcs = debs.common."libnvidia-container0".src;
    meta.platforms = [ "aarch64-linux" ];
  };
  libnvidia_container1 = buildFromDebs {
    name = "libnvidia-container1";
    buildInputs = [ libcap libseccomp ];
    srcs = debs.common."libnvidia-container1".src;
    meta.platforms = [ "aarch64-linux" ];
  };
  libnvidia_container_tools = buildFromDebs {
    name = "libnvidia-container-tools";
    buildInputs = [ libnvidia_container1 libcap ];
    srcs = debs.common."libnvidia-container-tools".src;
    meta.platforms = [ "aarch64-linux" ];
  };
  nvidia_container = buildFromDebs {
    name = "nvidia-container";
    buildInputs = [];
    srcs = debs.common."nvidia-container".src;
    meta.platforms = [ "aarch64-linux" ];
  };
  nvidia_container_runtime = buildFromDebs {
    name = "nvidia-container-runtime";
    buildInputs = [];
    srcs = debs.common."nvidia-container-runtime".src;
    meta.platforms = [ "aarch64-linux" ];
  };
  nvidia_container_toolkit = buildFromDebs {
    name = "nvidia-container-toolkit";
    buildInputs = [];
    srcs = debs.common."nvidia-container-toolkit".src;
    meta.platforms = [ "aarch64-linux" ];
  };
in {
    inherit libnvidia_container0 libnvidia_container1 libnvidia_container_tools;
    # nvidiaContainerRuntime = nvidia_container_toolkit;
    nvidiaContainerRuntime = writeShellScriptBin "nvidia-container-runtime" ''
      export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${lib.makeLibraryPath [libnvidia_container_tools libnvidia_container0]}"
      export PATH="$PATH:${nvidia_container_toolkit}/bin"
      exec ${nvidia_container_toolkit}/bin/nvidia-container-runtime --config "/root/flake/config.toml" "$@"
    '';
}