#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Native armhf-on-aarch64 acceleration.
#
# Activate with ENABLE_EXTENSIONS=native-armhf-on-arm64.
#
# WHAT
#   On an aarch64 host building an armhf target, disable qemu-arm in
#   binfmt_misc for the duration of the build. The kernel's binfmt_elf
#   path then runs armhf ELF binaries natively via CONFIG_COMPAT — ~10×
#   faster than qemu-user-static emulation. mmdebstrap, chroot apt-get,
#   dpkg --configure, post-install scripts and customize_image all
#   benefit.
#
# REQUIREMENTS
#   * Host architecture aarch64.
#   * Host kernel with CONFIG_COMPAT=y (32-bit ARM EL0 support).
#     CONFIG_COMPAT_VDSO is not strictly required — full mmdebstrap +
#     post-customize runs were validated on stock Ubuntu Noble (6.8.x)
#     without COMPAT_VDSO.
#   * Build target ARCH=armhf (a no-op for any other ARCH).
#   * qemu-user-static (or qemu-user-binfmt) registered with qemu-arm
#     enabled in /proc/sys/fs/binfmt_misc/qemu-arm at build start.
#     The extension verifies this and refuses to run otherwise.
#   * CAP_SYS_ADMIN on host (the build already runs as root).
#
# RESTRICTIONS
#   * NO CONCURRENT ARMBIAN BUILDS on the same host while this extension
#     is active. The extension globally disables qemu-arm in binfmt_misc
#     for the build window. Any other parallel armhf-cross workload on
#     the host (CI runners, container builds depending on qemu-arm) will
#     have its armhf binaries routed through the kernel's binfmt_elf
#     fallback instead of qemu — which works on this host, but may
#     surprise code that depends on qemu being in the chain.
#     The operator owns the host while this extension runs.
#   * If the build is SIGKILL'd or the box crashes before the cleanup
#     handler fires, qemu-arm stays disabled. Re-enable manually:
#         sudo update-binfmts --enable qemu-arm
#     or
#         echo 1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-arm
#
# DESIGN
#   No flock dance, no userspace coordination, no concurrent-safety
#   claims. The acceleration is mechanically simple: write 0 to the
#   binfmt_misc entry, write 1 back on cleanup. The in-core flock-based
#   variant lives at PR #9769 if you need acceleration that coexists
#   with concurrent armbian builds on the same host.

function host_binfmt_ready__native_armhf_on_arm64() {
	# Self-gate: target arch must be armhf and host arch must be aarch64.
	# Anything else: no-op, silent — the extension only accelerates the
	# armhf-on-aarch64 case.
	[[ "${ARCH}" == "armhf" ]] || return 0

	declare host_arch
	host_arch="$(arch)"
	[[ "${host_arch}" == "aarch64" ]] || return 0

	# Gate on NEEDS_BINFMT. prepare_host_binfmt_qemu (which runs just before
	# this hook) returns early when NEEDS_BINFMT != yes — that's the case
	# for artifact-only commands like `compile.sh kernel ...` and
	# `compile.sh uboot ...` which never enter an armhf chroot. Without
	# this gate we would needlessly abort (qemu-arm not registered) or, on
	# a host where someone else already set it up, disable host-wide
	# qemu-arm for a build that doesn't even need it. See codex P2 on
	# PR #115.
	[[ "${NEEDS_BINFMT:-no}" == "yes" ]] || return 0

	if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
		exit_with_error "native-armhf-on-arm64: qemu-arm is not registered in binfmt_misc on the host even after prepare_host_binfmt_qemu ran — this is unexpected. Aborting."
	fi

	declare qemu_arm_state
	qemu_arm_state="$(head -n1 /proc/sys/fs/binfmt_misc/qemu-arm 2> /dev/null || true)"
	if [[ "${qemu_arm_state}" != "enabled" ]]; then
		display_alert "native-armhf-on-arm64: qemu-arm already not enabled" "state='${qemu_arm_state}' — nothing to do, leaving alone" "info"
		return 0
	fi

	# Probe-with-rollback: disable qemu-arm, verify the kernel can still
	# run armhf binaries natively via binfmt_elf (CONFIG_COMPAT), and
	# re-enable + bail if it can't. We probe by directly exec'ing an
	# armhf binary (ld-linux-armhf from gcc-arm-linux-gnueabihf, an
	# armbian build dependency on aarch64 hosts). `arch-test armhf` is
	# unreliable here — on Hetzner Ampere CAX (Ubuntu Noble 6.8) it
	# returns failure even when CONFIG_COMPAT is fully functional.
	declare armhf_probe="/usr/arm-linux-gnueabihf/lib/ld-linux-armhf.so.3"
	if [[ ! -x "${armhf_probe}" ]]; then
		exit_with_error "native-armhf-on-arm64: armhf probe binary not found at ${armhf_probe}; install gcc-arm-linux-gnueabihf (armbian's host deps already include it) and retry."
	fi

	display_alert "native-armhf-on-arm64: disabling qemu-arm" "/proc/sys/fs/binfmt_misc/qemu-arm → 0" "info"
	if ! echo 0 > /proc/sys/fs/binfmt_misc/qemu-arm 2> /dev/null; then
		exit_with_error "native-armhf-on-arm64: cannot write to /proc/sys/fs/binfmt_misc/qemu-arm. CAP_SYS_ADMIN missing on host?"
	fi

	if ! "${armhf_probe}" --help > /dev/null 2>&1; then
		echo 1 > /proc/sys/fs/binfmt_misc/qemu-arm 2> /dev/null || true
		exit_with_error "native-armhf-on-arm64: host kernel cannot run armhf natively after disabling qemu-arm (no CONFIG_COMPAT?). Restored qemu-arm and aborting; disable this extension on this host."
	fi

	declare -g _NATIVE_ARMHF_EXTENSION_DISABLED_QEMU_ARM=yes
	add_cleanup_handler trap_handler_native_armhf_on_arm64_restore
	display_alert "native-armhf-on-arm64: armhf chroot execs will run natively via kernel binfmt_elf" "qemu-arm disabled for this build; will be restored on exit" "info"
}

function trap_handler_native_armhf_on_arm64_restore() {
	[[ "${_NATIVE_ARMHF_EXTENSION_DISABLED_QEMU_ARM:-no}" == "yes" ]] || return 0
	[[ -e /proc/sys/fs/binfmt_misc/qemu-arm ]] || return 0
	if echo 1 > /proc/sys/fs/binfmt_misc/qemu-arm 2> /dev/null; then
		display_alert "native-armhf-on-arm64: qemu-arm restored" "/proc/sys/fs/binfmt_misc/qemu-arm → 1" "info"
	else
		display_alert "native-armhf-on-arm64: failed to restore qemu-arm" "manual fix: echo 1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-arm" "wrn"
	fi
	unset _NATIVE_ARMHF_EXTENSION_DISABLED_QEMU_ARM
}
