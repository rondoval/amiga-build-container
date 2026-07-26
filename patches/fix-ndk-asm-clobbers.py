#!/usr/bin/env python3
"""
Fix fd2pragma-generated NDK inline headers (currently just inline/bsdsocket.h,
the Roadshow TCP/IP stack's hand-written asm stubs) for GCC's stricter
asm-clobber checking.

Starting around GCC 9, GCC hard-errors when a register-pinned local variable
used as an asm INPUT operand also appears (by register name) in that same asm
statement's clobber list:

    error: 'asm' specifier for variable '__ReleaseInterfaceList_list'
    conflicts with 'asm' clobber list

GCC 6.5 (this image's default base) tolerated the redundancy; GCC 13+ doesn't.
Most of the NDK avoids this via a shared macro (LPx, in inline/macros.h) that
declares scratch registers as dummy "=r" *output* operands instead of bare
clobbers. bsdsocket.h predates/bypasses that convention for its "no return
value" calls (e.g. ReleaseInterfaceList, BeginInterfaceConfig, setnetent) and
lists every scratch register as a bare clobber, including whichever register
the same statement is already using as a real input operand.

Fix: within each #define macro block, find "register TYPE NAME __asm("REG")
= ...;" declarations (the "=" initializer marks it as an input-bound
variable, as opposed to a bare "register TYPE NAME __asm("REG");" dummy
declaration with no initializer). Then, in every asm clobber list within
that same block, drop any register literal that matches one of those
input-bound registers -- it's already implicitly clobbered by virtue of
being consumed as input, so listing it again is both redundant and (per
GCC 9+) illegal. This is a pure text transform: it never changes codegen
on any GCC version, since a plain "r" input operand's register was never
assumed to survive the asm statement regardless of whether it's also
named in the clobber list.
"""
import re
import sys

REGISTER_DECL_RE = re.compile(
    r'register\s+[^;]*?__asm\(\s*"([a-z][a-z0-9]*)"\s*\)\s*=\s*[^;]*;'
)
CLOBBER_LIST_RE = re.compile(r':\s*((?:"[a-z0-9]+"\s*,?\s*)+)\)\s*;')


def fix_block(block):
    input_regs = set(REGISTER_DECL_RE.findall(block))
    if not input_regs:
        return block, 0

    removed = 0

    def repl(m):
        nonlocal removed
        items = re.findall(r'"([a-z0-9]+)"', m.group(1))
        kept = [r for r in items if r not in input_regs]
        removed += len(items) - len(kept)
        joined = ', '.join(f'"{r}"' for r in kept)
        return f': {joined});'

    fixed = CLOBBER_LIST_RE.sub(repl, block)
    return fixed, removed


def fix_file(path):
    with open(path, 'r', encoding='utf-8', errors='surrogateescape') as f:
        text = f.read()

    # Split into chunks, each starting at a top-level "#define" line, so
    # register declarations are only matched against clobber lists in the
    # same macro (never leak across macros).
    parts = re.split(r'(?m)(?=^#define\s)', text)

    total_removed = 0
    out_parts = []
    for part in parts:
        fixed, removed = fix_block(part)
        total_removed += removed
        out_parts.append(fixed)

    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(''.join(out_parts))

    print(f"{path}: removed {total_removed} conflicting clobber(s)", file=sys.stderr)
    return total_removed


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <header> [header...]", file=sys.stderr)
        sys.exit(2)

    total = sum(fix_file(path) for path in sys.argv[1:])
    if total == 0:
        print("warning: no conflicting clobbers found -- header may have "
              "changed upstream, double check the patch is still needed",
              file=sys.stderr)


if __name__ == '__main__':
    main()
