# Shared Amiga (m68k-amigaos) build image for the driver stacks.
#
# Base: stefanreinauer/amiga-gcc (PUBLIC, Docker Hub). Provides Bebbo's
# m68k-amigaos gcc at /opt/amiga, NDK 3.2 (from Aminet NDK3.2.lha) with
# libraries/keymap.h, AROS-open <devices/sana2.h> in m68k-amigaos/ndk-include,
# plus lha / python3 / sfdc / fd2sfd.
#
# BASE_TAG selects which upstream gcc build to pin (see
# https://hub.docker.com/r/stefanreinauer/amiga-gcc/tags). Default is gcc-v6.5.0b
# (Bebbo's classic port); CI also builds gcc-v13.4, gcc-v15.2 and gcc-v16.1 variants
# of this same image, see .github/workflows/docker-image.yml.
ARG BASE_TAG=gcc-v6.5.0b
FROM stefanreinauer/amiga-gcc:${BASE_TAG}

# This layer adds the few things the stacks need on top of that base:
#   1. cmake            (the base ships none)
#   2. flexcat          (built from adtools/flexcat)
#   3. MUI 5.0 SDK      (official amiga-mui/muidev os3 release, COMPLETE archive)
#   4. env hints        (MUI_INCLUDE_DIR / SANA2_INCLUDE_DIR for cmake configure)
#
# Consumers: poseidon-backport uses all of it; emu68-driver-stack uses only the
# cmake + NDK 3.2 toolchain (it ignores the MUI/flexcat layers).

ARG FLEXCAT_VERSION=2.18
ARG MUI_RELEASE=MUI-5.0-20210831
ARG MUI_LHA=MUI-5.0-20210831-os3.lha

# 0. Toolchain-path compatibility alias. The reinauer base puts the toolchain at
#    /opt/amiga; amigadev/crosstools (and consumers written against it — e.g.
#    emu68-driver-stack, whose toolchain.cmake defaults TOOLCHAIN_PATH=/opt/m68k-amigaos)
#    expect /opt/m68k-amigaos. This symlink makes the image a drop-in for both layouts.
RUN ln -s /opt/amiga /opt/m68k-amigaos

# 1. cmake + xxd
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cmake xxd \
 && rm -rf /var/lib/apt/lists/*

# 1a. NDK header fix: inline/bsdsocket.h (Roadshow TCP/IP's hand-written asm
#    stubs) hits a GCC 9+ hard error -- a register-pinned input operand also
#    listed in that same asm statement's clobber list -- that GCC 6.5 (this
#    image's default base) tolerated. Harmless on every GCC version (removes
#    a redundant clobber entry, doesn't change codegen); see the script for
#    the full explanation. Only inline/bsdsocket.h is affected; usergroup.h
#    was checked and is clean.
COPY patches/fix-ndk-asm-clobbers.py /tmp/fix-ndk-asm-clobbers.py
RUN python3 /tmp/fix-ndk-asm-clobbers.py /opt/amiga/m68k-amigaos/ndk-include/inline/bsdsocket.h \
 && rm /tmp/fix-ndk-asm-clobbers.py

# 2. flexcat -- host (unix) build. The Makefile has a bootstrap cycle: it tries to
#    run flexcat to regenerate its own committed cat-source files. Touch them so they
#    look up-to-date, breaking the cycle. Install the resulting native binary on PATH.
RUN git clone --depth 1 --branch ${FLEXCAT_VERSION} https://github.com/adtools/flexcat.git /tmp/flexcat \
 && cd /tmp/flexcat/src \
 && touch locale.c locale_other.c FlexCat_cat.h FlexCat_cat_other.h \
 && cd /tmp/flexcat \
 && make OS=unix DEBUG= \
 && install -m755 src/bin_unix/flexcat /usr/local/bin/flexcat \
 && flexcat 2>/dev/null | head -1 \
 && rm -rf /tmp/flexcat

# 3. Official MUI 5.0 dev SDK. The COMPLETE archive is extracted unmodified.
ADD https://github.com/amiga-mui/muidev/releases/download/${MUI_RELEASE}/${MUI_LHA} /tmp/mui.lha
RUN mkdir -p /opt/mui-sdk \
 && cd /opt/mui-sdk \
 && lha xq /tmp/mui.lha \
 && rm -f /tmp/mui.lha \
 && test -f /opt/mui-sdk/SDK/MUI/C/include/defines/muimaster.h \
 && test -f /opt/mui-sdk/SDK/MUI/C/include/inline/muimaster.h

# 4. Configure hints. SANA-II headers live in the NDK 3.2 ndk-include tree the base ships.
ENV MUI_INCLUDE_DIR=/opt/mui-sdk/SDK/MUI/C/include
ENV SANA2_INCLUDE_DIR=/opt/amiga/m68k-amigaos/ndk-include
ENV PATH=/opt/amiga/bin:/usr/local/bin:${PATH}
