{
  lib,
  stdenv,
  dpkg,
  debs,
  autoPatchelfHook,
  autoAddOpenGLRunpathHook,
  addOpenGLRunpath,
  fetchFromGitHub,
  libelf,
  libcap,
  libseccomp,
  substituteAll,
  git,
  writeShellScriptBin,
  coreutils,
  docker,
  shadow,
pkg-config, rpcsvc-proto, makeWrapper, removeReferencesTo,
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

  modprobeVersion = "396.51";
  nvidia-modprobe = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "nvidia-modprobe";
    rev = modprobeVersion;
    sha256 = "sha256-c2G0qatv0LMZ0RAbluB9TyHkZAVbdGf4U8RMghjHgrs=";
  };
  modprobePatch = substituteAll {
    src = ./modprobe.patch;
    inherit modprobeVersion;
  };

  libnvidia_container0 = stdenv.mkDerivation rec {
    pname = "libnvidia-container";
    version = "0.11.0+jetpack";
    src = fetchFromGitHub {
      owner = "NVIDIA";
      repo = "libnvidia-container";
      rev = "v${version}";
      sha256 = "sha256-dRK0mmewNL2jIvnlk0YgCfTHuIc3BuZhIlXG5VqBQ5Q=";
    };

    patches = [
      ./nvc_ldcache.patch
    ];

  postPatch = ''
    sed -i \
      -e 's/^REVISION :=.*/REVISION = ${src.rev}/' \
      -e 's/^COMPILER :=.*/COMPILER = $(CC)/' \
      mk/common.mk

    mkdir -p deps/src/nvidia-modprobe-${modprobeVersion}
    cp -r ${nvidia-modprobe}/* deps/src/nvidia-modprobe-${modprobeVersion}
    chmod -R u+w deps/src
    pushd deps/src

    # patch -p0 < ${modprobePatch}
    touch nvidia-modprobe-${modprobeVersion}/.download_stamp
    popd

    # 1. replace DESTDIR=$(DEPS_DIR) with empty strings to prevent copying
    #    things into deps/src/nix/store
    # 2. similarly, remove any paths prefixed with DEPS_DIR
    # 3. prevent building static libraries because we don't build static
    #    libtirpc (for now)
    # 4. prevent installation of static libraries because of step 3
    # 5. prevent installation of libnvidia-container-go.so twice
    sed -i Makefile \
      -e 's#DESTDIR=\$(DEPS_DIR)#DESTDIR=""#g' \
      -e 's#\$(DEPS_DIR)\$#\$#g' \
      -e 's#all: shared static tools#all: shared tools#g' \
      -e '/$(INSTALL) -m 644 $(LIB_STATIC) $(DESTDIR)$(libdir)/d' \
      -e '/$(INSTALL) -m 755 $(libdir)\/$(LIBGO_SHARED) $(DESTDIR)$(libdir)/d'
  '';

  enableParallelBuilding = true;

  preBuild = ''
    HOME="$(mktemp -d)"
  '';

  nativeBuildInputs = [ pkg-config rpcsvc-proto makeWrapper removeReferencesTo ];

  buildInputs = [ git libelf libcap libseccomp ];

  makeFlags = [
    "WITH_LIBELF=yes"
    "prefix=$(out)"
    # we can't use the WITH_TIRPC=yes flag that exists in the Makefile for the
    # same reason we patch out the static library use of libtirpc so we set the
    # define in CFLAGS
  ];

  postInstall =
    let
      inherit (addOpenGLRunpath) driverLink;
      libraryPath = lib.makeLibraryPath [ "$out" driverLink "${driverLink}-32" ];
    in
    ''
      wrapProgram $out/bin/nvidia-container-cli --prefix LD_LIBRARY_PATH : ${libraryPath}
    '';
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
  nvidia_ctk = writeShellScriptBin "nvidia-ctk" ''
    echo "$@" > /root/args
    ${nvidia_container_toolkit}/bin/nvidia-ctk "$@" 2>&1 | ${coreutils}/bin/tee /root/ctk
  '';
  nvidia_container_runtime_hook = writeShellScriptBin "nvidia-container-runtime-hook" ''
    exec ${nvidia_container_toolkit}/bin/nvidia-container-runtime-hook -c /root/flake/config.toml "$@"
  '';
in {
    inherit libnvidia_container0 libnvidia_container1 libnvidia_container_tools;
    # nvidiaContainerRuntime = nvidia_container_toolkit;
    nvidiaContainerRuntime = writeShellScriptBin "nvidia-container-runtime" ''
      export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${lib.makeLibraryPath [libnvidia_container0]}"
      export PATH="$PATH:${nvidia_ctk}/bin:${nvidia_container_runtime_hook}/bin:${docker}/bin:${shadow}/bin"
      exec ${nvidia_container_toolkit}/bin/nvidia-container-runtime "$@"
    '';
}