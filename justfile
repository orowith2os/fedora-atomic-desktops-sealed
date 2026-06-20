# SPDX-FileCopyrightText: Timothée Ravier <tim@siosm.fr>
# SPDX-License-Identifier: CC0-1.0

# Read in CI with just --evaluate variants
variants := '{
  "silverblue": {
    "image_url": "quay.io/fedora-ostree-desktops/silverblue",
    "fedora_release_and_tag": [[44, 44], [45, 45]]
  },
  "kinoite": {
    "image_url": "quay.io/fedora-ostree-desktops/silverblue",
    "fedora_release_and_tag": [[44, 44], [45, 45]]
  },
  "bootc-44": {
    "image_url": "quay.io/bootc-devel/fedora-bootc-44-standard",
    "fedora_release_and_tag": [[44, "latest"]]
  },
  "secureblue-silverblue": {
    "image_url": "ghcr.io/secureblue/silverblue-main-hardened",
    "fedora_release_and_tag": [[44, 44]]
  },
  "secureblue-kinoite": {
    "image_url": "ghcr.io/secureblue/kinoite-main-hardened",
    "fedora_release_and_tag": [[44, 44]]
  },
  "bazzite-dx": {
    "image_url": "ghcr.io/ublue-os/bazzite-dx",
    "fedora_release_and_tag": [[44, "stable-44"]]
  },
  "bazzite-dx-gnome": {
    "image_url": "ghcr.io/ublue-os/bazzite-dx-gnome",
    "fedora_release_and_tag": [[44, "stable-44"]]
  }
}'

all:
    echo "Please read README.md"

# Container registry where the images will be pushed
# Replace by your own or use 'localhost'
dest_registry := "quay.io/fedora-atomic-desktops-sealed"

# How to connect to libvirt (either system or session)
libvirt_uri := "qemu:///system"

# Builds a container with sbctl and generates Secure Boot keys
generate-secure-boot-keys:
    #!/bin/bash
    set -euo pipefail
    podman build --tag {{dest_registry}}/sbctl:latest --file Containerfile.sbctl
    podman run --rm -ti --security-opt=label=disable \
        --volume $(pwd):/run/src --workdir /run/src \
        {{dest_registry}}/sbctl:latest create-keys --config sbctl.conf

# Sign systemd-boot with the Secure Boot key, with the Fedora version to sign it for
sign-systemd-boot fedora_release:
    #!/bin/bash
    set -euo pipefail
    podman build \
        --tag {{dest_registry}}/systemd-boot:{{fedora_release}} \
        --build-arg=RELEASE={{fedora_release}} \
        --secret=id=secureboot_key,src=keys/db/db.key \
        --secret=id=secureboot_crt,src=keys/db/db.pem \
        --file Containerfile.systemd-boot

# Sign shim with the Secure Boot key, with the Fedora version to sign it for
sign-shim fedora_release:
    #!/bin/bash
    set -euo pipefail
    podman run --rm -ti --security-opt=label=disable \
        --volume $(pwd):/run/src --workdir /run/src \
        {{dest_registry}}/tools:{{fedora_release}} \
        sbsign \
            --key /run/src/keys/db/db.key \
            --cert /run/src/keys/db/db.pem \
            --output /run/src/shimx64-signed.efi \
            /run/src/shimx64-unsigned.efi

# Build the container image with the tools to build and sign UKIs, with the Fedora version to sign it for
build-tools fedora_release:
    #!/bin/bash
    set -euo pipefail
    podman build \
        --tag {{dest_registry}}/tools:{{fedora_release}} \
        --build-arg=RELEASE={{fedora_release}} \
        --file Containerfile.tools

# Build a generic sealed container image derived from the Fedora Silverblue or
# Kinoite unofficial bootable container image
build variant image_url fedora_release image_tag:
    #!/bin/bash
    set -euo pipefail

    podman build \
        --build-arg=BASE=${image_url}:${image_tag} \
        --build-arg=SYSTEMDBOOT={{dest_registry + "/systemd-boot:" + fedora_release}} \
        --build-arg=TOOLS={{dest_registry + "/tools:" + fedora_release}} \
        --tag {{dest_registry}}/{{variant}}:${fedora_release} \
        --skip-unused-stages=false \
        --volume $(pwd):/run/src \
        --security-opt=label=disable \
        --secret=id=secureboot_key,src=keys/db/db.key \
        --secret=id=secureboot_crt,src=keys/db/db.pem \
        .

# Extract the kernel from an image and remove the initrd to build a rechunked
# base image with generic configuration
build-base variant image_url fedora_release image_tag:
    #!/bin/bash
    set -euo pipefail

    podman build \
        --file Containerfile.kernel \
        --build-arg=BASE=${image_url}:${image_tag} \
        --tag {{dest_registry}}/{{variant}}-kernel:${fedora_release} \
        .
    podman build \
        --file Containerfile.base \
        --build-arg=BASE=${image_url}:${image_tag} \
        --build-arg=SYSTEMDBOOT={{dest_registry + "/systemd-boot:" + fedora_release}} \
        --tag {{dest_registry}}/{{variant}}-base:${fedora_release} \
        --skip-unused-stages=false \
        --volume $(pwd):/run/src \
        --security-opt=label=disable \
        .

# Build a sealed image with support for all GPU or only a specific GPU family
[arg('gpu', pattern='generic|amd|intel|nvidia')]
build-uki variant fedora_release gpu="generic":
    #!/bin/bash
    set -euo pipefail

    if [[ "{{gpu}}" == "generic" ]]; then
        repo="{{variant}}"
    else
        repo="{{variant}}-{{gpu}}"
    fi

    podman build \
        --file Containerfile.uki \
        --build-arg=BASE={{dest_registry}}/{{variant}}-base:${fedora_release} \
        --build-arg=KERNEL={{dest_registry}}/{{variant}}-kernel:${fedora_release} \
        --build-arg=GPU_FAMILY={{gpu}} \
        --build-arg=TOOLS={{dest_registry + "/tools:" + fedora_release}} \
        --tag {{dest_registry}}/${repo}:${fedora_release} \
        --volume $(pwd):/run/src \
        --security-opt=label=disable \
        --secret=id=secureboot_key,src=keys/db/db.key \
        --secret=id=secureboot_crt,src=keys/db/db.pem \
        .

# Install the container image to a QCOW2 disk image
qcow2 variant fedora_release:
    #!/bin/bash
    set -euo pipefail

    # Default to btrfs for the Atomic Desktops
    filesystem="btrfs"
    if [[ "{{variant}}" == "bootc-44" ]]; then
        filesystem="ext4"
    fi

    ./bcvk to-disk \
        --filesystem="${filesystem}" \
        --composefs-backend \
        --bootloader=systemd \
        --format qcow2 \
        --disk-size 20G \
        {{dest_registry}}/{{variant}}:{{fedora_release}} \
        {{variant}}-${fedora_release}.qcow2

# Move the QCOW2 image to libvirt image store
move-qcow2-libvirt-images variant fedora_release:
    #!/bin/bash
    set -euo pipefail

    DEST="${HOME}/.local/share/libvirt/images"
    mv -i {{variant}}-${fedora_release}.qcow2 "${DEST}"

# Generate an OVMF variable file for EDK2 with the Secure Boot keys included
generate-ovmf-vars:
    #!/bin/bash
    set -euo pipefail
    if [[ ! -d "keys" ]]; then
        echo "Missing Secure Boot keys"
        exit 1
    fi
    GUID=$(cat keys/GUID)
    virt-fw-vars \
        --input "/usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2" \
        --secure-boot \
        --set-pk  $GUID "keys/PK/PK.pem" \
        --add-kek $GUID "keys/KEK/KEK.pem" \
        --add-db  $GUID "keys/db/db.pem" \
        -o "OVMF_VARS_CUSTOM.qcow2"

# Boot the QCOW2 image with libvirt
libvirt variant fedora_release:
    #!/bin/bash
    set -euo pipefail

    DEST="${HOME}/.local/share/libvirt/images"

    name="fedora-{{variant}}-${fedora_release}"
    image="${DEST}/{{variant}}-${fedora_release}.qcow2"
    ovmf_vars="${DEST}/{{variant}}-${fedora_release}_ovmf_vars.qcow2"

    cp "OVMF_VARS_CUSTOM.qcow2" "${ovmf_vars}"

    VCPUS="4"
    RAM_MB="4096"
    DISK_GB="20"

    OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2"
    OVMF_VARS_TEMPLATE="/usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2"

    loader="loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,loader_secure=yes"
    nvram="nvram=${ovmf_vars},nvram.template=${OVMF_VARS_TEMPLATE}"
    features="firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes"
    uefi_arg+=("uefi,${loader},${nvram},${features}")

    virt-install --connect="{{libvirt_uri}}" \
        --name="${name}" \
        --vcpus="${VCPUS}" \
        --memory="${RAM_MB}" \
        --os-variant="fedora{{fedora_release}}" \
        --import \
        --disk="size=${DISK_GB},backing_store=${image}" \
        --network bridge=virbr0 \
        --machine q35 \
        --boot "${uefi_arg}" \
        --tpm "backend.type=emulator,backend.version=2.0,model=tpm-tis" \
        --noautoconsole

# Build and sign a UKI addon
uki-addon name commandline fedora_release:
    #!/bin/bash
    set -euo pipefail
    podman run --rm -ti --security-opt=label=disable \
        --volume $(pwd):/run/src --workdir /run/src \
        --secret=id=secureboot_key,src=keys/db/db.key \
        --secret=id=secureboot_crt,src=keys/db/db.pem \
        {{dest_registry + "/tools:" + fedora_release}} \
        ukify build \
            --cmdline "{{commandline}}" \
            --signtool sbsign \
            --secureboot-private-key /run/secrets/secureboot_key \
            --secureboot-certificate /run/secrets/secureboot_crt \
            --output "/run/src/{{name}}.addon.efi"

# Inspect a UKI or UKI addon
inspect uki fedora_release:
    #!/bin/bash
    set -euo pipefail
    podman run --rm -ti --security-opt=label=disable \
        --volume $(pwd):/run/src --workdir /run/src \
        {{dest_registry + "/tools:" + fedora_release}} \
        ukify inspect "/run/src/{{uki}}"
