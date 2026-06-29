# Shared Amiga (m68k-amigaos) build image for the driver stacks.
#
# Base: stefanreinauer/amiga-gcc (PUBLIC, Docker Hub). Provides Bebbo's
# m68k-amigaos gcc 6.5.0b at /opt/amiga, NDK 3.2 (from Aminet NDK3.2.lha) with
# libraries/keymap.h, AROS-open <devices/sana2.h> in m68k-amigaos/ndk-include,
# plus lha / python3 / sfdc / fd2sfd.
#
# This layer adds the few things the stacks need on top of that base:
#   1. cmake            (the base ships none)
#   2. flexcat          (built from adtools/flexcat)
#   3. MUI 5.0 SDK      (official amiga-mui/muidev os3 release, COMPLETE archive)
#   4. env hints        (MUI_INCLUDE_DIR / SANA2_INCLUDE_DIR for cmake configure)
#
# Consumers: poseidon-backport uses all of it; emu68-driver-stack uses only the
# cmake + NDK 3.2 toolchain (it ignores the MUI/flexcat layers).
FROM stefanreinauer/amiga-gcc:latest

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
