#!/bin/bash
# Toolchain stage, step 2 (runs with --network=none): build and install the cross toolchain
# into /opt/amiga from the sources fetch-sources.py laid out under /src, then delete the build
# tree and the sources in the same step so no image layer ever carries them. Verification and
# trimming live in finish-toolchain.sh, a separate (cheap) layer.
#
# What gets built (the orchestrator's `all` minus gdb and ixemul, see README):
#   binutils gcc gprof fd2sfd fd2pragma ira sfdc vasm libnix libgcc clib2 libdebug libpthread
#   ndk ndk13 libnix4.library   (+ newlib and the Roadshow netinclude as libnix dependencies)
#   sdk=ahi                     (AHI developer headers, used by poseidon's audio class)
#   lha, flexcat                host tools, built here from their pinned sources
#   two NDK headers the orchestrator gets wrong, generated here with the same sfdc + NDK archive
set -euo pipefail

SRC=${SRC:-/src}
ORCH=$SRC/amiga-gcc
PREFIX=${PREFIX:-/opt/amiga}
JOBS=${JOBS:-$(nproc)}

# The Makefile's `all` when HOST is empty. We deliberately build a subset; if upstream changes
# `all`, fail so the subset below gets reviewed instead of silently drifting.
EXPECTED_ALL='all: gcc binutils gdb gprof fd2sfd fd2pragma ira sfdc vasm libnix ixemul libgcc clib2 libdebug libpthread ndk ndk13 libnix4.library'
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
# lha first: the Makefile's $(PREFIX)/bin/lha file rule (which would clone a branch head) is
# satisfied by the file existing, and the NDK unpack + sdk installer need it.
echo ">> building lha"
( cd "$SRC/lha" && autoreconf -fi && ./configure --prefix="$PREFIX" && make -j"$JOBS" all ) > "$SRC/lha.log" 2>&1 \
	|| { tail -n 100 "$SRC/lha.log"; exit 1; }
install -m755 "$SRC/lha/src/lha" "$PREFIX/bin/lha"

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

echo ">> make sdk=ahi"
make "${make_args[@]}" sdk=ahi || { dump_logs; exit 1; }

# SANA-II headers: not in the NDK's Include_H nor in the Roadshow netinclude; the AROS copies
# (pinned in toolchain.lock.json) are what consumers have always compiled against.
install -m644 "$SRC"/extra/devices/*.h "$PREFIX/m68k-amigaos/ndk-include/devices/"
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

echo ">> built: $("$PREFIX/bin/m68k-amigaos-gcc" --version | head -1)"

# Everything below /src except what later stages copy (download/MUI*.lha, extra/, SOURCES).
cd /
rm -rf "$BUILD" "$ORCH" "$SRC/lha" "$SRC/flexcat" "$SRC"/*.log
du -sh "$PREFIX"
