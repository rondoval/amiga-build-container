# syntax=docker/dockerfile:1
# Shared Amiga (m68k-amigaos) build image for the driver stacks (emu68-driver-stack,
# poseidon-backport). Everything is built here from the pinned sources listed in
# toolchain.lock.json; no prebuilt toolchain image is consumed.
#
#   toolchain  ubuntu + build deps; fetch pinned sources (networked); build into /opt/amiga (offline)
#   final      ubuntu + runtime deps; /opt/amiga copied in; MUI 5 SDK; env
#   test       final + tests/smoke-test.sh, run as an unprivileged uid (CI builds this target first)
#
# Both stages share one base. Overridable for a trial build against another release:
# docker build --build-arg UBUNTU=ubuntu:28.04 ...
ARG UBUNTU=ubuntu:26.04

# ---------------------------------------------------------------------------------------------
# Sources: the only networked step, and the only one that reads the lock. Kept as its own stage
# so it can be built and inspected on its own (docker build --target sources), which is also how
# a change to the fetch logic is diffed against the previous one. Cache key: lock + fetch script.
FROM ${UBUNTU} AS sources
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf automake bison build-essential ca-certificates curl file flex gettext git \
      libgmp-dev libmpfr-dev libmpc-dev make patch perl python3 rsync wget xz-utils \
 && rm -rf /var/lib/apt/lists/*

COPY toolchain.lock.json scripts/lock.py scripts/fetch-sources.py /src/
RUN /src/fetch-sources.py

# ---------------------------------------------------------------------------------------------
FROM sources AS toolchain
# Build, offline. A change to the build recipe re-runs this without refetching. The build
# tree is removed inside this RUN so no intermediate layer ever carries it.
COPY scripts/build-toolchain.sh /src/
RUN --network=none /src/build-toolchain.sh

# Verify, strip and trim. Its script is copied only now, so editing it never invalidates
# the toolchain layer above.
COPY scripts/finish-toolchain.sh /src/
RUN --network=none /src/finish-toolchain.sh

# ---------------------------------------------------------------------------------------------
FROM ${UBUNTU} AS final
ENV DEBIAN_FRONTEND=noninteractive
# Runtime: cmake, make, xxd (bin2h), git (configure-time version strings), python3 and the shared
# libraries cc1/lto1 link against. sfdc is Perl; perl-base is part of the base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates cmake git make python3 xxd libgmp10 libmpfr6 libmpc3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=toolchain /opt/amiga /opt/amiga
# Consumers written against amigadev/crosstools (emu68's toolchain.cmake defaults
# TOOLCHAIN_PATH=/opt/m68k-amigaos) and against this image's /opt/amiga both work.
RUN ln -s /opt/amiga /opt/m68k-amigaos
ENV PATH=/opt/amiga/bin:/usr/local/bin:${PATH}
ENV MUI_INCLUDE_DIR=/opt/mui-sdk/SDK/MUI/C/include
ENV SANA2_INCLUDE_DIR=/opt/amiga/m68k-amigaos/ndk-include

# Official MUI 5.0 developer SDK (amiga-mui/muidev), the COMPLETE archive extracted unmodified.
# Its explicit-base inline headers are what poseidon builds against (MUI_INCLUDE_DIR).
COPY --from=toolchain /src/download/MUI-5.0-20210831-os3.lha /tmp/mui.lha
RUN mkdir -p /opt/mui-sdk \
 && cd /opt/mui-sdk \
 && lha xq /tmp/mui.lha \
 && rm -f /tmp/mui.lha \
 && test -f /opt/mui-sdk/SDK/MUI/C/include/defines/muimaster.h \
 && test -f /opt/mui-sdk/SDK/MUI/C/include/inline/muimaster.h

# Provenance travels with the image: the lock that built it, and the resolved manifest
# (/opt/amiga/etc/SOURCES, written by the toolchain stage).
COPY toolchain.lock.json /opt/amiga/etc/toolchain.lock.json

LABEL org.opencontainers.image.source="https://github.com/rondoval/amiga-build-container" \
      org.opencontainers.image.description="m68k-amigaos GCC cross toolchain (AmigaPorts amiga16.2) + NDK 3.2 + MUI 5 SDK + cmake, built from pinned sources"

# ---------------------------------------------------------------------------------------------
FROM final AS test
COPY tests/ /tests/
USER 1000:1000
ENV HOME=/tmp LC_ALL=C
RUN /tests/smoke-test.sh
