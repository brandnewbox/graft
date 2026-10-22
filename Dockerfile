# syntax=docker/dockerfile:1.7
# The iOS toolchain from joshuaswarren/omarchy-apple-dev (Swift, xtool, pymobiledevice3, the
# iPhoneOS SDK) on Ubuntu 24.04, following its docs/DISTROS.md. Full mode: the SDK comes from an
# Xcode .xip. This builds everything up to the SDK step; `ios-linux setup` adds the SDK.

FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive

# DISTROS.md's Ubuntu list, minus libimobiledevice-dev (too old for xtool; built below) and usbmuxd
# (pairing uses the host's).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      binutils build-essential ca-certificates cmake curl file git gnupg2 libc6-dev \
      libcurl4-openssl-dev libedit2 libfuse3-dev libbz2-dev libgcc-13-dev libheif-dev \
      libheif-examples liblzma-dev libncurses6 libncursesw6 libpython3-dev libssl-dev \
      libstdc++-13-dev libtinfo6 libxml2-dev libz3-dev llvm pkg-config poppler-utils python3 \
      python3-venv rsync unzip zip zlib1g-dev \
      autoconf automake libtool \
      libffi8 libgdbm6t64 libreadline8t64 libsqlite3-0 libuuid1 \
      sudo iproute2 iputils-ping openssh-client \
 && rm -rf /var/lib/apt/lists/*

# The tailnet tunnel needs TLS-PSK, so Python 3.13 or newer (docs/OVER-TAILNET.md); 24.04 ships
# 3.12. The official image's build links the system OpenSSL, which has it (uv's builds don't).
# Only as python3.14: the rest of the system keeps 3.12, which the toolchain's lldb links.
COPY --from=python:3.14-slim-bookworm /usr/local /usr/local
RUN cd /usr/local/bin && rm -f python python3 python-config python3-config pip pip3 pydoc pydoc3 idle idle3 \
 && ldconfig \
 && python3.14 -c 'import ssl; assert hasattr(ssl.SSLContext, "set_psk_client_callback")'

# Swift from swift.org, keeping the archive's usr/ level (SwiftPM walks up to usr/lib/swift).
# Its Swift must match the Xcode the SDK comes from: 6.4.0 for Xcode 27.0.
ARG SWIFT_VERSION=6.4.0
RUN curl -fsSL "https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local \
 && /usr/local/usr/bin/swift --version
ENV PATH=/usr/local/usr/bin:$PATH

# libimobiledevice from source: 24.04's 1.3.0 has no idevice_events_subscribe, which xtool needs.
# Its whole stack, so nothing links 24.04's older libplist.
ENV PKG_CONFIG_PATH=/usr/local/usr/lib/pkgconfig
RUN set -e; cd /tmp; \
    for r in libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice; do \
      git clone -q --depth 1 "https://github.com/libimobiledevice/$r"; \
      (cd "$r" && ./autogen.sh --prefix=/usr/local/usr >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null); \
    done; \
    echo /usr/local/usr/lib > /etc/ld.so.conf.d/usrlocalusr.conf; ldconfig; \
    rm -rf /tmp/lib*

# A user matching the host's, so files written to the mounted repo keep their owner. Passwordless
# sudo: tailnet-tunnel.py re-runs itself with `sudo -n` for the TUN device.
ARG UID=1000
ARG GID=1000
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g "$GID" dev && useradd -m -u "$UID" -g "$GID" -s /bin/bash dev \
 && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
 && chown -R dev:dev /usr/local/usr/share/pm
# install_darwin_tools patches SwiftBuild's xcspec defaults inside the toolchain, hence the chown.

USER dev
WORKDIR /home/dev
ENV PATH=/home/dev/.local/bin:$PATH

ARG OMARCHY_REF=d585573d9da52394abba82840f6b5e6d15e304c7
RUN git init -q omarchy-apple-dev \
 && git -C omarchy-apple-dev fetch -q --depth 1 https://github.com/joshuaswarren/omarchy-apple-dev "$OMARCHY_REF" \
 && git -C omarchy-apple-dev checkout -q FETCH_HEAD

# The installer keeps a healthy venv, so making it here picks the interpreter.
RUN python3.14 -m venv pymobile3-venv \
 && pymobile3-venv/bin/pip install -q pymobiledevice3 \
 && pymobile3-venv/bin/pip show pymobiledevice3 | grep ^Version

# xtool, rcodesign, ipsw. Without an .xip the installer stops at the SDK step with exit 1 and
# "One download left"; anything else is a real failure. xtool's build tree and the package caches
# (2.8 GB) aren't needed once it's installed in ~/.local/lib.
RUN cd omarchy-apple-dev \
 && { ./install-toolchain.sh --mode full > /tmp/install.log 2>&1; status=$?; cat /tmp/install.log; \
      [ "$status" = 0 ] || grep -q 'One download left' /tmp/install.log; } \
 && xtool --version && rcodesign --version && ipsw version | head -n1 \
 && rm -rf ~/.cache/omarchy-apple-dev ~/.cache/org.swift.swiftpm ~/.cache/clang ~/.cache/pip

# actool rasterizes SVG images with rsvg-convert, which DISTROS.md's list leaves out.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends librsvg2-bin && rm -rf /var/lib/apt/lists/*
USER dev

COPY --chmod=755 bin/installer-steps /usr/local/bin/

# The Linux stand-ins for Xcode's build tools (actool, ibtool, ...) and the macro server. The installer
# builds them after the SDK, copies them into it, and patches SwiftBuild's defaults in the toolchain.
# Its two functions, run here against a stub SDK, do the building and the toolchain patch in the
# image; setup-sdk runs them again against the real SDK, installing what was built here.
RUN stub=/tmp/stub.artifactbundle \
 && mkdir -p "$stub/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins" \
 && echo '{}' > "$stub/toolset-swb.json" \
 && DARWIN_SDK_BUNDLE=$stub installer-steps install_darwin_tools \
 && DARWIN_SDK_BUNDLE=$stub installer-steps install_oam \
 && rm -rf "$stub" ~/.cache/clang ~/.cache/org.swift.swiftpm

# What outlives a container, in two volumes shared by every project: ios-linux-state at /state
# (pairing records, signing identities, Apple ID auth) and ios-linux-sdk at /sdk (the iOS SDK, made
# once by `setup` from the user's own Xcode, which can't be in a published image).
# pymobiledevice3 keeps pairing records in ~/.pymobiledevice3 and tailnet-tunnel.py looks in
# ~/.local/share/pymobiledevice3: one directory.
RUN mkdir -p .local/share .config/omarchy-apple-dev .swiftpm \
 && ln -s /state/xtool .local/share/xtool \
 && ln -s /state/pymobiledevice3 .local/share/pymobiledevice3 \
 && ln -s /state/pymobiledevice3 .pymobiledevice3 \
 && ln -s /state/development .config/omarchy-apple-dev/development \
 && rm -rf .swiftpm/swift-sdks && ln -s /sdk/swift-sdks .swiftpm/swift-sdks
COPY --chmod=755 bin/ /usr/local/bin/
RUN home-writable

# The launcher runs on the host; projects keep a stub that reads it from here (README.md).
COPY --chmod=644 ios-linux /usr/local/share/ios-linux/launcher

# The entrypoint gives dev the caller's UID, then drops to it.
USER root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
LABEL org.opencontainers.image.source=https://github.com/brandnewbox/ios-linux
