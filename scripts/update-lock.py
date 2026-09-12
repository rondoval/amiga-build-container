#!/usr/bin/env python3
"""Move the pins in toolchain.lock.json to the branch heads the lock follows.

    scripts/update-lock.py                 every git row -> the head of its `ref` branch
    scripts/update-lock.py --files         ...and re-download + re-hash every file row
    scripts/update-lock.py gcc lha         only these rows

The lock is rewritten in place and the change printed as a diff; review it and commit. This is
the only thing that moves a pin: the image build never follows a branch.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # before the lock import, so no __pycache__ appears in scripts/

import argparse  # noqa: E402
import difflib  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
from pathlib import Path  # noqa: E402

from lock import Lock, LockError, curl, sha256_of  # noqa: E402

DEFAULT_LOCK = Path(__file__).resolve().parent.parent / "toolchain.lock.json"


def branch_head(url: str, ref: str) -> str:
    """The commit a branch currently points at, without cloning anything."""
    proc = subprocess.run(
        ["git", "ls-remote", "-q", url, f"refs/heads/{ref}"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise LockError(f"git ls-remote {url}: {proc.stderr.strip()}")
    head = proc.stdout.split("\t")[0].strip()
    if not head:
        raise LockError(f"{url}: no branch named {ref}")
    return head


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("names", nargs="*", metavar="NAME", help="only these rows (default: all)")
    parser.add_argument(
        "--files", action="store_true", help="also re-download and re-hash the file rows"
    )
    parser.add_argument(
        "--lock", type=Path, default=DEFAULT_LOCK, help="lock file to update (default: this repo's)"
    )
    args = parser.parse_args(argv)

    lock = Lock.load(args.lock)
    before = lock.dumps()

    known = {row.name for row in (*lock.git, *lock.files)}
    for name in args.names:
        if name not in known:
            raise LockError(f"no row named {name} in {args.lock.name}")

    def wanted(name: str) -> bool:
        return not args.names or name in args.names

    for row in lock.git:
        if not wanted(row.name):
            continue
        head = branch_head(row.url, row.ref)
        if head != row.pin:
            print(f">> {row.name}: {row.ref} {row.pin} -> {head}")
            lock.set_pin(row.name, head)

    if args.files:
        with tempfile.TemporaryDirectory() as tmpdir:
            for row in lock.files:
                if not wanted(row.name):
                    continue
                # expanded against the pins as just moved, so an @aros@ URL follows the bump
                url = lock.expand_url(row.url)
                print(f">> {row.name} <- {url}")
                downloaded = Path(tmpdir) / row.name
                if not curl(url, downloaded):
                    raise LockError(f"could not download {url}")
                digest = sha256_of(downloaded)
                if digest != row.sha256:
                    print(f"   sha256 {row.sha256} -> {digest}")
                    lock.set_sha256(row.name, digest)

    after = lock.dumps()
    if after == before:
        print(f"{args.lock.name} is up to date")
        return 0

    sys.stdout.writelines(
        difflib.unified_diff(
            before.splitlines(keepends=True),
            after.splitlines(keepends=True),
            fromfile=f"a/{args.lock.name}",
            tofile=f"b/{args.lock.name}",
        )
    )
    args.lock.write_text(after)
    print(f"{args.lock.name} updated; review and commit")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LockError as exc:
        print(f"update-lock: {exc}", file=sys.stderr)
        sys.exit(1)
