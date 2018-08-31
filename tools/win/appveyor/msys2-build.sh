#!/usr/bin/env bash
# MSYS2 build and test script for MyPaint.
# All rights waived: https://creativecommons.org/publicdomain/zero/1.0/
#
#: Usage:
#:   $ msys2_build.sh [OPTIONS]
#:
#: OPTIONS:
#:   installdeps  Build+install dependencies.
#:   build        Build MyPaint itself from this source tree.
#:   clean        Clean the build tree.
#:   tests        Runs tests on the built source.
#:   doctest      Check to make sure all python docs work.
#:   bundle       Creates installer bundles in ./out/bundles
#:
#:  This script is designed to be called by AppVeyor or Tea-CI. However
#:  it's clean enough to run from an interactive shell. It expects to be
#:  called with MSYSTEM="MINGW{64,32}", i.e. from an MSYS2 "native" shell.
#: 
#:  Build artifacts are written to ./out/pkgs and ./out/bundles by default.
#trap "set +x; sleep 2; set -x" DEBUG
set -e

# ANSI control codes
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script name and location.
SCRIPT=`basename "$0"`
SCRIPTDIR=`dirname "$0"`
cd "$SCRIPTDIR/.."

# Main repository location, as an absolute path.
TOPDIR=`pwd`
cd "$TOPDIR"

# Ensure we're being run from one of MSYS2's "native shells".
case "$MSYSTEM" in
    "MINGW64")
        PKG_PREFIX="mingw-w64-x86_64"
        MINGW_INSTALLS="mingw64"
        BUNDLE_ARCH="w64"
        ;;
    "MINGW32")
        PKG_PREFIX="mingw-w64-i686"
        MINGW_INSTALLS="mingw32"
        BUNDLE_ARCH="w32"
        ;;
    *)
        echo >&2 "$SCRIPT must only be called from a MINGW64/32 login shell."
        exit 1
        ;;
esac
export MINGW_INSTALLS

# This script pulls down and maintains a clone of the pkgbuild tree for
# MSYS2's MINGW32 and MINGW64 software.

SRC_PROJECT="mingw"
SRC_DIR="${SRC_ROOT}/${SRC_PROJECT}"


# Output location for build artefacts.
OUTPUT_ROOT="${OUTPUT_ROOT:-$TOPDIR/out}"


install_dependencies() {
    pushd /home
    pwd -W
    popd
    env
    # reduce time required to install packages by disabling pacman's disk space checking
    sed -i 's/^CheckSpace/#CheckSpace/g' /etc/pacman.conf
    loginfo "Upgrading MSYS2 environment"
    pacman -Syu --noconfirm
    
    loginfo "core update"
    
    loginfo " installing required tools"
    pacman -S --noconfirm --needed --noprogressbar \
    base-devel tar gzip nano make diffutils intltool git zip
    loginfo "Installing pre-built dependencies "
#    pacman -Rs --noconfirm\
#    ${PKG_PREFIX}-{gcc-objc,gcc-fortran,gcc-ada,gcc-libgfortran,gcc-libs}
    pacman -S --noconfirm --needed --noprogressbar \
    ${PKG_PREFIX}-{toolchain,gcc,gdb,make,pkg-config,cmake,gtkmm3,lcms2,fftw,lensfun,nsis}
    logok "Dependencies installed."
    
    loginfo "building libiptc"
    pushd /tmp
    curl -LO http://downloads.sourceforge.net/project/libiptcdata/libiptcdata/1.0.4/libiptcdata-1.0.4.tar.gz
    tar xzf libiptcdata-1.0.4.tar.gz
    cd libiptcdata-1.0.4
    ./configure --prefix=/$MSYSTEM
    sed -i -e 's/DIST_SUBDIRS = m4 libiptcdata po iptc docs win python/DIST_SUBDIRS = m4 libiptcdata po win python/' Makefile 
    sed -i -e 's/SUBDIRS = m4 libiptcdata po iptc docs win $(MAYBE_PYTHONLIB)/SUBDIRS = m4 libiptcdata po win $(MAYBE_PYTHONLIB)/' Makefile 
    make
    make install
    popd
}


loginfo() {
    echo -ne "${CYAN}"
    echo -n "$@"
    echo -e "${NC}"
}


logok() {
    echo -ne "${GREEN}"
    echo -n "$@"
    echo -e "${NC}"
}


logerr() {
    echo -ne "${RED}ERROR: "
    echo -n "$@"
    echo -e "${NC}"
}


check_output_dir() {
    type="$1"
    if test -d "$OUTPUT_ROOT/$type"; then
        return
    fi
    mkdir -vp "$OUTPUT_ROOT/$type"
}


update_mingw_src() {
    # Initialize or update the managed MINGW-packages sources dir.
    if test -d "$SRC_DIR"; then
        loginfo "Updating $SRC_DIR..."
        pushd "$SRC_DIR"
        git pull
    else
        loginfo "Creating $SRC_ROOT"
        mkdir -vp "$SRC_ROOT"
        pushd "$SRC_ROOT"
        loginfo "Shallow-cloning $SRC_CLONEURI into $SRC_DIR..."
        git clone --depth 1 "$SRC_CLONEURI" "$SRC_PROJECT"
    fi
    popd
    logok "Updated $SRC_DIR" 
}


seed_mingw_src_rawtherapee_repo() {
    # Seed the MyPaint source repository that makepkg-mingw wants
        
#    repo="$SRC_DIR/mingw-w64-mypaint-git/mypaint"
#    test -d "$TOPDIR/.git" || return
#    test -d "$repo" && return
    loginfo "Seeding $repo..."
#    git clone --local --no-hardlinks --bare "$TOPDIR" "$repo"
#    pushd "$repo"
    pushd $APPVEYOR_BUILD_FOLDER
#    git remote remove origin
#    git remote add origin https://github.com/gaaned92/rawtherapee.git
#    git fetch origin
     git clone --no-checkout https://github.com/gaaned92/rawtherapee.git
    popd
    logok "Seeded $repo" 
}


build_pkg() {
    # Build and optionally install a .pkg.tar.xz from the
    # managed tree of PKGBUILDs.
    #
    # Usage: build_pkg PKGNAMESTEM {true|false}

    if ! test -d "$SRC_DIR"; then
        logerr "Managed src dir $SRC_DIR does not exist (update_mingw_src 1st)"
        exit 2
    fi

    pkgstem="$1"
    install="$2"
    src="${SRC_DIR}/mingw-w64-$pkgstem"
    pushd "$src"
    rm -vf *.pkg.tar.xz

    # This only builds for the arch in MINGW_INSTALLS, i.e. the current
    # value of MSYSTEM.
    loginfo "Building in $src for $MINGW_INSTALLS ..."
    MSYSTEM=MSYS2 bash --login -c 'cd "$1" && makepkg-mingw -f' - "$src"
    logok "Build finished."

    if $install; then
        loginfo "Installing built packages..."
        pacman -U --noconfirm *.pkg.tar.xz
        logok "Install finished."
    fi
    popd

    loginfo "Capturing build artifacts..."
    check_output_dir "pkgs"
    mv -v "$src"/*.pkg.tar.xz "$OUTPUT_ROOT/pkgs"
    logok "Packages moved."
}


bundle() {
    # Convert local and repository *.pkg.tar.xz into nice bundles
    # for users to install.
    # Needs the libmypaint-git and mypaint-git .pkg.tar.xz artefacts.
    styrene_path=`which styrene||true`
    if [ "x$styrene_path" = "x" ]; then
        mkdir -vp "$SRC_ROOT"
        pushd "$SRC_ROOT"
        if [ -d styrene ]; then
            loginfo "Updating managed Styrene source"
            pushd styrene
            git pull
        else
            loginfo "Cloning managed Styrene source"
            git clone https://github.com/achadwick/styrene.git
            pushd styrene
        fi
        loginfo "Installing styrene with pip3..."
        pip3 install .
        loginfo "Installed styrene."
        popd
        popd
    fi

    check_output_dir "bundles"
    loginfo "Creating installer bundles..."

    tmpdir="/tmp/styrene.$$"
    mkdir -p "$tmpdir"
    styrene --colour=yes \
        --pkg-dir="$OUTPUT_ROOT/pkgs" \
        --output-dir="$tmpdir" \
        "$TOPDIR/windows/styrene/mypaint.cfg"
        
    output_version=$(echo $BUNDLE_ARCH-$APPVEYOR_BUILD_VERSION | sed -e 's/[^a-zA-Z0-9._-]/-/g')

    mv -v "$tmpdir"/*-standalone.zip \
        "$OUTPUT_ROOT/bundles/mypaint-git-$output_version-standalone.zip"
    mv -v "$tmpdir"/*-installer.exe  \
        "$OUTPUT_ROOT/bundles/mypaint-git-$output_version-installer.exe"
        
    ls -l "$OUTPUT_ROOT/bundles"/*.*

    rm -fr "$tmpdir"

    logok "Bundle creation finished."
}

# Test Build, Clean, and Install tools to make sure all of setup.py is
# working as intended.

build() {
    loginfo "Building Rawtherapee from source"
    #location of build and install dir
    BUILD="${BUILD:-/tmp/build}"
    INSTALL="${INSTALL:-/tmp/install}"
    BUILDDEBUG="${BUILD:-/tmp/builddebug}"
    #
    # determine branch, version and number of commits from tag
    #
    cd $APPVEYOR_BUILD_FOLDER
    pwd -W
    dir
    ls -d -- */
    BRANCH=$(echo  $(git symbolic-ref --short -q HEAD))
    echo "branch=   " $BRANCH
    ver=$(git describe --tags --always)
    echo "version=  " $ver
    GIT_TAG=$(git tag --merged HEAD)
    GIT_COMMITS=$(git rev-list --count HEAD --not ${GIT_TAG})
    
    #RawTherapee cache location
    CACHE="5-DEV"
    PROC=$(echo $(getconf _NPROCESSORS_ONLN 2>/dev/null || getconf NPROCESSORS_ONLN 2>/dev/null || echo 1))
    #CMAKE release
    mkdir $BUILD
    pushd $BUILD
    CXX_FLAGS="-m64 -mwin32 -mfpmath=sse -mthreads -Wno-aggressive-loop-optimizations -Wno-parentheses  -O3 "
    LINKER_FLAGS="-m64  -mthreads  -static-libgcc -s  -O3  -fno-use-linker-plugin"

    cmake -G "MSYS Makefiles"  -DCMAKE_BUILD_TYPE="release"  -DCMAKE_CXX_FLAGS=$CXX_FLAGS -DCMAKE_C_FLAGS=$CXX_FLAGS  -DCMAKE_EXE_LINKER_FLAGS=$LINKER_FLAGS \
        -DCACHE_NAME_SUFFIX="5-dev" \
        -DPROC_TARGET_NUMBER="1" \
        -DBUNDLE_BASE_INSTALL_DIR=$INSTALL \
        -DOPTION_OMP="ON" -DWITH_MYFILE_MMAP="ON" \
        -DWITH_LTO="OFF" \
        -DWITH_PROF="OFF" \
        -DWITH_SAN="OFF" \
        $APPVEYOR_BUILD_FOLDER
    mkdir $INSTALL
    mingw32-make  -j$PROC install
    popd
    pushd $INSTALL
    dir
    popd
    logok "Build finished."
}

clean_local_repo() {
    loginfo "Cleaning local build"
    python setup.py clean --all
    rm -vf lib/*_wrap.c*
    logok "Clean finished."
}

install_test(){
    # TODO: Look into this to find out why it is failing.
    loginfo "Testing setup.py managed installation commands"
    python setup.py managed_install
    python setup.py managed_uninstall
    logok "Install-test finished finished."
}

# Can't test everything from TeaCI due to wine crashing.
# However, it's always appropriate to run the doctests.
# With Appveyor, the tests scripts should run just fine.

run_doctest() {
    loginfo "Running unit tests."
    python setup.py nosetests --tests lib
    logok "Unit tests done."
}

run_tests() {
    loginfo "Running conformance tests."
    python setup.py test
    logok "Tests done."
}


# Command line processing

case "$1" in
    installdeps)
         loginfo " installdeps empty"
         install_dependencies
#        update_mingw_src
#        build_pkg "libmypaint-git" true
        ;;
    build)
        seed_mingw_src_rawtherapee_repo
        build
        ;;
    clean)
        clean_local_repo
        ;;
    tests)
        run_tests
        # install_test
        ;;
    doctest)
        run_doctest
        ;;
    bundle)
        update_mingw_src
        seed_mingw_src_mypaint_repo
        build_pkg "mypaint-git" false
        bundle_mypaint
        ;;
    *)
        grep '^#:' $0 | cut -d ':' -f 2-50
        exit 2
        ;;
esac