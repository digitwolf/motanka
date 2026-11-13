# The CI harness container (task 24.1). GitHub's runners do not have the
# host tools of the VM harness (tech.md: qemu-system-x86_64, qemu-img,
# ssh, rsync, gpgv, python3, zstd), and CI jobs never install packages on
# the runner itself. Every CI step that boots a test VM, lints or signs
# runs in this container instead, through ci/in-harness, as an unprivileged
# user with the runner's uid and gid. The VMs it starts are the same
# throwaway QEMU/KVM VMs test/vm/ starts on a development machine.
#
# Ubuntu 26.04 matches the development host, so shellcheck and shfmt have
# the versions the developer uses. The tag is not pinned by digest.
FROM ubuntu:26.04

ARG CI_UID=1001
ARG CI_GID=1001

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# qemu-system-x86, qemu-utils, ipxe-qemu, seabios: the test VMs.
# openssh-client, rsync: test/vm/run and test/vm/push.
# python3, gpgv, ubuntu-cloudimage-keyring: test/vm/image, tools/*.
# ubuntu-keyring: tools/aptnames checks the archive's InRelease with it.
# gnupg, apt-utils, xz-utils, zstd: chumak/build-repo, ci/publish-repo.
# shellcheck, shfmt: the lint job.
# git, curl, ca-certificates: ci/pin-bump and tools/vendor.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-utils \
        ca-certificates \
        curl \
        git \
        gnupg \
        gpgv \
        ipxe-qemu \
        openssh-client \
        python3 \
        qemu-system-x86 \
        qemu-utils \
        rsync \
        seabios \
        shellcheck \
        shfmt \
        ubuntu-cloudimage-keyring \
        ubuntu-keyring \
        util-linux \
        xz-utils \
        zstd \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --non-unique --gid "$CI_GID" ci \
    && useradd --non-unique --create-home --uid "$CI_UID" --gid "$CI_GID" --shell /bin/bash ci

USER ci
WORKDIR /work
