# amiga-build-container

A shared **m68k-amigaos cross-build image** for the Amiga driver/stack projects
(`emu68-driver-stack`, `neptune-usb-stack`), published to
**`ghcr.io/rondoval/amiga-build-container`** and consumed by those repos' `scripts/docker-build.sh`.

The toolchain is **built from source here**, from the commits pinned in
[`toolchain.lock.json`](toolchain.lock.json). The sources are the actively maintained AmigaPorts
continuation of Bebbo's amiga-gcc, and every input (16 git modules, the NDK archive, the AHI
and P96 developer kits, the AROS SANA-II headers, the Emu68 resource SFDs, the MUI SDK, gcc's
gmp/mpfr/mpc prerequisites) is pinned by commit or sha256.

## Tags

| Tag | Meaning |
|---|---|
| `gcc-v16.2` | gcc 16.2.0b (`AmigaPorts/gcc` branch `amiga16.2`) + binutils 2.46, the current toolchain |
| `latest` | same as `gcc-v16.2` |
| `sha-<git7>` | the candidate built from that commit of this repo; promoted to the two tags above after the consumer gate |
| `gcc-v6.5.0b`, `gcc-v13.4`, `gcc-v15.2`, `gcc-v16.1` | frozen: the former `stefanreinauer/amiga-gcc`-based images, kept as a rollback path |

## What's in it

Toolchain at `/opt/amiga` (also reachable as `/opt/m68k-amigaos`, on `PATH`):

* **gcc 16.2.0b** (C, C++, ObjC; 10 multilibs: 68000/020/060 × baserel variants × 68881),
  **binutils 2.46** with HUNK support, **libnix** (`-mcrt=nix20` / `-noixemul`, `nix13`), **clib2**,
  **newlib** headers, **libdebug**, **libpthread**, **libamiga**. gmp, mpfr and mpc are built
  in-tree, so neither compiler depends on the host distribution's copies.
* **NDK 3.2 R4** (Aminet `NDK3.2.lha`, sha256-pinned) integrated as `m68k-amigaos/ndk-include`:
  `proto/`, `inline/`, `lvo/` generated with **sfdc 1.13**; the Roadshow TCP/IP `netinclude`
  (`sys/socket.h`, `proto/bsdsocket.h`, …) from `AmigaPorts/amiga-netinclude`, with its
  `inline/bsdsocket.h` generated here from the NDK's own SFD (see below); AROS' open
  `devices/sana2.h` + `sana2specialstats.h` (pinned AROS commit).
* **AHI 6.0 developer headers** (`devices/ahi.h`, `libraries/ahi_sub.h`, `proto/ahi.h`).
* **P96 3.6.1 developer headers** (iComp's `P96Develop.lha`, installed by the orchestrator's
  `sdk/p96.sdk`): the vendor's own `proto/Picasso96.h`, `clib/Picasso96_protos.h`,
  `inline/Picasso96.h` and `libraries/Picasso96.h` (base `P96Base`), plus
  `lib/sfd/Picasso96API_lib.sfd` and an auto-open stub in `libstubs.a`. `clib/Picasso96_protos.h`
  uses `struct RastPort` without declaring it, so include `<proto/graphics.h>` first. The driver
  kit (`boardinfo.h`, `sdk/p96card.sdk`) is not installed.
* **Emu68 resource headers** for `devicetree.resource`, `mailbox.resource` and `cma.resource`
  (Michal Schulz's repos; their SFDs and `resources/cma.h` at pinned commits): `clib/`, `proto/`,
  `inline/` and `lvo/` generated here by sfdc with the same modes as the other SDK headers, the
  SFDs installed under `lib/sfd/`. Include `<proto/devicetree.h>`, `<proto/mailbox.h>`,
  `<resources/cma.h>` and `<proto/cma.h>`.
* Host tools: `sfdc`, `fd2sfd`, `fd2pragma`, `vasm`, `ira`, `lha` (lha-ac, with the
  `--system-kanji-code`/`--archive-kanji-code` options), `flexcat`, plus `cmake` 4.2, `make`, `xxd`,
  `git`, `python3`, `perl`.
* **MUI 5.0 SDK** (official `amiga-mui/muidev` os3 release, complete archive) at `/opt/mui-sdk`.

The SDK headers (AHI, P96, Emu68 resources) live in `m68k-amigaos/include/`, on the compiler's
default include path next to the NDK's, so consumers need no `-I` for them.
Configure hints are baked in as env vars: `MUI_INCLUDE_DIR`, `SANA2_INCLUDE_DIR`.
Provenance travels with the image: `/opt/amiga/etc/toolchain.lock.json` (the lock that built it) and
`/opt/amiga/etc/SOURCES` (the resolved commits and archive checksums).

### Two NDK headers generated here, not taken as the orchestrator leaves them

Both come out of `scripts/build-toolchain.sh`, produced by the same pinned sfdc from the same
pinned NDK archive as every other header.

1. **`proto/cardres.h` and `inline/cardres.h`** — sfdc derives the names it references from
   the SFD's `==libname` (`card.resource` → `card`), the NDK names its files after the SFD
   (`cardres_lib.sfd` → `cardres.*`), and `cardres` is the one NDK 3.2 SFD where the two
   disagree. sfdc's `proto/cardres.h` has therefore always included a `clib/card_protos.h` that
   does not exist; sfdc 1.13's `inline/cardres.h` additionally includes `proto/card.h`. The
   orchestrator's NDK rule even copies the NDK's own `proto/cardres.h` explicitly, then its
   sfdc proto rule overwrites it. The image ships the NDK's own proto header and an inline
   header generated with sfdc's `--protoname=cardres`, the option that exists for exactly this
   case (the Makefile never passes it, and sfdc's proto mode has no equivalent yet).
2. **`inline/bsdsocket.h`** — `AmigaPorts/amiga-netinclude` carries Roadshow's 2017
   fd2pragma-generated inline header rewritten by hand into asm stubs: they repeat register-pinned
   input operands in their clobber lists (a hard error since GCC 9) and marshal varargs through
   the `_sfdc_vararg` type that sfdc 1.13 only defines in the headers that need it. The NDK
   archive ships Roadshow's own `bsdsocket_lib.sfd`; the image generates the inline header from
   it like every other inline header, and installs the SFD under `ndk/lib/sfd/`. The rest of
   amiga-netinclude (`sys/`, `netinet/`, `netdb.h`, `proto/bsdsocket.h`, …) is used as is.

## Using it

Run builds inside the image and point the toolchain at `/opt/amiga` or `/opt/m68k-amigaos`:

```sh
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain.cmake \
      -DTOOLCHAIN_PATH=/opt/amiga \
      -DMUI_INCLUDE_DIR="$MUI_INCLUDE_DIR" \
      -DSANA2_INCLUDE_DIR="$SANA2_INCLUDE_DIR"
cmake --build build -j"$(nproc)"
```

## Bumping the toolchain

`toolchain.lock.json` is the only place pins live. To move to the current branch heads:

```sh
scripts/update-lock.py            # git rows -> branch heads (full 40-hex ids)
scripts/update-lock.py --files    # ...and re-hash the archives / raw files
scripts/update-lock.py gcc sfdc   # ...only these rows
```

Each row carries everything about one input: where it is checked out or downloaded to (`dest`,
relative to `/src`), which file's presence stops the orchestrator's Makefile from cloning the
module itself (`marker`), whether its clone rule also applies local patches (`patched`), and,
for a file the Makefile pins as well, the variable it pins it with (`makefile_pin`: the NDK
archive and the three gcc prerequisites), and for an archive the orchestrator installs with
`make sdk=<name>`, that descriptor's name (`sdk`: AHI, P96; the descriptor's `Url:` and `Sha256:`
must agree with the row, and the build installs every SDK the lock names).
`scripts/fetch-sources.py` is driven entirely by those fields, so adding or moving an input is a
lock edit rather than a script edit.

A git row without `dest` is never checked out: it only pins the commit that `@<name>@` in the
URLs of loose files expands to (`aros` for the SANA-II headers; `devicetree.resource`,
`mailbox.resource` and `cma.resource` for the Emu68 resource SFDs). Moving such a pin needs
`--files` as well, to re-hash the files it serves. Another SFD-only interface is one such row
plus a file row with `dest` under `extra/sfd/` (and `extra/include/` for a header of its own).

A `makefile_pin` mismatch fails the sources stage. It means upstream moved to another version of
that archive: the Makefile's download rule names the file after the version it pins, so the
pre-downloaded one no longer satisfies it and the offline build step would go looking for the
network. Follow the new version in the row's `name`, `url`, `dest` and `sha256`.

Review the diff, commit, push. CI rebuilds the toolchain stage,
runs the in-image smoke test, builds `emu68-driver-stack` and `neptune-usb-stack` with the
candidate, and only then moves `gcc-v16.2` + `latest`. Changes that leave the lock and
`scripts/` untouched (tests, the final stage) reuse the toolchain stage from the registry
build cache and take a few minutes.

## Building locally

```sh
docker build --target final -t amiga-build-container:dev .   # ~15 min on a 24-core host
docker build --target test  .                               # + the in-image smoke test
```

The Dockerfile's stages: `sources` (materialise every pinned input under `/src`), `toolchain`
(build offline into `/opt/amiga`), `final` (runtime image), `test` (`final` +
`tests/smoke-test.sh` as uid 1000). `sources` is the only stage with network access; everything
after it runs with `--network=none`.

Validate the consumers against the local image through their own wrappers (fresh build trees):

```sh
EMU68_BUILD_IMAGE=amiga-build-container:dev    ./scripts/docker-build.sh   # in emu68-driver-stack
NEPTUNE_BUILD_IMAGE=amiga-build-container:dev  ./scripts/docker-build.sh   # in neptune-usb-stack
```

## Licensing

All bundled software is freely distributable: the GCC toolchain and binutils (GPL), libnix,
newlib and clib2 (their respective licenses, see the AmigaPorts repos), `lha` and `flexcat` (GPL),
the NDK 3.2 headers (public Aminet archive), the AHI developer kit (Aminet), the AROS SANA-II
headers (APL), the P96 developer files (CC-BY 4.0, © iComp / Jens Schönfeld,
<https://wiki.icomp.de/wiki/P96>), the devicetree.resource, mailbox.resource and cma.resource
SFDs and `resources/cma.h` (Mozilla Public License 2.0, <https://mozilla.org/MPL/2.0/>; sources at
<https://github.com/michalsc>), and the **complete, unmodified** MUI 5.0 developer SDK.
