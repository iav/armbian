#!/usr/bin/env bash
# @description Makes kdump work out of the box: builds the kernel with kexec and crash dump support, installs `kdump-tools`, `kexec-tools` and `makedumpfile`, reserves memory with `crashkernel=` in `armbianEnv.txt` and configures kdump-tools so a panic leaves a compressed vmcore in `/var/crash`; keeps the kernel log of a panic, and the console output before a watchdog reset, in RAM (ramoops). Pair it with `KERNEL_DBG_PACKAGE=yes` to get the matching `vmlinux` for `crash` or `drgn`.

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
#   KDUMP_RAMOOPS       yes: keep the kernel log in 2 MiB of RAM reserved with
#                       reserve_mem=, see /var/lib/systemd/pstore after the
#                       next boot. Default: yes
#
# Only boards that boot through armbianEnv.txt get crashkernel= and the ramoops
# arguments automatically; elsewhere add them to the kernel command line by hand.
#
# ramoops keeps the whole kernel log on a panic or an oops. Without one, as
# when the watchdog resets a hung board, only the console record survives, and
# it holds just what passes the console loglevel: next to nothing at loglevel=1.
#
# The crash kernel command line is built on the board each time kdump-tools
# loads it: the running command line without what a crash kernel must not
# repeat (crashkernel=, ramoops, kgdboc=, splash, display consoles), plus a
# single CPU, a serial earlycon and no CMA.
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
# - The default KDUMP_CRASHKERNEL reserves nothing below 1 GiB of RAM, so
#   kdump-tools loads no crash kernel on such a board.
# - ramoops needs reserve_mem=, which Linux has from 6.11 on.

function extension_prepare_config__kdump() {
	case "${ARCH}" in
		arm64 | armhf | amd64) ;;
		*) exit_with_error "${EXTENSION}: Debian has no kdump-tools package for ${ARCH}" "${BOARD}" ;;
	esac
	declare -g KDUMP_CRASHKERNEL="${KDUMP_CRASHKERNEL:-1G-2G:256M,2G-:512M}"
	if [[ -z "${KDUMP_CRASHKERNEL}" || "${KDUMP_CRASHKERNEL}" =~ [[:space:]] ]]; then
		exit_with_error "${EXTENSION}: KDUMP_CRASHKERNEL must be a single crashkernel= value" "'${KDUMP_CRASHKERNEL}'"
	fi
	declare -g KDUMP_RAMOOPS="${KDUMP_RAMOOPS:-yes}"
	if [[ "${KDUMP_RAMOOPS}" == "yes" ]] && ! linux-version compare "${KERNEL_MAJOR_MINOR}" ge 6.11; then
		display_alert "${EXTENSION}: no ramoops" "kernel ${KERNEL_MAJOR_MINOR} has no reserve_mem=, it came in 6.11" "wrn"
		KDUMP_RAMOOPS="no"
	fi
	declare -g KDUMP_KERNEL_ARGS="crashkernel=${KDUMP_CRASHKERNEL}"
	case "${KDUMP_RAMOOPS}" in
		yes) KDUMP_KERNEL_ARGS+=" reserve_mem=2M:4096:ramoops ramoops.mem_name=ramoops ramoops.console_size=1048576 ramoops.record_size=131072" ;;
		no) ;;
		*) exit_with_error "${EXTENSION}: KDUMP_RAMOOPS must be yes or no" "'${KDUMP_RAMOOPS}'" ;;
	esac
	if [[ "${SRC_EXTLINUX}" == "yes" ]]; then
		display_alert "${EXTENSION}: extlinux boot" "add '${KDUMP_KERNEL_ARGS}' to the kernel command line by hand" "wrn"
	fi
	add_packages_to_image kdump-tools kexec-tools makedumpfile
	if [[ "${LINUXFAMILY}" == "meson64" ]]; then
		add_packages_to_image device-tree-compiler # fdtput for the SM1 crash device tree
	fi
	display_alert "${EXTENSION}: kernel command line" "${KDUMP_KERNEL_ARGS}" "info"
}

function custom_kernel_config__kdump() {
	# kexec-tools reads PHYS_OFFSET and _text from /proc/kcore and /proc/kallsyms
	# to build the vmcore header.
	opts_y+=("KEXEC" "KEXEC_FILE" "CRASH_DUMP" "PROC_VMCORE" "PROC_KCORE" "KALLSYMS_ALL")
	# Build these in whatever KDUMP_RAMOOPS says: the kernel artifact must not depend on
	# it, and without a device tree node nothing loads a ramoops module.
	opts_y+=("PSTORE" "PSTORE_RAM" "PSTORE_CONSOLE")
	display_alert "${EXTENSION}: kernel" "kexec, crash dump, /proc/vmcore, ramoops" "info"
}

function image_specific_armbian_env_ready__kdump_kernel_args() {
	declare env_file="${SDCARD}/boot/armbianEnv.txt"
	# U-Boot keeps the last extraargs= line only, so extend the existing one.
	if grep -q '^extraargs=' "${env_file}"; then
		sed -i "s|^extraargs=.*|& ${KDUMP_KERNEL_ARGS}|" "${env_file}"
	else
		echo "extraargs=${KDUMP_KERNEL_ARGS}" >> "${env_file}"
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
				crashkernel=* | crash_kexec_post_notifiers | reserve_mem=* | ramoops.* | kgdboc=* | kgdbwait | memtest=* | splash | splash=* | quiet | console=tty[0-9]*) ;;
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

	declare kdump_append="reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 earlycon cma=0 loglevel=7 panic=10"
	# Debian adds irqpoll everywhere except arm64. We leave out its usbcore.nousb:
	# a crash kernel without USB cannot write the dump to a root file system on USB.
	if [[ "${ARCH}" != "arm64" ]]; then
		kdump_append+=" irqpoll"
	fi

	cat <<- 'EOF' >> "${SDCARD}/etc/default/kdump-tools"

		# Armbian kdump extension
		USE_KDUMP=1
		KDUMP_COREDIR="/var/crash"
		KDUMP_FAIL_CMD="reboot -f"
		MAKEDUMP_ARGS="-c -d 31"
		KDUMP_CMDLINE="$(/usr/lib/armbian/kdump-cmdline)"
		KDUMP_KEXEC_ARGS="$(/usr/lib/armbian/kdump-kexec-args)"
	EOF
	echo "KDUMP_CMDLINE_APPEND=\"${kdump_append}\"" >> "${SDCARD}/etc/default/kdump-tools"

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/kdump-tools-dump.service.d/armbian.conf"
		[Unit]
		FailureAction=reboot-force

		[Service]
		TimeoutStartSec=300
	EOF

	if [[ "${KDUMP_RAMOOPS}" == "yes" ]]; then
		# systemd-pstore saves the console record under the same name every time;
		# date the previous one so the next boot does not overwrite it.
		mkdir -p "${SDCARD}/etc/systemd/system/systemd-pstore.service.d"
		cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/systemd-pstore.service.d/armbian-kdump.conf"
			[Service]
			ExecStartPre=/bin/sh -c 'for f in /var/lib/systemd/pstore/console-ramoops-[0-9]; do [ -f "$$f" ] && mv "$$f" "$$f.$$(date -r "$$f" +%%Y%%m%%d-%%H%%M%%S)"; done; true'
		EOF
	fi

	chroot_sdcard systemctl enable kdump-tools.service
}
