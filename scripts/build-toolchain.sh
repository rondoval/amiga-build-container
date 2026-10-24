#!/bin/bash
# Toolchain stage, step 2 (runs with --network=none): build and install the cross toolchain
# into /opt/amiga from the sources fetch-sources.py laid out under /src, then delete the build
# tree and the sources in the same step so no image layer ever carries them. Verification and
# trimming live in finish-toolchain.sh, a separate (cheap) layer.
#
# What gets built (the orchestrator's `all` minus gdb and ixemul, see README):
#   binutils gcc gprof fd2sfd fd2pragma ira sfdc vasm libnix libgcc clib2 libdebug libpthread
#   ndk ndk13 libnix4.library   (+ newlib and the Roadshow netinclude as libnix dependencies,
#                                lha as the NDK unpack's and the SDK installer's)
#   sdk=<each line of SDKS>     (ahi: neptune's audio class; p96: emu68's vchiq tools)
#   flexcat                     host tool, built here from its pinned source
#   two NDK headers the orchestrator gets wrong, generated here with the same sfdc + NDK archive
#   headers for the SFD-only interfaces in extra/sfd (the Emu68 resources), same sfdc
set -euo pipefail

SRC=${SRC:-/src}
ORCH=$SRC/amiga-gcc
PREFIX=${PREFIX:-/opt/amiga}
JOBS=${JOBS:-$(nproc)}

# The Makefile's `all` ($(ALL_GDB) is gdb when HOST is empty). We deliberately build a subset,
# and never `all` itself, whose recipe also writes the module manifest from the .git trees
# fetch-sources.py drops; if upstream changes `all`, fail so the subset below gets reviewed
# instead of silently drifting.
EXPECTED_ALL='all: gcc binutils $(ALL_GDB) gprof fd2sfd fd2pragma ira sfdc vasm libnix ixemul libgcc clib2 libdebug libpthread ndk ndk13 libnix4.library'
TARGETS='binutils gcc gprof fd2sfd fd2pragma ira sfdc vasm libnix libgcc clib2 libdebug libpthread ndk ndk13 libnix4.library'

cd "$ORCH"
BUILD=$PWD/build-$(uname -s)-m68k-amigaos     # the Makefile's $(BUILD)

actual_all=$(grep -m1 '^all: ' Makefile)
[ "$actual_all" = "$EXPECTED_ALL" ] || {
	echo "build-toolchain: the orchestrator's 'all' target changed:" >&2
	echo "  expected: $EXPECTED_ALL" >&2
	echo "  actual:   $actual_all" >&2
	echo "Review TARGETS in $0 against the new list, then update EXPECTED_ALL." >&2
	exit 1
}

mkdir -p "$PREFIX/bin" "$PREFIX/etc"
export PATH=$PREFIX/bin:$PATH

# ---- host tools ----------------------------------------------------------------------------
# lha is an orchestrator module (projects/lha), built by make for the NDK unpack.
echo ">> building flexcat"
( cd "$SRC/flexcat/src" && make OS=unix CC=cc DEBUG= DEBUGSYM= bootstrap && make OS=unix CC=cc DEBUG= DEBUGSYM= ) > "$SRC/flexcat.log" 2>&1 \
	|| { tail -n 100 "$SRC/flexcat.log"; exit 1; }
install -m755 "$SRC/flexcat/src/bin_unix/flexcat" "$PREFIX/bin/flexcat"

# ---- the toolchain -------------------------------------------------------------------------
# NEWLIB_BINUTILS_PREREQ: with HOST empty the Makefile makes newlib (hence libnix, hence
# everything, including `sdk`) wait for the gdb stamp; point it at the binutils stamp so gdb is
# never built. Every make invocation must carry it.
make_args=(PREFIX="$PREFIX" NEWLIB_BINUTILS_PREREQ="$BUILD/binutils/_done")
dump_logs() { echo "build-toolchain: make failed; last lines of the per-step logs:" >&2; for f in log/*; do echo "==== $f"; tail -n 60 "$f"; done >&2; }

echo ">> make $TARGETS"
make -j"$JOBS" "${make_args[@]}" $TARGETS || { dump_logs; exit 1; }

# Each from the archive pre-downloaded under download/, which scripts/sdk-download accepts by
# checksum.
while read -r sdk; do
	echo ">> make sdk=$sdk"
	make "${make_args[@]}" sdk="$sdk" || { dump_logs; exit 1; }
done < "$SRC/SDKS"

install -m644 "$SRC/SOURCES" "$PREFIX/etc/SOURCES"

# ---- two NDK headers the orchestrator gets wrong ------------------------------------------
# Generated with the pinned sfdc from the pinned NDK archive, exactly like the other headers;
# nothing is edited. Both are upstream inconsistencies (see README) and can go once fixed there.
ndk=$ORCH/projects/NDK3.2
ndkinc=$PREFIX/m68k-amigaos/ndk-include
sfdc=$PREFIX/bin/sfdc

# card.resource: sfdc derives the names it references from the SFD's ==libname (card.resource
# -> card) while the NDK names its files after the SFD (cardres_lib.sfd -> cardres.*), so sfdc's
# proto/cardres.h includes a clib/card_protos.h that does not exist and, since sfdc 1.12,
# inline/cardres.h includes proto/card.h. The orchestrator's NDK rule copies the NDK's own
# proto/cardres.h explicitly, then its sfdc proto rule overwrites it. Put the NDK's back and
# generate the inline header pointing at it (sfdc's --protoname exists for exactly this).
echo ">> cardres: the NDK's proto header, inline header generated with --protoname"
install -m644 "$ndk/Include_H/proto/cardres.h" "$ndkinc/proto/cardres.h"
"$sfdc" --target=m68k-gcc-amigaos --mode=macros --protoname=cardres --quiet \
	--output="$ndkinc/inline/cardres.h" "$ndk/SFD/cardres_lib.sfd"

# bsdsocket.library: amiga-netinclude ships Roadshow's 2017 fd2pragma inline header rewritten by
# hand into asm stubs (register-pinned inputs repeated in the clobber lists, a hard error since
# GCC 9; varargs through the _sfdc_vararg type sfdc no longer defines everywhere). The NDK
# archive carries Roadshow's own SFD; generate the inline header from it instead.
echo ">> bsdsocket: inline header generated from the NDK's Roadshow SFD"
install -m644 "$ndk/SANA+RoadshowTCP-IP/sfd/bsdsocket_lib.sfd" "$PREFIX/m68k-amigaos/ndk/lib/sfd/"
"$sfdc" --target=m68k-gcc-amigaos --mode=macros --quiet \
	--output="$ndkinc/inline/bsdsocket.h" "$PREFIX/m68k-amigaos/ndk/lib/sfd/bsdsocket_lib.sfd"

# ---- SFD-only interfaces (the Emu68 resources) --------------------------------------------
# Upstream ships only the SFD (plus, for cma, a public header). Generate the headers with the
# modes and targets of the orchestrator's scripts/sdk-install clib + sfdc verbs, so they match
# every other SDK header under m68k-amigaos/include/ (sfdc's vbcc variant is left out, as for
# the NDK).
sdkinc=$PREFIX/m68k-amigaos/include
mkdir -p "$PREFIX/m68k-amigaos/lib/sfd" "$sdkinc/clib" "$sdkinc/proto" "$sdkinc/inline" "$sdkinc/lvo"
for sfd in "$SRC"/extra/sfd/*_lib.sfd; do
	name=$(basename "$sfd" _lib.sfd)
	echo ">> $name: headers generated from its SFD"
	install -m644 "$sfd" "$PREFIX/m68k-amigaos/lib/sfd/"
	"$sfdc" --target=m68k-amigaos     --mode=clib   --quiet --output="$sdkinc/clib/${name}_protos.h" "$sfd"
	"$sfdc" --target=m68k-gcc-amigaos --mode=proto  --quiet --output="$sdkinc/proto/$name.h" "$sfd"
	"$sfdc" --target=m68k-gcc-amigaos --mode=macros --quiet --output="$sdkinc/inline/$name.h" "$sfd"
	"$sfdc" --target=m68k-amigaos     --mode=lvo    --quiet --output="$sdkinc/lvo/$name.i" "$sfd"
done
( cd "$SRC/extra/include" && find . -type f -exec install -D -m644 {} "$sdkinc/{}" \; )

echo ">> built: $("$PREFIX/bin/m68k-amigaos-gcc" --version | head -1)"

# Everything below /src except what later stages copy (download/MUI*.lha, extra/, SOURCES).
cd /
rm -rf "$BUILD" "$ORCH" "$SRC/flexcat" "$SRC"/*.log
du -sh "$PREFIX"
