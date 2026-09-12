#!/bin/bash
# Toolchain stage, step 3 (runs with --network=none, after build-toolchain.sh): assert the
# installed prefix has what the consumer stacks rely on, strip the host binaries and trim
# docs. Kept in its own file, copied into the image after the build step, so that editing it
# never invalidates the 15-minute toolchain layer.
set -euo pipefail

SRC=${SRC:-/src}
PREFIX=${PREFIX:-/opt/amiga}

expected_version=$(awk '$1 == "gcc-version" { print $2 }' "$SRC/SOURCES")
actual_version=$("$PREFIX/bin/m68k-amigaos-gcc" -dumpfullversion)
[ "$actual_version" = "$expected_version" ] || { echo "gcc version $actual_version != BASE-VER $expected_version" >&2; exit 1; }

# ---- assertions --------------------------------------------------------------------------
# The two headers build-toolchain.sh generates itself (see there): the NDK's own proto/cardres.h
# with sfdc's inline header pointing back at it, and the sfdc-generated inline/bsdsocket.h.
inc=$PREFIX/m68k-amigaos/ndk-include
grep -q '^#include <inline/cardres.h>' "$inc/proto/cardres.h" \
	|| { echo "proto/cardres.h is not the NDK's own header" >&2; exit 1; }
grep -q '^#include <proto/cardres.h>' "$inc/inline/cardres.h" \
	|| { echo "inline/cardres.h does not reference proto/cardres.h (--protoname lost?)" >&2; exit 1; }
grep -q '^/\* Automatically generated header (sfdc' "$inc/inline/bsdsocket.h" \
	|| { echo "inline/bsdsocket.h is not the sfdc-generated header" >&2; exit 1; }

# Paths the consumer stacks rely on (toolchain.cmake and their CMake lists).
missing=0
for f in \
	bin/m68k-amigaos-gcc bin/m68k-amigaos-g++ bin/m68k-amigaos-ld bin/m68k-amigaos-objdump bin/m68k-amigaos-strip \
	bin/sfdc bin/fd2sfd bin/fd2pragma bin/vasmm68k_mot bin/lha bin/flexcat \
	m68k-amigaos/lib/libamiga.a m68k-amigaos/lib/libdebug.a m68k-amigaos/lib/libc.a m68k-amigaos/lib/libm.a \
	m68k-amigaos/lib/libstubs.a m68k-amigaos/libnix/lib/libnix20.a m68k-amigaos/libnix/lib/libm020/libnix20.a \
	m68k-amigaos/clib2/lib/libc.a m68k-amigaos/sys-include/stdio.h \
	m68k-amigaos/ndk-include/exec/types.h m68k-amigaos/ndk-include/libraries/keymap.h \
	m68k-amigaos/ndk-include/proto/exec.h m68k-amigaos/ndk-include/inline/exec.h \
	m68k-amigaos/ndk-include/inline/bsdsocket.h m68k-amigaos/ndk-include/sys/socket.h \
	m68k-amigaos/ndk-include/devices/sana2.h m68k-amigaos/ndk-include/devices/sana2specialstats.h \
	m68k-amigaos/ndk-include/devices/newstyle.h m68k-amigaos/ndk/lib/sfd/exec_lib.sfd \
	m68k-amigaos/ndk/lib/sfd/bsdsocket_lib.sfd \
	m68k-amigaos/include/devices/ahi.h m68k-amigaos/include/libraries/ahi_sub.h m68k-amigaos/include/proto/ahi.h \
	lib/gcc/m68k-amigaos/$actual_version/libgcc.a etc/SOURCES
do
	[ -e "$PREFIX/$f" ] || { echo "missing: $PREFIX/$f" >&2; missing=1; }
done
[ "$missing" = 0 ]
multilibs=$("$PREFIX/bin/m68k-amigaos-gcc" -print-multi-lib | wc -l)
[ "$multilibs" -ge 10 ] || { echo "only $multilibs multilibs configured" >&2; exit 1; }

# ---- trim ---------------------------------------------------------------------------------
# Strip host executables only (never the m68k target archives under lib/ and lib/gcc/).
echo ">> stripping host binaries"
find "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/m68k-amigaos/bin" -type f -print0 \
	| while IFS= read -r -d '' f; do
		case $(file -b "$f") in ELF\ 64-bit*x86-64*) strip --strip-unneeded "$f" 2>/dev/null || true ;; esac
	done
rm -rf "$PREFIX/share/man" "$PREFIX/share/info" "$PREFIX/share/locale" \
	"$PREFIX/lib/gcc/m68k-amigaos/$actual_version/plugin/include" \
	"$PREFIX/lib/gcc/m68k-amigaos/$actual_version/install-tools"
# amiga-netinclude's files are committed with the executable bit; headers are not programs.
find "$inc" -type f -perm -u+x -exec chmod 644 {} +

echo ">> ready: $("$PREFIX/bin/m68k-amigaos-gcc" --version | head -1)"
du -sh "$PREFIX"
