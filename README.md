# amiga-build-container

A shared **m68k-amigaos cross-build image** for the Amiga driver/stack projects
(`poseidon-backport`, `emu68-driver-stack`, …). It is published to
**`ghcr.io/rondoval/amiga-build-container:latest`** and consumed by those repos' CI.

## What's in it

It builds `FROM` the public [`stefanreinauer/amiga-gcc`](https://hub.docker.com/r/stefanreinauer/amiga-gcc)
image (Bebbo's `m68k-amigaos` GCC 6.5.0b at `/opt/amiga`, **NDK 3.2** from Aminet, AROS-open
`<devices/sana2.h>`, `lha`, `python3`, `sfdc`) and adds:

| Addition | Why |
|---|---|
| **cmake** (apt) | the base ships none; ≥3.30 for emu68's `devicetree.resource` |
| **flexcat** (built from [`adtools/flexcat`](https://github.com/adtools/flexcat) 2.18) | poseidon's Trident catalog generation |
| **MUI 5.0 SDK** (complete [`amiga-mui/muidev`](https://github.com/amiga-mui/muidev) os3 release) | poseidon's Trident + GUI classes — the *explicit-base* SDK |

Configure hints are baked in as env vars: `MUI_INCLUDE_DIR`, `SANA2_INCLUDE_DIR`, and
`/opt/amiga/bin` on `PATH`.

## Using it

Run CI jobs inside the image and point the toolchain at `/opt/amiga`:

```sh
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain.cmake \
      -DTOOLCHAIN_PATH=/opt/amiga \
      -DMUI_INCLUDE_DIR="$MUI_INCLUDE_DIR" \
      -DSANA2_INCLUDE_DIR="$SANA2_INCLUDE_DIR"
cmake --build build -j"$(nproc)"
```

emu68-driver-stack uses only the cmake + NDK 3.2 toolchain (it ignores the MUI/flexcat layers).

## Licensing

All bundled software is freely distributable: the GCC toolchain/binutils (GPL), `flexcat`
(GPL), the NDK 3.2 headers (public Aminet archive), and the **complete, unmodified** MUI 5.0
developer SDK.

## Rebuilding

`.github/workflows/docker-image.yml` builds and pushes to GHCR on changes to the `Dockerfile`
(and on manual `workflow_dispatch`). Locally: `docker build -t amiga-build-container .`
