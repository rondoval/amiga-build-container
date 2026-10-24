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
# gcc is configured --with-gcc-major-version-only: its versioned directories under lib/gcc and
# libexec/gcc carry the major version alone, which is what -dumpversion reports.
gcc_dir=$("$PREFIX/bin/m68k-amigaos-gcc" -dumpversion)
[ "$gcc_dir" = "${expected_version%%.*}" ] || { echo "gcc -dumpversion $gcc_dir != major of BASE-VER $expected_version" >&2; exit 1; }

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
# SANA-II: the orchestrator's own copies (patches/NDK3.2), complete with the include of
# utility/tagitem.h (TAG_USER) and the AROS licence they refer to.
grep -q '^#include <utility/tagitem.h>' "$inc/devices/sana2.h" \
	|| { echo "devices/sana2.h is not the orchestrator's copy" >&2; exit 1; }

# Paths the consumer stacks rely on (toolchain.cmake and their CMake lists).  The LTO rows
# are load-bearing: the stacks build with -flto, and a binutils configured --disable-plugins
# (as older orchestrator pins did) still produces a working toolchain that fails only once a
# consumer puts an LTO object into a .a.  Assert the pieces here so that regression is caught
# in this build rather than in theirs.
missing=0
for f in \
	bin/m68k-amigaos-gcc bin/m68k-amigaos-g++ bin/m68k-amigaos-ld bin/m68k-amigaos-objdump bin/m68k-amigaos-strip \
	bin/sfdc bin/fd2sfd bin/fd2pragma bin/vasmm68k_mot bin/lha bin/flexcat \
	m68k-amigaos/lib/libamiga.a m68k-amigaos/lib/libdebug.a m68k-amigaos/lib/libc.a m68k-amigaos/lib/libm.a \
	m68k-amigaos/lib/libstubs.a m68k-amigaos/libnix/lib/libnix20.a m68k-amigaos/libnix/lib/libm020/libnix20.a \
	m68k-amigaos/libnix/lib/libm020/libm881/libm.a \
	m68k-amigaos/clib2/lib/libc.a m68k-amigaos/sys-include/stdio.h \
	m68k-amigaos/ndk-include/exec/types.h m68k-amigaos/ndk-include/libraries/keymap.h \
	m68k-amigaos/ndk-include/proto/exec.h m68k-amigaos/ndk-include/inline/exec.h \
	m68k-amigaos/ndk-include/inline/bsdsocket.h m68k-amigaos/ndk-include/sys/socket.h \
	m68k-amigaos/ndk-include/devices/sana2.h m68k-amigaos/ndk-include/devices/sana2specialstats.h \
	m68k-amigaos/ndk-include/devices/LICENSE.AROS-APL \
	m68k-amigaos/ndk-include/devices/newstyle.h m68k-amigaos/ndk/lib/sfd/exec_lib.sfd \
	m68k-amigaos/ndk/lib/sfd/bsdsocket_lib.sfd \
	m68k-amigaos/include/devices/ahi.h m68k-amigaos/include/libraries/ahi_sub.h m68k-amigaos/include/proto/ahi.h \
	m68k-amigaos/include/{proto,inline}/{devicetree,mailbox,cma,Picasso96}.h \
	m68k-amigaos/include/clib/{devicetree,mailbox,cma,Picasso96}_protos.h \
	m68k-amigaos/include/resources/cma.h m68k-amigaos/include/libraries/Picasso96.h \
	m68k-amigaos/lib/sfd/{devicetree,mailbox,cma,Picasso96API}_lib.sfd \
	lib/gcc/m68k-amigaos/$gcc_dir/libgcc.a etc/SOURCES \
	bin/m68k-amigaos-gcc-ar bin/m68k-amigaos-gcc-ranlib bin/m68k-amigaos-gcc-nm \
	libexec/gcc/m68k-amigaos/$gcc_dir/lto1 \
	libexec/gcc/m68k-amigaos/$gcc_dir/lto-wrapper \
	libexec/gcc/m68k-amigaos/$gcc_dir/liblto_plugin.so
do
	[ -e "$PREFIX/$f" ] || { echo "missing: $PREFIX/$f" >&2; missing=1; }
done
[ "$missing" = 0 ]
multilibs=$("$PREFIX/bin/m68k-amigaos-gcc" -print-multi-lib | wc -l)
[ "$multilibs" -ge 8 ] || { echo "only $multilibs multilibs configured" >&2; exit 1; }

# gcc installs the plugin under libexec/, where only the gcc-* wrappers look for it.  The
# symlink is the conventional location bare binutils probe, so ar/nm/ranlib/objdump can read
# LTO objects instead of reporting "plugin needed to handle lto object".
mkdir -p "$PREFIX/lib/bfd-plugins"
ln -sf "../../libexec/gcc/m68k-amigaos/$gcc_dir/liblto_plugin.so" \
	"$PREFIX/lib/bfd-plugins/liblto_plugin.so"

# ---- trim ---------------------------------------------------------------------------------
# Strip host executables only (never the m68k target archives under lib/ and lib/gcc/).
echo ">> stripping host binaries"
find "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/m68k-amigaos/bin" -type f -print0 \
	| while IFS= read -r -d '' f; do
		case $(file -b "$f") in ELF\ 64-bit*x86-64*) strip --strip-unneeded "$f" 2>/dev/null || true ;; esac
	done
rm -rf "$PREFIX/share/man" "$PREFIX/share/info" "$PREFIX/share/locale" \
	"$PREFIX/lib/gcc/m68k-amigaos/$gcc_dir/plugin/include" \
	"$PREFIX/lib/gcc/m68k-amigaos/$gcc_dir/install-tools"
# amiga-netinclude's files are committed with the executable bit; headers are not programs.
find "$inc" -type f -perm -u+x -exec chmod 644 {} +

echo ">> ready: $("$PREFIX/bin/m68k-amigaos-gcc" --version | head -1)"
du -sh "$PREFIX"
