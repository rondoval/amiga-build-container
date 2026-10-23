#!/usr/bin/env python3
"""Toolchain stage, step 1 (the only step with network access).

Materialise every input listed in toolchain.lock.json under /src, so that the build step can
run with --network=none and so that nothing in the build can reach a branch head. Each input's
destination, and the facts the orchestrator's Makefile needs about it, come from its own row in
the lock; this script keeps no per-module tables of its own.

Layout produced (the `dest` of each row, relative to /src):
  /src/amiga-gcc/                 orchestrator (AmigaPorts/m68k-amigaos-gcc) at its pin
  /src/amiga-gcc/projects/<mod>/  every module at its pin (so `make` never clones)
  /src/amiga-gcc/download/        NDK3.2.lha, the SDK archives (AHI, P96), the gmp/mpfr/mpc
                                  tarballs gcc and binutils are built with (so `make` never
                                  downloads)
  /src/lha, /src/flexcat          host tools, built by build-toolchain.sh
  /src/download/<MUI .lha>        extracted in the final stage
  /src/extra/devices/*.h          AROS SANA-II headers, installed by build-toolchain.sh
  /src/extra/sfd/*.sfd            SFD-only interfaces (the Emu68 resources); build-toolchain.sh
                                  generates their headers
  /src/extra/include/             headers installed as they are under m68k-amigaos/include/
  /src/SDKS                       the orchestrator SDKs to install, one per line (rows with `sdk`)
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


def check_makefile_pins(lock: Lock, orch: Path) -> None:
    """The Makefile pins some of these archives too; if upstream re-pins one, our lock must follow.

    Its download rules are satisfied by a file already sitting in download/ under the name the
    pinned version spells, which is what lets the build step run offline. A new NDK or a newer
    gmp would rename that file, so the build would reach for the network and fail deep into the
    toolchain instead; fail here, where the fix is one lock row.
    """
    makefile = (orch / "Makefile").read_text()
    for row in lock.files:
        if not row.makefile_pin:
            continue
        # Every assignment, not the first: the Makefile sets NDK_SHA256 once per NDK it can
        # build against (3.2 and 3.9), and which branch comes first is not ours to rely on.
        # [ \t]* and not \s*: an empty assignment must not match across the line break and
        # capture the next line's variable name.
        found = re.findall(rf"^{re.escape(row.makefile_pin)}[ \t]*:=[ \t]*(\S+)", makefile, re.M)
        if not found:
            raise LockError(f"the orchestrator Makefile no longer sets {row.makefile_pin}")
        if row.sha256 not in found:
            raise LockError(
                f"Makefile {row.makefile_pin} ({', '.join(found)}) != lock {row.name} ({row.sha256})"
            )


def check_sdk_pins(lock: Lock, orch: Path) -> None:
    """Each SDK's .sdk descriptor pins its archive as well; if upstream re-pins one, follow.

    `make sdk=<sdk>` hands the descriptor's checksum to sdk/download for download/<basename of
    its Url>, which leaves an archive that verifies alone and otherwise discards it and reaches
    for the network the build step does not have. So both the name and the checksum must agree.
    """
    for row in lock.files:
        if not row.sdk:
            continue
        descriptor = f"sdk/{row.sdk}.sdk"
        text = (orch / descriptor).read_text()
        url = re.search(r"^Url:[ \t]*(\S+)", text, re.M)
        sha = re.search(r"^Sha256:[ \t]*(\S+)", text, re.M)
        if not url or not sha:
            raise LockError(f"{descriptor} no longer carries a Url and a Sha256")
        expected_dest = Path(lock.git_row("m68k-amigaos-gcc").dest) / "download" / Path(url.group(1)).name
        if Path(row.dest) != expected_dest:
            raise LockError(f"{descriptor} downloads {expected_dest}, lock {row.name} goes to {row.dest}")
        if sha.group(1).lower() != row.sha256:
            raise LockError(f"{descriptor} Sha256 ({sha.group(1)}) != lock {row.name} ({row.sha256})")


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
    # A pin-only row (aros, the Emu68 resources) is never checked out; only the files its @name@
    # URLs name are fetched, but its pin is still what they were taken from.
    for row in lock.git:
        if row.dest is not None:
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

    check_makefile_pins(lock, orch)
    check_sdk_pins(lock, orch)
    poison_repos(orch)

    (SRC / "SDKS").write_text("".join(f"{row.sdk}\n" for row in lock.files if row.sdk))
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
