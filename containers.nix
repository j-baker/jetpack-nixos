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
  libtirpc,
  libseccomp,
  substituteAll,
  git,
  writeShellScriptBin,
  coreutils,
  docker,
  shadow,
  bspSrc,
  pkgs,
  findutils,
pkg-config, rpcsvc-proto, makeWrapper, removeReferencesTo,
}:


let
  debsForSourcePackage = srcPackageName: lib.filter (pkg: (pkg.source or "") == srcPackageName) (builtins.attrValues debs.common);

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

  # First, extract the l4t.xml from the root image.
  l4tCsv = pkgs.runCommand "l4t.csv" {} ''
    tar -xf "${bspSrc}/nv_tegra/config.tbz2"
    mkdir -p "$out"
    mv etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv "$out"
  '';

  # make a single sources root of all the debs. TODO filter down to those that matter.
  unpackedDebs = pkgs.runCommand "depsForContainer" { nativeBuildInputs = [ dpkg ]; } ''
    mkdir -p $out
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: p: "echo Unpacking ${n}; dpkg -x ${p.src} $out") debs.common)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: p: "echo Unpacking ${n}; dpkg -x ${p.src} $out") debs.t234)}
  '';

  filteredDebs = pkgs.runCommand "filteredDepsForContainer" { nativeBuildInputs = [ findutils ]; } ''
    set -e
    copy_path() {
      FILE_PATH="$1"
      PARENT="$(dirname \"$FILE_PATH\")"
      mkdir -p "$out/$PARENT"
      (cp "${unpackedDebs}$FILE_PATH" "''${out}$FILE_PATH") || :
    }

    cat "${l4tCsv}/l4t.csv" | tr -d ' ' | cut -f2 -d',' | xargs copy_path
  '';

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
      ./nvc-ldcache.patch
      #./foo.patch
      ./avoid-static-libtirpc-build.patch
      # ./last.patch
      ./patchagain.patch
      #./patch1.patch
      #./patch2.patch
      #./patch3.patch
      #./patch4.patch
      #./patch5.patch
      #./patch6.patch
      #./patch7.patch
      ./patch8.patch
      #./patch9.patch
      ./patch10.patch
      ./patch11.patch
      ./patch12.patch
      ./patch13.patch
      ./patch14.patch
      ./patch15.patch
    ];
  postPatch = ''
    sed -i \
      -e 's/^REVISION :=.*/REVISION = ${src.rev}/' \
      -e 's/^COMPILER :=.*/COMPILER = $(CC)/' \
      mk/common.mk

    sed -i 's#/etc/nvidia-container-runtime/host-files-for-container.d#${l4tCsv}#g' src/nvc_info.c
    sed -i 's#NIXOS_BASE#${filteredDebs}#g' src/jetson_mount.c
    sed -i 's#NIXOS_BASE#${filteredDebs}#g' src/nvc_info.c

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

  NIX_CFLAGS_COMPILE = toString [ "-I${libtirpc.dev}/include/tirpc" ];
  NIX_LDFLAGS = [ "-L${libtirpc}/lib" "-ltirpc" ];

  nativeBuildInputs = [ pkg-config rpcsvc-proto makeWrapper removeReferencesTo ];

  buildInputs = [ git libelf libcap libseccomp libtirpc ];

  makeFlags = [
    "WITH_LIBELF=yes"
    "prefix=$(out)"
    # we can't use the WITH_TIRPC=yes flag that exists in the Makefile for the
    # same reason we patch out the static library use of libtirpc so we set the
    # define in CFLAGS
    "CFLAGS=-DWITH_TIRPC"
  ];
  };
in {
    inherit libnvidia_container0;
}