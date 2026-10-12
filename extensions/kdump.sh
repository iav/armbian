#!/usr/bin/env bash
# @description Makes kdump work out of the box: builds the kernel with kexec and crash dump support, installs `kdump-tools`, `kexec-tools` and `makedumpfile`, reserves memory with `crashkernel=` in `armbianEnv.txt` and configures kdump-tools so a panic leaves a compressed vmcore in `/var/crash`. Pair it with `KERNEL_DBG_PACKAGE=yes` to get the matching `vmlinux` for `crash` or `drgn`.

#
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2026 Igor Velkov
# This file is a part of the Armbian Build Framework https://github.com/armbian/build/
#
# Enable with: ENABLE_EXTENSIONS="kdump"
#
# Variables:
#   KDUMP_CRASHKERNEL   Memory to reserve for the crash kernel, in kernel
#                       crashkernel= syntax. Default: 1G-2G:256M,2G-:512M
#
# Only boards that boot through armbianEnv.txt get crashkernel= automatically;
# elsewhere add it to the kernel command line by hand.
#
# The crash kernel command line is built on the board each time kdump-tools
# loads it: the running command line without what a crash kernel must not
# repeat (crashkernel=, kgdboc=, splash, display consoles), plus a single CPU,
# a serial earlycon and no CMA.
#
# Limits:
# - On boards whose PMIC sits behind a slow bus (RK8xx over I2C) the panicking
#   kernel may hang before kexec; see the "genirq/kexec" patch on LKML.
# - After a PCIe link failure the panicking kernel may hang while it masks the
#   root port's MSI.
# - A hardware watchdog keeps counting; the crash kernel has to start before it
#   fires.
# - makedumpfile from the distribution may not know a newer kernel; it still
#   writes a dump, with a warning.

function extension_prepare_config__kdump() {
	declare -g KDUMP_CRASHKERNEL="${KDUMP_CRASHKERNEL:-1G-2G:256M,2G-:512M}"
	if [[ -z "${KDUMP_CRASHKERNEL}" || "${KDUMP_CRASHKERNEL}" =~ [[:space:]] ]]; then
		exit_with_error "${EXTENSION}: KDUMP_CRASHKERNEL must be a single crashkernel= value" "'${KDUMP_CRASHKERNEL}'"
	fi
	if [[ "${SRC_EXTLINUX}" == "yes" ]]; then
		display_alert "${EXTENSION}: extlinux boot" "add crashkernel=${KDUMP_CRASHKERNEL} to the kernel command line by hand" "wrn"
	fi
	add_packages_to_image kdump-tools kexec-tools makedumpfile
	if [[ "${LINUXFAMILY}" == "meson64" ]]; then
		add_packages_to_image device-tree-compiler # fdtput for the SM1 crash device tree
	fi
	display_alert "${EXTENSION}: crash kernel reservation" "crashkernel=${KDUMP_CRASHKERNEL}" "info"
}

function custom_kernel_config__kdump() {
	# kexec-tools reads PHYS_OFFSET and _text from /proc/kcore and /proc/kallsyms
	# to build the vmcore header.
	opts_y+=("KEXEC" "KEXEC_FILE" "CRASH_DUMP" "PROC_VMCORE" "PROC_KCORE" "KALLSYMS_ALL")
	display_alert "${EXTENSION}: kernel" "kexec, crash dump, /proc/vmcore" "info"
}

function image_specific_armbian_env_ready__kdump_crashkernel() {
	declare env_file="${SDCARD}/boot/armbianEnv.txt"
	# U-Boot keeps the last extraargs= line only, so extend the existing one.
	if grep -q '^extraargs=' "${env_file}"; then
		sed -i "s|^extraargs=.*|& crashkernel=${KDUMP_CRASHKERNEL}|" "${env_file}"
	else
		echo "extraargs=crashkernel=${KDUMP_CRASHKERNEL}" >> "${env_file}"
	fi
	display_alert "${EXTENSION}: armbianEnv.txt" "$(grep '^extraargs=' "${env_file}")" "info"
}

function post_customize_image__kdump_tools_config() {
	display_alert "${EXTENSION}: configuring kdump-tools" "${BOARD}" "info"
	mkdir -p "${SDCARD}/usr/lib/armbian" "${SDCARD}/etc/systemd/system/kdump-tools-dump.service.d"

	cat <<- 'EOF' > "${SDCARD}/usr/lib/armbian/kdump-cmdline"
		#!/bin/sh
		# Print the running kernel command line without what a crash kernel must not repeat.
		for arg in $(cat /proc/cmdline); do
			case "${arg}" in
				crashkernel=* | crash_kexec_post_notifiers | kgdboc=* | kgdbwait | memtest=* | splash | splash=* | quiet | console=tty[0-9]*) ;;
				*) printf '%s ' "${arg}" ;;
			esac
		done
	EOF

	cat <<- 'EOF' > "${SDCARD}/usr/lib/armbian/kdump-kexec-args"
		#!/bin/sh
		# SM1 device trees number the cores 0-3, the hardware reports MPIDR 0x000-0x300:
		# a crash kernel started on core 1-3 would not find its own CPU node.
		tr '\0' '\n' < /proc/device-tree/compatible 2> /dev/null | grep -qx 'amlogic,sm1' || exit 0
		dtb=/var/lib/kdump/crash.dtb
		cp /sys/firmware/fdt "${dtb}" || exit 0
		for n in 1 2 3; do
			fdtput -t x "${dtb}" "/cpus/cpu@${n}" reg 0 "${n}00" || exit 0
		done
		echo "--dtb=${dtb}"
	EOF
	chmod 755 "${SDCARD}/usr/lib/armbian/kdump-cmdline" "${SDCARD}/usr/lib/armbian/kdump-kexec-args"

	cat <<- 'EOF' >> "${SDCARD}/etc/default/kdump-tools"

		# Armbian kdump extension
		USE_KDUMP=1
		KDUMP_COREDIR="/var/crash"
		KDUMP_FAIL_CMD="reboot -f"
		MAKEDUMP_ARGS="-d 31"
		KDUMP_CMDLINE="$(/usr/lib/armbian/kdump-cmdline)"
		KDUMP_CMDLINE_APPEND="reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 earlycon cma=0 loglevel=7 panic=10"
		KDUMP_KEXEC_ARGS="$(/usr/lib/armbian/kdump-kexec-args)"
	EOF

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/kdump-tools-dump.service.d/armbian.conf"
		[Unit]
		FailureAction=reboot-force

		[Service]
		TimeoutStartSec=300
	EOF

	chroot_sdcard systemctl enable kdump-tools.service
}
