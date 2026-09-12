"""Reading, validating and fetching the inputs listed in toolchain.lock.json.

Imported by fetch-sources.py (inside the image) and update-lock.py (on the host); both sit
next to this file, which is what puts it on sys.path. Nothing else parses the lock.

The lock is a JSON object with two arrays of input rows, one row per thing the image is built
from. Every row carries everything about that input, so no caller keeps its own table of
per-module facts. See toolchain.lock.json, and the field notes on the dataclasses below.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

HEX40 = re.compile(r"\A[0-9a-f]{40}\Z")
HEX64 = re.compile(r"\A[0-9a-f]{64}\Z")
PLACEHOLDER = re.compile(r"@([A-Za-z0-9_.-]+)@")

AMINET = re.compile(r"\Ahttps?://(www\.)?aminet\.net")
AMINET_MIRROR = os.environ.get("AMINET_MIRROR", "http://nl.aminet.net")


class LockError(Exception):
    """The lock is malformed, or an input could not be obtained as pinned."""


@dataclass(frozen=True)
class GitRow:
    """A git repository, built at exactly `pin`.

    dest    where fetch-sources.py puts it, relative to /src. Absent means the row is never
            fetched and exists only so its pin can be referenced (see expand_url).
    marker  the file whose presence stops the orchestrator's Makefile from cloning this
            module itself (its clone rules are guarded by a marker file). Absent for the
            orchestrator and for host tools, which no Makefile rule clones.
    patched the Makefile's clone rule for this module also applies patches/<name>/*.diff,
            so fetch-sources.py has to do the same after checking it out.
    """

    name: str
    url: str
    ref: str
    pin: str
    dest: str | None = None
    marker: str | None = None
    patched: bool = False
    note: str | None = None


@dataclass(frozen=True)
class FileRow:
    """A single downloaded file, verified against `sha256`.

    url may contain an @<git row name>@ placeholder, replaced by that row's pin.
    dest is relative to /src.
    """

    name: str
    url: str
    sha256: str
    dest: str
    note: str | None = None


def _row(cls, obj, where):
    """Build a row dataclass from a JSON object, rejecting unknown and missing keys."""
    if not isinstance(obj, dict):
        raise LockError(f"{where}: expected an object, got {type(obj).__name__}")
    fields = {f.name: f for f in dataclasses.fields(cls)}
    unknown = sorted(set(obj) - set(fields))
    if unknown:
        raise LockError(f"{where}: unknown key(s) {', '.join(unknown)}")
    missing = sorted(
        n for n, f in fields.items() if f.default is dataclasses.MISSING and n not in obj
    )
    if missing:
        raise LockError(f"{where}: missing key(s) {', '.join(missing)}")
    for name, value in obj.items():
        expected = bool if isinstance(fields[name].default, bool) else str
        if value is not None and not isinstance(value, expected):
            raise LockError(f"{where}: {name} must be {expected.__name__}")
    return cls(**obj)


class Lock:
    """The parsed lock file. Rows keep the order they have in the file."""

    def __init__(self, version: int, git: list[GitRow], files: list[FileRow], note: str | None = None):
        self.version = version
        self.note = note
        self.git = git
        self.files = files

    # ---- loading ---------------------------------------------------------------------
    @classmethod
    def load(cls, path: Path | str) -> "Lock":
        path = Path(path)
        try:
            doc = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise LockError(f"{path}: {exc}") from exc
        if not isinstance(doc, dict):
            raise LockError(f"{path}: expected a JSON object at the top level")
        unknown = sorted(set(doc) - {"version", "note", "git", "files"})
        if unknown:
            raise LockError(f"{path}: unknown top-level key(s) {', '.join(unknown)}")

        lock = cls(
            version=doc.get("version", 1),
            note=doc.get("note"),
            git=[_row(GitRow, o, f"{path}: git row {i}") for i, o in enumerate(doc.get("git", []))],
            files=[_row(FileRow, o, f"{path}: file row {i}") for i, o in enumerate(doc.get("files", []))],
        )
        lock._validate(path)
        return lock

    def _validate(self, path: Path) -> None:
        seen: set[str] = set()
        for row in (*self.git, *self.files):
            if row.name in seen:
                raise LockError(f"{path}: duplicate row name {row.name}")
            seen.add(row.name)
        for row in self.git:
            if not HEX40.match(row.pin):
                raise LockError(f"{path}: {row.name}: pin is not a full 40-hex commit id")
        for row in self.files:
            if not HEX64.match(row.sha256):
                raise LockError(f"{path}: {row.name}: sha256 is not 64 hex characters")
            self.expand_url(row.url)  # every placeholder must resolve

    # ---- lookups ---------------------------------------------------------------------
    def git_row(self, name: str) -> GitRow:
        for row in self.git:
            if row.name == name:
                return row
        raise LockError(f"no git row named {name}")

    def file_row(self, name: str) -> FileRow:
        for row in self.files:
            if row.name == name:
                return row
        raise LockError(f"no file row named {name}")

    def expand_url(self, url: str) -> str:
        """Replace every @<git row name>@ placeholder with that row's pinned commit."""
        return PLACEHOLDER.sub(lambda m: self.git_row(m.group(1)).pin, url)

    # ---- editing (update-lock.py) ----------------------------------------------------
    def set_pin(self, name: str, pin: str) -> None:
        self.git = [dataclasses.replace(r, pin=pin) if r.name == name else r for r in self.git]

    def set_sha256(self, name: str, sha256: str) -> None:
        self.files = [
            dataclasses.replace(r, sha256=sha256) if r.name == name else r for r in self.files
        ]

    # ---- writing ---------------------------------------------------------------------
    @staticmethod
    def _plain(row) -> dict:
        """A row as a JSON object: declared field order, with unset optionals left out."""
        return {
            f.name: getattr(row, f.name)
            for f in dataclasses.fields(row)
            if getattr(row, f.name) != (None if f.default is dataclasses.MISSING else f.default)
        }

    def dumps(self) -> str:
        """Serialise deterministically, so that a pin bump is a one-line diff."""
        doc: dict = {"version": self.version}
        if self.note:
            doc["note"] = self.note
        doc["git"] = [self._plain(row) for row in self.git]
        doc["files"] = [self._plain(row) for row in self.files]
        return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"

    def dump(self, path: Path | str) -> None:
        Path(path).write_text(self.dumps())


# ---- fetching ------------------------------------------------------------------------
def run(cmd: list[str]) -> None:
    """Run a command, raising LockError with the command line if it fails."""
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        raise LockError(f"command failed ({exc.returncode}): {' '.join(cmd)}") from exc


def fetch_git(url: str, pin: str, dest: Path | str) -> None:
    """Shallow-checkout exactly `pin` into `dest`.

    GitHub serves any reachable commit by its full id, so this needs no branch and gets no
    history. It is the same technique the orchestrator's own CI uses to pin modules
    (.github/scripts/override-repos.sh), which is what lets `make` skip its clone rules.
    """
    dest = Path(dest)
    if not HEX40.match(pin):
        raise LockError(f"{url}: pin '{pin}' is not a full 40-hex commit id")
    print(f">> {dest} <- {url} @ {pin}", flush=True)
    shutil.rmtree(dest, ignore_errors=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "init", "-q", str(dest)])
    run(["git", "-C", str(dest), "remote", "add", "origin", url])
    run(["git", "-C", str(dest), "fetch", "-q", "--depth", "1", "origin", pin])
    run(["git", "-C", str(dest), "-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"])


def sha256_of(path: Path | str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def curl(url: str, dest: Path) -> bool:
    """Download to dest, retrying transient failures. False if curl gave up."""
    cmd = [
        "curl", "--fail", "--location", "--silent", "--show-error",
        "--connect-timeout", "15", "--retry", "4", "--retry-all-errors",
        "--output", str(dest), url,
    ]
    return subprocess.run(cmd).returncode == 0


def mirrors(url: str) -> list[str]:
    """Candidate URLs to try, best first.

    aminet.net redirects each download to a random mirror, some slow or broken; try a known
    good one first (the orchestrator's CI pins the same one for the same reason).
    """
    if AMINET_MIRROR and AMINET.match(url):
        return [AMINET.sub(AMINET_MIRROR, url), url]
    return [url]


def fetch_verified(url: str, sha256: str, dest: Path | str) -> None:
    """Download `url` to `dest`, accepting it only if it hashes to `sha256`."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.parent / (dest.name + ".tmp")
    for candidate in mirrors(url):
        print(f">> {dest} <- {candidate}", flush=True)
        tmp.unlink(missing_ok=True)
        if not curl(candidate, tmp):
            print(f"   download failed from {candidate}", flush=True)
            continue
        got = sha256_of(tmp)
        if got == sha256:
            tmp.replace(dest)
            return
        print(f"   checksum mismatch from {candidate}: {got} != {sha256}", flush=True)
    tmp.unlink(missing_ok=True)
    raise LockError(f"could not obtain a verified {dest}")
