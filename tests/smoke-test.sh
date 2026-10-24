#!/bin/bash
# In-image smoke test. Runs as an unprivileged uid with HOME=/tmp (the way the consumer
# wrappers run the image) in the Dockerfile's `test` stage, or by hand:
#
#   docker run --rm -u 1000:1000 -e HOME=/tmp -v "$PWD/tests:/tests:ro" <image> /tests/smoke-test.sh
#
# It checks what the consumer stacks rely on, not everything the toolchain can do: compiler
# identity, the two register-argument traps, every -mcrt/CPU link mode the stacks use, the
# freestanding device link recipe, the headers they include, and the host tools they call.
set -u

PREFIX=${PREFIX:-/opt/amiga}
T=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT
cd "$T"

fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
# check <description> <command...>: passes when the command exits 0 (output shown on failure)
check() {
	local desc=$1 out; shift
	if out=$("$@" 2>&1); then pass "$desc"; else fail "$desc"; printf '%s\n' "$out" | sed 's/^/      /' >&2; fi
}
CC=$PREFIX/bin/m68k-amigaos-gcc
hunk_magic() { [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = "000003f3" ]; }

# ---- identity -------------------------------------------------------------------------------
expected=$(awk '$1 == "gcc-version" { print $2 }' "$PREFIX/etc/SOURCES" 2>/dev/null)
actual=$("$CC" -dumpfullversion 2>/dev/null)
if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
	pass "gcc is $actual (matches etc/SOURCES)"
else
	fail "gcc version '$actual' != etc/SOURCES '$expected'"
fi
check "/opt/m68k-amigaos alias resolves to the same gcc" test "$(readlink -f /opt/m68k-amigaos/bin/m68k-amigaos-gcc)" = "$(readlink -f "$CC")"
check "toolchain bin on PATH" test "$(command -v m68k-amigaos-gcc)" = "$CC"
check "\$HOME is writable" touch "$HOME/.smoke-probe"
check "-print-multi-lib lists >= 8 multilibs" test "$("$CC" -print-multi-lib | wc -l)" -ge 8

# ---- multilib selection ---------------------------------------------------------------------
# Which libgcc, libnix, libdebug and libpthread a stack links is decided by MULTILIB_MATCHES.
# One 020 multilib, built with -m68020-60, serves every 020-class CPU (there is no 060 one any
# more), and -mhard-float selects its 68881 variant like -m68881 does. Before, -m68030, -m68040
# and the -march= spellings fell through to the 68000 libraries, and later -mhard-float alone
# still got the soft-float ones, so the -m68040 -mhard-float stacks linked soft-float library
# code. The spellings checked here are the ones the consumers offer (M68K_CPU, M68K_FPU),
# -m68040 -mhard-float being their default.
multi_dir_is() {
	local want=$1 got; shift
	got=$("$CC" -print-multi-directory "$@") || return 1
	[ "$got" = "$want" ] || { echo "-print-multi-directory $*: '$got', want '$want'"; return 1; }
}
for cpu in 68020 68030 68040 68060; do
	check "-m$cpu -msoft-float links the 020 multilib" multi_dir_is libm020 -m$cpu -msoft-float
	check "-m$cpu -mhard-float links the 020 68881 multilib" multi_dir_is libm020/libm881 -m$cpu -mhard-float
done
check "-m68040 -m68881 links the 020 68881 multilib" multi_dir_is libm020/libm881 -m68040 -m68881
check "-m68000 links the root multilib" multi_dir_is . -m68000 -msoft-float
check "-m68040 -fbaserel links the baserel 020 multilib" multi_dir_is libb/libm020 -m68040 -fbaserel
check "-m68040 -mhard-float -fbaserel links the baserel 020 68881 multilib" \
	multi_dir_is libb/libm020/libm881 -m68040 -mhard-float -fbaserel

# ---- register-argument traps ----------------------------------------------------------------
# The AmigaOS ABI passes arguments in named registers, via asm("a1") on the parameter. Two ways
# m68k-amigaos-gcc 16.1.1b silently broke that, both fixed in the AmigaPorts amiga16.2 branch:
#   1. the annotation was dropped when the prototype saw the parameter's struct as incomplete,
#      reading the argument off the stack while every caller still passed it in a1;
#   2. a definition that does not repeat the prototype's asm() was accepted instead of rejected.
cat > regarg.c <<'EOF'
struct Bad;                                    /* completed BETWEEN prototype and definition */
long bad(struct Bad *m asm("a1"));
struct Bad { unsigned short id; char *str; };
long bad(struct Bad *m asm("a1")) { return (long)m->str; }
struct Good { unsigned short id; char *str; };  /* control: complete before the prototype */
long good(struct Good *m asm("a1"));
long good(struct Good *m asm("a1")) { return (long)m->str; }
EOF
cat > regarg-dropped.c <<'EOF'
struct Map { unsigned short id; char *str; };
long hook(struct Map *m asm("a1"));
long hook(struct Map *m) { return (long)m->str; }   /* asm() not repeated: must not compile */
EOF

# _<fn>'s instructions, up to its rts, must read through a1 and never touch the stack.
# ($1 == "rts", not /\<rts\>/: the image's mawk has no \< \> and the body ran into the next
# function, so a fault in one was reported against the other.)
regarg_uses_a1() {
	local body
	body=$(awk -v fn="_$1" '$0 == fn ":" { f = 1; next } f && $1 == "rts" { exit } f' regarg.s)
	[ -n "$body" ] || { echo "no _$1 in regarg.s"; return 1; }
	grep -q 'a1' <<<"$body" && ! grep -q '(sp)' <<<"$body" || { printf '%s\n' "$body"; return 1; }
}
for flags in "-O2" "-O2 -m68040 -mhard-float -fomit-frame-pointer -mcrt=nix20 -ffreestanding"; do
	if out=$("$CC" $flags -Wall -Wextra -S regarg.c -o regarg.s 2>&1); then
		for fn in bad good; do check "regarg trap 1: $fn keeps a1 ($flags)" regarg_uses_a1 "$fn"; done
	else
		fail "regarg trap 1: compile failed ($flags)"; printf '%s\n' "$out" | sed 's/^/      /' >&2
	fi
done
regarg_rejects_dropped_asm() {
	local out
	out=$("$CC" -O2 -c regarg-dropped.c -o /dev/null 2>&1) \
		&& { echo "compiled, but must be rejected as 'conflicting types'"; return 1; }
	grep -q "conflicting types" <<<"$out" || { printf '%s\n' "$out"; return 1; }
}
check "regarg trap 2: dropped annotation is rejected with 'conflicting types'" regarg_rejects_dropped_asm

# ---- hosted link modes ----------------------------------------------------------------------
cat > hello.c <<'EOF'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) { (void)argv; printf("hello %d %zu\n", argc, strlen("x")); return 0; }
EOF
# called unquoted (link_hello $mode) so a multi-word mode splits into arguments and an empty one
# contributes none, which is the <newlib default> case
link_hello() {
	"$CC" -O2 -Wall hello.c -o hello.exe "$@" || return 1
	hunk_magic hello.exe || { echo "linked, but the result is not a HUNK executable"; return 1; }
}
for mode in \
	"-mcrt=nix20" "-mcrt=nix13" "-mcrt=clib2" "-noixemul" "" \
	"-mcrt=nix20 -m68020 -msoft-float" "-mcrt=nix20 -m68040 -mhard-float" "-mcrt=nix20 -m68060 -mhard-float" \
	"-mcrt=nix20 -m68000 -msoft-float" "-mcrt=nix20 -lm"
do
	check "link hello world: ${mode:-<newlib default>}" link_hello $mode
done
cat > hello.cpp <<'EOF'
struct S { virtual ~S() {} virtual int v() { return 1; } };
int f() { S s; return s.v(); }
EOF
check "g++ compiles C++" "$PREFIX/bin/m68k-amigaos-g++" -O2 -c hello.cpp -o hello.o

# ---- freestanding device/library link recipe -----
cat > dev.c <<'EOF'
#include <exec/types.h>
#include <exec/lists.h>
#include <exec/ports.h>
#include <proto/exec.h>
#include <clib/alib_protos.h>
#include <clib/debug_protos.h>
#include <string.h>
struct ExecBase *SysBase;
LONG doNotExecute(void) { return -1; }
void work(void) {
    struct MsgPort *mp = CreatePort(NULL, 0);        /* libamiga.a */
    KPutStr((CONST_STRPTR)"smoke\n");               /* libdebug.a */
    if (mp) DeletePort(mp);
    KPrintF((CONST_STRPTR)"%ld\n", (LONG)strlen("abc"));  /* libnix libc: strlen */
}
EOF
build_device() {
	"$CC" -O2 -m68040 -mhard-float -fomit-frame-pointer -mcrt=nix20 -ffreestanding \
		-Wall -c dev.c -o dev.o || return 1
	"$CC" -mcrt=nix20 -nostdlib -nostartfiles -s -Wl,-e,_doNotExecute dev.o -o dev.device \
		-Wl,--start-group -lc -lamiga -ldebug -lgcc -Wl,--end-group || return 1
	hunk_magic dev.device || { echo "linked, but the result is not a HUNK executable"; return 1; }
}
check "freestanding link with -lc -lamiga -ldebug -lgcc" build_device

# ---- LTO --------------------------------------------------------------------------------------
# The consumer stacks build with -flto, which needs binutils configured WITH plugin support. A gcc
# whose binutils was built --disable-plugins still links loose LTO objects (collect2 falls back to
# lto-wrapper) and fails only once an LTO object sits inside a .a -- i.e. every CMake static
# library. So the archive is what gets checked here, with CMake's exact ar/ranlib sequence, and the
# assertion is that the cross-TU call was constant-folded, not merely resolved: 20 + 22 collapses to
# a single moveq #42 iff the plugin really handed the IR to GCC.
cat > lto_lib.c <<'EOF'
int lto_answer(void);
int lto_answer(void) { return 20; }
EOF
cat > lto_main.c <<'EOF'
int lto_answer(void);
int doNotExecute(void);
/* __attribute__((used)) is load-bearing, exactly as in the stacks' device.c: -Wl,-e is NOT an
 * LTO root, so without it the plugin discards the whole module and the link still "succeeds",
 * emitting a 20-byte HUNK header with no hunks. */
int __attribute__((used)) doNotExecute(void) { return lto_answer() + 22; }
EOF
LTO_CFLAGS="-O2 -m68040 -mhard-float -fomit-frame-pointer -mcrt=nix20 -ffreestanding -flto"
build_lto() {
	"$CC" $LTO_CFLAGS -c lto_lib.c -o lto_lib.o || return 1
	"$CC" $LTO_CFLAGS -c lto_main.c -o lto_main.o || return 1
	m68k-amigaos-ar qc libltotest.a lto_lib.o || return 1   # what CMake's archive rule runs
	m68k-amigaos-ranlib libltotest.a || return 1
	"$CC" $LTO_CFLAGS -nostdlib -nostartfiles -s -Wl,-e,_doNotExecute \
		lto_main.o -L. -lltotest -o lto.device || return 1
	hunk_magic lto.device || { echo "linked, but the result is not a HUNK executable"; return 1; }
	# hunk_magic alone is not enough: a module the plugin dropped entirely is still a valid
	# (empty) HUNK header, so require real code.  20 + 22 folds to one moveq #42 iff the IR
	# actually reached GCC; an un-inlined build shows jsr + moveq #22 + moveq #20 instead.
	if ! m68k-amigaos-objdump -d --no-show-raw-insn lto.device 2>&1 | grep -q '#42'; then
		echo "linked, but the cross-TU call was not constant-folded -- LTO did not happen:"
		m68k-amigaos-objdump -dh lto.device 2>&1
		return 1
	fi
}
check "LTO through a static archive, cross-TU call constant-folded" build_lto
check "ld has real plugin support (not --disable-plugins)" bash -c \
	"m68k-amigaos-ld --help | grep -q -- '-plugin PLUGIN' && ! m68k-amigaos-ld --help | grep -q 'plugin.*(ignored)'"
check "ar accepts --plugin" bash -c "m68k-amigaos-ar --help | grep -q -- '--plugin'"
check "gcc-ar archives an LTO object" m68k-amigaos-gcc-ar rc libgccar.a lto_lib.o
check "bare nm reads LTO objects (lib/bfd-plugins symlink)" bash -c \
	"m68k-amigaos-nm lto_lib.o | grep -q lto_answer"

# ---- headers the stacks include ----------------------------------------------------------------
cat > headers.c <<'EOF'
#include <exec/types.h>
#include <exec/execbase.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/utility.h>
#include <proto/intuition.h>
#include <proto/keymap.h>
#include <proto/cardres.h>    /* libname (card.resource) != sfd name: NDK proto + --protoname inline */
#include <inline/cardres.h>
#include <proto/wb.h>         /* libname workbench.library != sfd name wb */
#include <libraries/keymap.h>
#include <devices/trackdisk.h>
#include <devices/scsidisk.h>
#include <devices/newstyle.h>
#include <devices/timer.h>
#include <devices/input.h>
#include <devices/sana2.h>
#include <devices/sana2specialstats.h>
#include <libraries/bsdsocket.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <proto/bsdsocket.h>
#include <devices/ahi.h>
#include <libraries/ahi_sub.h>
#include <proto/ahi.h>
#include <proto/graphics.h>   /* P96's clib header uses struct RastPort without declaring it */
#include <proto/Picasso96.h>  /* P96's own proto/inline headers, as sdk/p96.sdk installs them */
#include <libraries/Picasso96.h>
#include <proto/devicetree.h> /* the Emu68 resources: headers generated from their upstream SFDs */
#include <proto/mailbox.h>
#include <resources/cma.h>
#include <proto/cma.h>
#include <libraries/mui.h>
#include <string.h>
#include <stdint.h>
struct Library *SocketBase;
struct ExecBase *SysBase;
struct Library *P96Base;
APTR DeviceTreeBase, MailboxBase, CMABase;
/* one call through each of the four bases (P96's LPn macros, sfdc's inline stubs) */
struct BitMap *use_p96(void) { return p96AllocBitMap(640, 480, 32, BMF_USERPRIVATE, NULL, RGBFB_A8R8G8B8); }
CONST_STRPTR use_dt(void) { return DT_GetKeyName(DT_OpenKey((CONST_STRPTR)"/emu68")); }
ULONG use_mailbox(void) { return MB_GetClockRate(4); }
APTR use_cma(void) { return CMA_AllocAligned(65536, 4096); }
/* a "no return value" bsdsocket inline (the hand-written Roadshow header failed here on GCC >= 9) */
void use_inline(struct List *l) { ReleaseInterfaceList(l); }
/* a bsdsocket varargs wrapper (the hand-written header needed a typedef sfdc 1.13 stopped emitting) */
LONG use_varargs(void) { return QueryInterfaceTags((STRPTR)"eth0", TAG_END); }
struct NSDeviceQueryResult q = { 0, sizeof(struct NSDeviceQueryResult), NSDEVTYPE_SANA2, 0, NULL };
EOF
check "NDK 3.2 + netinclude + SANA-II + AHI + P96 + Emu68 resource + MUI headers compile (-I\$MUI_INCLUDE_DIR)" \
	"$CC" -O2 -m68040 -mhard-float -mcrt=nix20 -Wall -Wextra -Werror -I"${MUI_INCLUDE_DIR:?MUI_INCLUDE_DIR unset}" -c headers.c -o headers.o
# ---- fixed addresses ----------------------------------------------------------------------------
# The stacks read SysBase from address 4 (also through EXEC_BASE_NAME in the inline headers) and
# MMIO from fixed addresses. -Warray-bounds used to take such a read for a null-pointer access
# ("source object is likely at address zero"), so the consumers carried -Wno-array-bounds; since
# amiga16.2 0edaa6190 m68k-amigaos defaults to --param=min-pagesize=0 and needs no switch.
cat > absaddr.c <<'EOF'
#define __NOLIBBASE__
#define EXEC_BASE_NAME (*(struct ExecBase **)4)
#include <exec/execbase.h>
#include <proto/exec.h>
APTR use_abs_base(void) { return AllocMem(16, MEMF_PUBLIC); }
UWORD sysbase_version(void) { return (*(struct ExecBase **)4)->LibNode.lib_Version; }
ULONG read_mmio(void) { return *(volatile ULONG *)0xf2003004; }
EOF
check "fixed-address reads (SysBase at 4, MMIO) compile with -Warray-bounds on" \
	"$CC" -O2 -m68040 -mhard-float -mcrt=nix20 -Wall -Wextra -Werror -c absaddr.c -o absaddr.o
check "SANA2_INCLUDE_DIR points at devices/sana2.h" test -f "${SANA2_INCLUDE_DIR:?SANA2_INCLUDE_DIR unset}/devices/sana2.h"
check "MUI SDK has the explicit-base inline path" test -f "$MUI_INCLUDE_DIR/inline/muimaster.h" -a -f "$MUI_INCLUDE_DIR/defines/muimaster.h"
check "libraries/keymap.h (NDK 3.2 addition)" test -f "$PREFIX/m68k-amigaos/ndk-include/libraries/keymap.h"
check "provenance manifest present" test -s "$PREFIX/etc/SOURCES" -a -s "$PREFIX/etc/toolchain.lock.json"

# ---- host tools the stacks call ----------------------------------------------------------------
check "sfdc generates proto/exec.h from the NDK sfd" \
	bash -c "sfdc --target=m68k-amigaos --mode=proto --output=$T/exec_proto.h '$PREFIX/m68k-amigaos/ndk/lib/sfd/exec_lib.sfd' && grep -q PROTO_EXEC_H $T/exec_proto.h"
check "fd2sfd present" test -x "$PREFIX/bin/fd2sfd"
check "fd2pragma present" test -x "$PREFIX/bin/fd2pragma"
check "flexcat present" bash -c "command -v flexcat >/dev/null && (flexcat >/dev/null 2>&1; [ \$? -ne 127 ])"
check "vasm present" test -x "$PREFIX/bin/vasmm68k_mot"
mkdir -p cat/français && echo catalog > cat/français/x.catalog
check "lha archives UTF-8 names as latin-1 (neptune Packaging.cmake flags)" \
	bash -c "lha aq2 --system-kanji-code=utf8 --archive-kanji-code=latin1 $T/t.lha cat && lha t $T/t.lha"
cmv=$(cmake --version | awk 'NR==1 { print $3 }')
check "cmake >= 3.30 (have $cmv)" bash -c "printf '%s\n3.30\n' '$cmv' | sort -V | head -1 | grep -qx 3.30"
for tool in xxd git make python3 perl; do check "$tool present" command -v "$tool"; done
check "perl modules for sfdc" perl -e 'use Getopt::Long; use IO::Handle;'
check "m68k-amigaos-objdump disassembles" bash -c "m68k-amigaos-objdump -d --no-show-raw-insn dev.o | grep -q rts"
check "m68k-amigaos-strip works" m68k-amigaos-strip dev.device
missing=$(for f in "$PREFIX"/bin/* "$PREFIX"/libexec/gcc/m68k-amigaos/*/*; do [ -f "$f" ] && ldd "$f" 2>/dev/null | grep 'not found' | sed "s|^|$f: |"; done)
if [ -z "$missing" ]; then
	pass "no missing shared libraries under bin/ and libexec/"
else
	fail "missing shared libraries"; printf '%s\n' "$missing" >&2
fi

echo
if [ "$fails" = 0 ]; then echo "smoke test: all checks passed"; else echo "smoke test: $fails check(s) FAILED" >&2; exit 1; fi
