#!/usr/bin/env python3
"""Toolchain stage, step 1 (the only step with network access).

Materialise every input listed in toolchain.lock.json under /src, so that the build step can
run with --network=none and so that nothing in the build can reach a branch head. Each input's
destination, and the facts the orchestrator's Makefile needs about it, come from its own row in
the lock; this script keeps no per-module tables of its own.

Layout produced (the `dest` of each row, relative to /src):
  /src/amiga-gcc/                 orchestrator (AmigaPorts/m68k-amigaos-gcc) at its pin
  /src/amiga-gcc/projects/<mod>/  every module at its pin, lha included (so `make` never clones)
  /src/amiga-gcc/download/        NDK3.2.lha, the SDK archives (AHI, P96), the gmp/mpfr/mpc
                                  tarballs gcc and binutils are built with (so `make` never
                                  downloads)
  /src/flexcat                    host tool, built by build-toolchain.sh
  /src/download/<MUI .lha>        extracted in the final stage
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

from lock import Lock, LockError, fetch_git, fetch_verified  # noqa: E402

SRC = Path(os.environ.get("SRC", "/src"))
LOCK = Path(os.environ.get("LOCK", SRC / "toolchain.lock.json"))


def apply_clone_side_effects(lock: Lock) -> None:
    """Do what the Makefile's clone rules do besides cloning.

    Pre-populating projects/<mod> stops those rules from running at all, so anything else they
    would have done has to happen here instead. The only one left is libdebug's:
    """
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


def check_archive_pins(lock: Lock, orch: Path) -> None:
    """The orchestrator pins some of these archives too; if upstream re-pins one, our lock must follow.

    Its default-archives lists each as `name file sha256 url...`, and the Makefile's download
    rule for download/<file> is satisfied by a pre-downloaded file that verifies against that
    sha256, which is what lets the build step run offline. A new NDK or a newer gmp would
    change the file or the checksum, so the build would reach for the network and fail deep
    into the toolchain instead; fail here, where the fix is one lock row.
    """
    entries = {}
    for line in (orch / "default-archives").read_text().splitlines():
        fields = line.split()
        if fields and not fields[0].startswith("#"):
            entries[fields[0]] = fields
    download = Path(lock.git_row("m68k-amigaos-gcc").dest) / "download"
    for row in lock.files:
        if not row.archive:
            continue
        if row.archive not in entries or len(entries[row.archive]) < 3:
            raise LockError(f"the orchestrator's default-archives no longer lists {row.archive}")
        _, file, sha256 = entries[row.archive][:3]
        if Path(row.dest) != download / file:
            raise LockError(f"default-archives {row.archive} is {download / file}, lock {row.name} goes to {row.dest}")
        if sha256.lower() != row.sha256:
            raise LockError(f"default-archives {row.archive} ({sha256}) != lock {row.name} ({row.sha256})")


def check_sdk_pins(lock: Lock, orch: Path) -> None:
    """Each SDK's .sdk descriptor pins its archive as well; if upstream re-pins one, follow.

    `make sdk=<sdk>` hands the descriptor's checksum to scripts/sdk-download for download/<basename of
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
    # A pin-only row (the Emu68 resources) is never checked out; only the files its @name@
    # URLs name are fetched, but its pin is still what they were taken from.
    for row in lock.git:
        if row.dest is not None:
            fetch_git(row.url, row.pin, SRC / row.dest)
        provenance.append((row.name, row.pin))

    apply_clone_side_effects(lock)
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

    check_archive_pins(lock, orch)
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
