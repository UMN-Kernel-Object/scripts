#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2024 Nathan Ringo <nathan@remexre.com>
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# Some configurables.
KERNEL_CLONE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz"
ROOTFS_HASH="185123ceb6e7d08f2449fff5543db206ffb79decd814608d399ad447e08fa29e"
DEFAULT_KERNEL_DIR="$here/linux"
DEFAULT_FS_DIR="$here"

# say VERB REST...
#
#   Prints a message, with the verb highlighted in green if stdout was a TTY.
say() {
	verb="$1"
	shift
	if [[ -t 1 ]]; then
		printf "\e[1;32m%s\e[0m %s\n" "$verb" "$*"
	else
		printf "%s %s\n" "$verb" "$*"
	fi
}

# errsay ADJECTIVE REST...
#
#   Prints a message, with the adjective highlighted in red if stdout was a TTY.
errsay() {
	adjective="$1"
	shift
	if [[ -t 1 ]]; then
		printf "\e[1;31m%s\e[0m %s\n" "$adjective" "$*"
	else
		printf "%s %s\n" "$adjective" "$*"
	fi
}

# config_check ITEM
#
#   Checks that the given config item is set to y, or warns about it.
config_check() {
	fail=0
	while (( $# != 0 )); do
		if ! grep -F "CONFIG_$1=y" "$kernel_dir/.config" >/dev/null; then
			errsay Missing .config option "CONFIG_$1"
			fail=1
		fi
		shift
	done
	if [[ $fail != 0 ]]; then
		exit 1
	fi
}

# Parse arguments.
# 
#     Usage: kern-me-up.sh [KERNEL-DIR] [FS-DIR] QEMU-ARGS...
kernel_dir="${KMU_KERNEL_DIR:-$DEFAULT_KERNEL_DIR}"
fs_dir="${KMU_FS_DIR:-$DEFAULT_FS_DIR}"
if [[ $# -gt 0 ]]; then
	if [[ "$1" != "-" ]]; then
		kernel_dir="$(realpath "$1")"
	fi
	shift
fi
if [[ $# -gt 0 ]]; then
	if [[ "$1" != "-" ]]; then
		fs_dir="$(realpath "$1")"
	fi
	shift
fi

# Ensure that a configured and built kernel is present.
if [[ ! -d "$kernel_dir" ]]; then
	say Cloning "$KERNEL_CLONE_URL..."
	git clone "$KERNEL_CLONE_URL" "$kernel_dir"
fi
if [[ ! -f "$kernel_dir/.config" ]]; then
	say Configuring kernel with defconfig...
	make -C "$kernel_dir" defconfig
	say Setting config options we require...
	sed -i "$kernel_dir/.config" \
		-e 's/# CONFIG_9P_FS_POSIX_ACL is not set/CONFIG_9P_FS_POSIX_ACL=y/' \
		-e 's/CONFIG_DEBUG_INFO_NONE=y/# CONFIG_DEBUG_INFO_NONE is not set/' \
		-e 's/# CONFIG_DEBUG_INFO_DWARF5 is not set/CONFIG_DEBUG_INFO_DWARF5=y/' \
		-e 's/# CONFIG_OVERLAY_FS is not set/CONFIG_OVERLAY_FS=y/' \
		-e 's/# CONFIG_SQUASHFS is not set/CONFIG_SQUASHFS=y/'
	echo 'CONFIG_GDB_SCRIPTS=y' >> "$kernel_dir/.config"
	say Configuring kernel with olddefconfig...
	make -C "$kernel_dir" olddefconfig
fi
# really basic things...
config_check 64BIT BINFMT_ELF BINFMT_SCRIPT DEVTMPFS_MOUNT MULTIUSER PRINTK PROC_FS SERIAL_8250_CONSOLE SYSFS TMPFS_POSIX_ACL VIRTIO_BLK
# from https://wiki.qemu.org/Documentation/9psetup#Preparation
config_check NET_9P NET_9P_VIRTIO 9P_FS 9P_FS_POSIX_ACL PCI VIRTIO_PCI
# needed for our rootfs shenanigans
config_check OVERLAY_FS SQUASHFS
# stage2 dependencies
config_check E1000E FILE_LOCKING PACKET
# debugging niceties
config_check DEBUG_INFO_DWARF5 GDB_SCRIPTS
if [[ ! -f "$kernel_dir/arch/x86_64/boot/bzImage" ]]; then
	say Building kernel...
else
	say Rebuilding kernel...
fi
make -C "$kernel_dir" bzImage -j $(( "$(nproc)" * 3 / 2 )) -l "$(nproc)"

# Make a rootfs.
if [[ ! -f "$fs_dir/rootfs.tar.gz" || "$(sha256sum "$fs_dir/rootfs.tar.gz")" != "$ROOTFS_HASH  $fs_dir/rootfs.tar.gz" ]]; then
	say Downloading "$ROOTFS_URL..."
	curl -Lo "$fs_dir/rootfs.tar.gz" "$ROOTFS_URL"
fi
if [[ ! -e "$fs_dir/rootfs.squashfs" ]]; then
	say Creating root filesystem...
	zcat "$fs_dir/rootfs.tar.gz" | sqfstar "$fs_dir/rootfs.squashfs"
fi

# Create an "initial filesystem." Man, why am I so opposed to every init system
# that I consider this a reasonable alternative? And why am I not making an
# initramfs instead? Then I could use switch_root instead of chroot...
if [[ ! -e "$fs_dir/initfs.squashfs" ]]; then
	if [[ -f "$fs_dir/initfs.tar" ]]; then
		say Deleting the old initfs.tar...
		rm "$fs_dir/initfs.tar"
	fi

	say Creating files to add to the initial filesystem...
	tmp=$(mktemp -d)
	mkdir -p "$tmp/bin" "$tmp/dev" "$tmp/init" "$tmp/mnt/lower" "$tmp/mnt/root" \
		"$tmp/mnt/upper" "$tmp/usr/bin" "$tmp/usr/sbin"
	cat >"$tmp/init/stage1" <<EOF
#!/bin/sh
set -eux

mount -t squashfs /dev/vdb /mnt/lower
mount -t tmpfs    none     /mnt/upper

mkdir /mnt/upper/files /mnt/upper/work
mount -t overlay overlay /mnt/root -o lowerdir=/mnt/lower,upperdir=/mnt/upper/files,workdir=/mnt/upper/work

mount -t 9p       host /mnt/root/mnt -o trans=virtio,version=9p2000.L,msize=128M
mount --move      /dev /mnt/root/dev
mount -t proc     none /mnt/root/proc
mount -t sysfs    none /mnt/root/sys

install /init/stage2 /mnt/root/init
exec chroot /mnt/root /init
EOF
	cat >"$tmp/init/stage2" <<EOF
#!/bin/sh
set -eu

printf "Booted to \e[1;31ms\e[32mt\e[33ma\e[34mg\e[35me\e[36m2\e[0m!\n"

(
set -x
hostname '$(whoami)-vm'
ip link set dev eth0 up
udhcpc
passwd -d root
)

printf "\n\e[1;32mWelcome!\e[0m You can log in as \e[1mroot\e[0m with \e[1mno password\e[0m.\n"
printf "\n\e[1;96mWant gcc, vim, or bash?\e[0m Try running \e[1mapk add vim\e[0m!\n"
printf "\n\e[1;96mLooking for your files?\e[0m Try running \e[1mcd /mnt\e[0m!\n"
printf "\n\e[1;96mTrying to exit the VM?\e[0m  Try hitting \e[1mCtrl-a\e[0m, then \e[1mx\e[0m!\n"
while true; do
	getty 0 /dev/ttyS0
done
EOF
	chmod +x "$tmp/init/stage1"
	tar -xC "$tmp" -zf "$fs_dir/rootfs.tar.gz" \
		./bin/busybox \
		./bin/mkdir \
		./bin/mount \
		./bin/sh \
		./usr/bin/install \
		./usr/sbin/chroot \
		./lib/ld-musl-x86_64.so.1
	tar -cC "$tmp" -f "$fs_dir/initfs.tar" .
	rm -r "$tmp"

	say Creating initial filesystem...
	sqfstar "$fs_dir/initfs.squashfs" < "$fs_dir/initfs.tar"
fi

# Launch the VM.
say Running QEMU...
qemu-system-x86_64 \
	-kernel "$kernel_dir/arch/x86_64/boot/bzImage" \
	-append "console=ttyS0 root=/dev/vda init=/init/stage1 nokaslr" \
	-M q35 \
	-m 512M \
	-accel kvm \
	-cpu host \
	-drive file="$fs_dir/initfs.squashfs",if=virtio,index=0,format=raw,read-only=on \
	-drive file="$fs_dir/rootfs.squashfs",if=virtio,index=1,format=raw,read-only=on \
	-nographic \
	-virtfs local,path=.,mount_tag=host,security_model=mapped,multidevs=remap \
	"$@"
