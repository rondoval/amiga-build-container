#!/usr/bin/env python3
"""Toolchain stage, step 1 (the only step with network access).

Materialise every input listed in toolchain.lock.json under /src, so that the build step can
run with --network=none and so that nothing in the build can reach a branch head. Each input's
destination, and the facts the orchestrator's Makefile needs about it, come from its own row in
the lock; this script keeps no per-module tables of its own.

Layout produced (the `dest` of each row, relative to /src):
  /src/amiga-gcc/                 orchestrator (AmigaPorts/m68k-amigaos-gcc) at its pin
  /src/amiga-gcc/projects/<mod>/  every module at its pin (so `make` never clones)
  /src/amiga-gcc/download/        NDK3.2.lha, m68k-amigaos-ahidev.lha (so `make` never downloads)
  /src/lha, /src/flexcat          host tools, built by build-toolchain.sh
  /src/download/<MUI .lha>        extracted in the final stage
  /src/extra/devices/*.h          AROS SANA-II headers, installed by build-toolchain.sh
  /src/SOURCES                    "<name> <commit-or-sha256>" provenance, shipped as etc/SOURCES
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # before the lock import: keeps __pycache__ out of the image layer

import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
from datetime import datetime  # noqa: E402
from pathlib import Path  # noqa: E402

from lock import Lock, LockError, fetch_git, fetch_verified, run  # noqa: E402

SRC = Path(os.environ.get("SRC", "/src"))
LOCK = Path(os.environ.get("LOCK", SRC / "toolchain.lock.json"))

# Where a clone rule would have put a module's patches, relative to the orchestrator.
PATCH_DIR = "patches"


def apply_clone_side_effects(lock: Lock, orch: Path) -> None:
    """Do what the Makefile's clone rules do besides cloning.

    Pre-populating projects/<mod> stops those rules from running at all, so anything else they
    would have done has to happen here instead.
    """
    # gcc, binutils and fd2sfd: apply patches/<mod>/**/*.diff, where each diff's path under
    # patches/ mirrors the file it patches under projects/. (Empty upstream today.)
    for row in lock.git:
        if not row.patched:
            continue
        root = orch / PATCH_DIR / row.name
        if not root.is_dir():
            continue
        for diff in sorted(root.rglob("*.diff")):
            target = orch / "projects" / diff.relative_to(orch / PATCH_DIR).with_suffix("")
            print(f">> patch {target} < {diff}", flush=True)
            run(["patch", "-N", str(target), str(diff)])

    # libdebug: its clone rule backdates configure.ac so that configure is always newer and
    # autoreconf never re-runs. `touch -t 0001010000` is local midnight on 2000-01-01.
    stamp = datetime(2000, 1, 1).timestamp()
    configure_ac = SRC / lock.git_row("libdebug").dest / "configure.ac"
    os.utime(configure_ac, (stamp, stamp))


def check_markers(lock: Lock) -> None:
    """Every module must leave its marker file in place, or `make` would clone a branch head."""
    for row in lock.git:
        if row.marker and not (SRC / row.dest / row.marker).exists():
            raise LockError(
                f"marker {row.dest}/{row.marker} is missing: the Makefile would clone {row.name}"
            )


def check_ndk_pin(lock: Lock, orch: Path) -> None:
    """The Makefile pins the NDK archive too; if upstream re-pins it, our lock must follow."""
    found = re.search(r"^NDK_SHA256\s*:=\s*(\S+)", (orch / "Makefile").read_text(), re.M)
    if not found:
        raise LockError("the orchestrator Makefile no longer has an NDK_SHA256 line")
    want = lock.file_row("NDK3.2.lha").sha256
    if found.group(1) != want:
        raise LockError(f"Makefile NDK_SHA256 ({found.group(1)}) != lock NDK3.2.lha ({want})")


def pin_ahi_sdk(lock: Lock, orch: Path) -> None:
    """Make `make sdk=ahi` verify the pre-downloaded archive rather than trust a bare URL.

    The SDK installer honours a Sha256: line in the .sdk file and reuses an already downloaded,
    verified archive, which is what lets that target run offline.
    """
    sdk = orch / "sdk" / "ahi.sdk"
    text = sdk.read_text()
    if not re.search(r"^Sha256:", text, re.M):
        sdk.write_text(text + f"Sha256: {lock.file_row('m68k-amigaos-ahidev.lha').sha256}\n")


def poison_repos(orch: Path) -> None:
    """Leave .repos in place but with unroutable URLs.

    It is read only by the clone rules (which now find every marker in place) and by the
    update/branch targets (never run). Pointing every URL at a dead host means an unexpected
    clone fails loudly instead of quietly fetching an unpinned head.
    """
    text = (orch / "default-repos").read_text()
    (orch / ".repos").write_text(
        re.sub(r"https?://\S+", "https://invalid.invalid/pinned-by-toolchain.lock.json", text)
    )


def main() -> int:
    lock = Lock.load(LOCK)
    orch = SRC / lock.git_row("m68k-amigaos-gcc").dest
    provenance: list[tuple[str, str]] = []

    # ---- git rows: the orchestrator, its modules, and the host tools --------------------
    for row in lock.git:
        if row.dest is None:
            continue  # a pin-only row (aros): referenced by @aros@ URLs, never checked out
        fetch_git(row.url, row.pin, SRC / row.dest)
        provenance.append((row.name, row.pin))

    apply_clone_side_effects(lock, orch)
    check_markers(lock)

    # The Makefile reads gcc's version from this file at parse time, so it must be in place
    # before the build step runs make; record it for finish-toolchain.sh and the smoke test.
    gcc_version = (SRC / lock.git_row("gcc").dest / "gcc" / "BASE-VER").read_text().strip()
    print(f">> gcc BASE-VER: {gcc_version}", flush=True)
    provenance.append(("gcc-version", gcc_version))

    # No build rule reads the checkouts' git metadata (only `make log`/`make remotes`, which we
    # never run), and dropping it keeps the sources layer smaller.
    for row in lock.git:
        if row.dest:
            shutil.rmtree(SRC / row.dest / ".git", ignore_errors=True)

    # ---- file rows: archives and loose headers ------------------------------------------
    for row in lock.files:
        fetch_verified(lock.expand_url(row.url), row.sha256, SRC / row.dest)
        provenance.append((row.name, row.sha256))

    check_ndk_pin(lock, orch)
    pin_ahi_sdk(lock, orch)
    poison_repos(orch)

    (SRC / "SOURCES").write_text("".join(f"{name} {value}\n" for name, value in provenance))
    print(">> sources ready:", flush=True)
    print((SRC / "SOURCES").read_text(), end="", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LockError as exc:
        print(f"fetch-sources: {exc}", file=sys.stderr)
        sys.exit(1)
