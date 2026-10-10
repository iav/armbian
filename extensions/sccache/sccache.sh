# shellcheck shell=bash
#
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2013-2026 Igor Pecovnik, igor@armbian.com
# This file is a part of the Armbian Build Framework https://github.com/armbian/build/
#
# Compile-cache backend: sccache (https://github.com/mozilla/sccache).
#
# Wraps compiler invocations for kernel / u-boot / ATF / Crust through the
# `sccache` binary. Same wiring shape as extensions/ccache.sh — it implements
# compile_prepare_vars (env exports), compile_wrapper_pre/_post (stats), and
# per-artifact *_make_config hooks that point the `env -i` make environments
# at the saved sccache environment.
#
# The backend is whatever the SCCACHE_* environment selects, as documented by
# sccache; the default is the local disk under ${SRC}/cache/sccache.
#
# Enable explicitly via ENABLE_EXTENSIONS=sccache; the legacy USE_CCACHE
# toggle enables no backend.
#
# Mutually exclusive with extensions/ccache.sh: each backend registers in
# COMPILE_CACHE_BACKENDS and core rejects more than one.

# Defaults — overridable via env at compile.sh invocation time.
# sccache's own default cache size is 10G; 5G is comfortable for
# kernel+u-boot+ATF turns on a CAX21-class builder without hogging the
# project cache disk.
declare -g SCCACHE_PIN_VERSION="${SCCACHE_PIN_VERSION:-v0.18.0}"
# SCCACHE_CACHE_SIZE default is applied later in compile_prepare_vars__sccache
# (lib.config / user_config / extension_prepare_config can set COMPILE_CACHE_SIZE
# between extension source time and compile time; resolving at source time would
# freeze the default before those override points run).

# SHA256 table for the pinned version's prebuilt musl tarballs. Keyed by
# the rust target triple slug used in the GitHub release filename. If
# SCCACHE_PIN_VERSION is overridden, the bootstrap step will accept the
# user-provided SCCACHE_SHA256_<TRIPLE> env override instead.
declare -g -A __ext_sccache_sha256=(
	["x86_64-unknown-linux-musl"]="45f1447fbe231e3037bde351ef70677dd212216c8d62ae7ca409fecc4d6acc89"
	["aarch64-unknown-linux-musl"]="2b3284d5da3b46a47dc4229e75bb7b88ac4aa99c8d754fb7d2f84997e5a4354a"
	["armv7-unknown-linux-musleabi"]="5e1b69e95cee1b19f0d0669eb1b1597f51770fc602e4321adfea99143cac6ce9"
	["i686-unknown-linux-musl"]="e23e961b549c3c40ac0d504e0d4a63a5da2ef1b44ac253c55bef55e755fdf340"
	["riscv64gc-unknown-linux-musl"]="ee204961bae9c7033971a7a65e93e66431c8e2ca4af9123330ac3e94afacd4de"
	["loongarch64-unknown-linux-musl"]="2c165dd599675a31be5d0e100e8df2bb22919d75ac711f9060acd96fcb7c6626"
	["s390x-unknown-linux-musl"]="c7e532bc7f2e6e1f27c9087172a95faf3b85672256775fde3e8cf26d9934f4fe"
)

# Prefixes of what sccache reads (docs/Configuration.md): its own settings, the
# S3, Azure, OSS and COS credentials, and the GitHub Actions cache runtime.
declare -g -a __ext_sccache_env_prefixes=(SCCACHE_ AWS_ ACTIONS_ AZURE_ ALIBABA_CLOUD_ TENCENTCLOUD_)

function _ext_sccache_env_vars() {
	local prefix var
	for prefix in "${__ext_sccache_env_prefixes[@]}"; do
		for var in $(compgen -v "${prefix}"); do
			[[ -n "${!var}" ]] && echo "${var}"
		done
	done
	return 0
}

# `env -i make` drops the environment, so the shim restores it from this file.
# Rewritten whenever the extension changes a variable.
function _ext_sccache_write_env_file() {
	mkdir -p "${WORKDIR}"
	export ARMBIAN_SCCACHE_ENV="${WORKDIR}/sccache.env"
	local var val tmp
	tmp="$(mktemp "${ARMBIAN_SCCACHE_ENV}.XXXXXX")"
	for var in $(_ext_sccache_env_vars); do
		val="${!var}"
		printf "export %s='%s'\n" "${var}" "${val//\'/\'\\\'\'}"
	done > "${tmp}"
	mv -f "${tmp}" "${ARMBIAN_SCCACHE_ENV}"
}

# Set address variables, whose loopback host must become host.docker.internal in Docker.
function _ext_sccache_endpoint_vars() {
	local var
	for var in $(_ext_sccache_env_vars); do
		case "${var}" in
			*ENDPOINT* | *_URL | SCCACHE_REDIS | SCCACHE_MEMCACHED) echo "${var}" ;;
		esac
	done
	return 0
}

function extension_prepare_config__sccache() {
	_ext_sccache_bootstrap_binary
}

# Download + verify the pinned sccache binary into cache/tools/sccache/,
# and overlay it with a thin shim — both named "sccache". The real binary
# stays in the versioned ${bin_dir}; the shim lives in ${bin_dir}/shim (added
# to PATH) and references it by absolute path. Idempotent: fast path skips
# when both files are in place.
#
# Naming: the shim's filename MUST be "sccache" (not "sccache-wrap" or
# similar). The u-boot top-level Makefile parses CROSS_COMPILE with a
# sed expression that matches optional "<word>ccache <space>" before the
# target prefix; a dash in the wrapper name pollutes that capture group
# and breaks MK_ARCH/HOST_ARCH detection (lib/efi_loader breaks with
# "operator '==' has no left operand" / #error Unsupported Host
# architecture). See u-boot Makefile lines ~230-245.
function _ext_sccache_bootstrap_binary() {
	local ver="${SCCACHE_PIN_VERSION}"
	local triple
	triple="$(_ext_sccache_host_triple)" || {
		display_alert "${EXTENSION}: unsupported host arch" "$(uname -m) — sccache not available" "wrn"
		return 1
	}

	local tools_dir="${SRC}/cache/tools/sccache"
	local bin_dir="${tools_dir}/sccache-${ver}-${triple}"
	local real="${bin_dir}/sccache"
	# Per version, so concurrent builds on different pins keep their own shim.
	local shim_dir="${bin_dir}/shim"
	local shim="${shim_dir}/sccache"

	declare -g __ext_sccache_bin_dir="${shim_dir}"

	mkdir -p "${tools_dir}" "${shim_dir}"
	_ext_sccache_write_cachedir_tag "${tools_dir}"

	# Fast path: both files present and shim still references this real binary.
	if [[ -x "${real}" && -x "${shim}" ]] && grep -q "REAL=${real}" "${shim}" 2> /dev/null &&
		grep -q ARMBIAN_SCCACHE_ENV "${shim}" 2> /dev/null; then
		display_alert "${EXTENSION}: cached sccache binary" "${ver} (${triple})" "cachehit"
		return 0
	fi

	if [[ "${OFFLINE_WORK}" == "yes" && ! -x "${real}" ]]; then
		exit_with_error "${EXTENSION}: cannot bootstrap sccache" \
			"OFFLINE_WORK=yes but binary missing at ${real} — run once online or pre-seed cache/tools/sccache/"
	fi

	if [[ ! -x "${real}" ]]; then
		# Allow per-version SHA override (env), else look up in the pinned table.
		local sha
		local override_var="SCCACHE_SHA256_${triple//-/_}"
		sha="${!override_var:-${__ext_sccache_sha256[${triple}]:-}}"
		if [[ -z "${sha}" ]]; then
			exit_with_error "${EXTENSION}: no SHA256 known for sccache ${ver} ${triple}" \
				"set ${override_var}=<sha256> or use the pinned SCCACHE_PIN_VERSION"
		fi

		mkdir -p "${bin_dir}"
		local url="https://github.com/mozilla/sccache/releases/download/${ver}/sccache-${ver}-${triple}.tar.gz"
		# A private scratch dir per build and an atomic rename into place, so
		# concurrent first-time builds never read each other's partial files.
		local tmp
		tmp="$(mktemp -d "${bin_dir}/.download-XXXXXX")"
		local tarball="${tmp}/sccache.tar.gz"

		display_alert "${EXTENSION}: downloading sccache" "${ver} (${triple})" "info"
		run_host_command_logged curl --fail --location --silent --show-error --output "${tarball}" "${url}" ||
			{
				rm -rf "${tmp}"
				exit_with_error "${EXTENSION}: failed to download" "${url}"
			}

		local got
		got="$(sha256sum "${tarball}" | awk '{print $1}')"
		if [[ "${got}" != "${sha}" ]]; then
			rm -rf "${tmp}"
			exit_with_error "${EXTENSION}: SHA256 mismatch" "expected ${sha}, got ${got}"
		fi

		run_host_command_logged tar -xzf "${tarball}" -C "${tmp}" --strip-components=1 "sccache-${ver}-${triple}/sccache" ||
			{
				rm -rf "${tmp}"
				exit_with_error "${EXTENSION}: tar extract failed" "${tarball}"
			}
		chmod +x "${tmp}/sccache"
		mv -f "${tmp}/sccache" "${real}"
		rm -rf "${tmp}"
	fi

	_ext_sccache_write_shim "${shim}" "${real}"
	display_alert "${EXTENSION}: installed sccache" "${ver} (${triple})" "ext"
}

# Concurrent builds share the shim and wrappers; a rename never exposes a half-written script.
function _ext_sccache_install_script() {
	local dst="$1" tmp
	tmp="$(mktemp "${dst}.XXXXXX")"
	cat > "${tmp}"
	chmod 0755 "${tmp}"
	mv -f "${tmp}" "${dst}"
}

# Emit the in-tree sccache shim. sccache rejects unknown tools (ld, ar,
# nm, strip, objcopy, ranlib …) with non-zero exit — kernel/u-boot
# Makefiles expand CROSS_COMPILE='sccache <prefix>-' into LD/AR/STRIP/…
# invocations which then abort the build. ccache silently passes those
# through; the shim emulates that by routing only real compiler
# invocations through the real sccache binary and exec'ing everything
# else directly.
function _ext_sccache_write_shim() {
	local shim="$1" real="$2"
	_ext_sccache_install_script "${shim}" <<- SCCACHE_SHIM
		#!/bin/sh
		# Auto-generated by extensions/sccache.sh — do not edit.
		# REAL=${real}
		[ -r "\${ARMBIAN_SCCACHE_ENV:-}" ] && . "\${ARMBIAN_SCCACHE_ENV}"
		# Routes flags + compiler calls to sccache; exec's binutils
		# (ld/ar/nm/strip/etc.) directly — bare sccache rejects them
		# with "Compiler not supported", aborting kbuild/u-boot when
		# CROSS_COMPILE='sccache <prefix>-' expands LD/AR/STRIP/…
		case "\$1" in
		    -*) exec "${real}" "\$@" ;;
		esac
		b=\${1##*/}
		case "\$b" in
		    *-gcc | *-g++ | *-cc | *-c++ | *-clang | *-clang++ \\
		        | gcc | g++ | cc | c++ | clang | clang++ | rustc)
		        exec "${real}" "\$@" ;;
		    *)
		        exec "\$@" ;;
		esac
	SCCACHE_SHIM
}

# HOSTCC/HOSTCXX in kernel and u-boot are bare gcc/g++, outside CROSS_COMPILE;
# ccache catches them via /usr/lib/ccache, these wrappers in front of PATH likewise.
function _ext_sccache_write_host_cc_wrappers() {
	local dir="$1" name real
	for name in gcc g++ cc c++; do
		real="$(PATH="${PATH//"${dir}:"/}" command -v "${name}")" || continue
		_ext_sccache_install_script "${dir}/${name}" <<- SCCACHE_HOST_CC
			#!/bin/sh
			# Auto-generated by extensions/sccache.sh — do not edit.
			exec "${dir}/sccache" "${real}" "\$@"
		SCCACHE_HOST_CC
	done
	return 0
}

# Write a Cache Directory Tagging Standard marker so tools like
# `tar --exclude-caches`, Borg, Restic, Duplicity, rsync filters and
# similar skip the directory during backups / archival. Spec:
# https://bford.info/cachedir/  — the first 43 bytes must be the exact
# `Signature: 8a477f597d28d172789f06886806bc55` line.
function _ext_sccache_write_cachedir_tag() {
	local dir="$1"
	local tag="${dir}/CACHEDIR.TAG"
	[[ -f "${tag}" ]] && return 0
	mkdir -p "${dir}"
	cat > "${tag}" <<- 'CACHEDIR_TAG'
		Signature: 8a477f597d28d172789f06886806bc55
		# This file is a cache directory tag created by the Armbian
		# sccache extension. For information about cache directory tags
		# see https://bford.info/cachedir/
	CACHEDIR_TAG
}

# Resolve `uname -m` to the rust target triple slug used in the sccache
# release filename. Returns non-zero (and emits nothing) for unsupported
# hosts, letting the caller fall back gracefully.
function _ext_sccache_host_triple() {
	case "$(uname -m)" in
		x86_64 | amd64) echo "x86_64-unknown-linux-musl" ;;
		aarch64 | arm64) echo "aarch64-unknown-linux-musl" ;;
		armv7l | armv7) echo "armv7-unknown-linux-musleabi" ;;
		i686 | i386) echo "i686-unknown-linux-musl" ;;
		riscv64) echo "riscv64gc-unknown-linux-musl" ;;
		loongarch64) echo "loongarch64-unknown-linux-musl" ;;
		s390x) echo "s390x-unknown-linux-musl" ;;
		*) return 1 ;;
	esac
}

# Main env setup. Runs from prepare_compilation_vars — late enough for
# extension config to settle, early enough for ${CCACHE} substitution
# inside run_*_make_internal to see the exported value.
function compile_prepare_vars__sccache() {
	COMPILE_CACHE_BACKENDS+=("sccache")

	# CCACHE substitutes into CROSS_COMPILE='${CCACHE} <prefix>-' at the
	# kernel/u-boot/atf/crust call sites. The "sccache" name is also
	# special-cased by u-boot's HOST_ARCH detection regex (matches
	# `.*ccache <space>`), so we keep the shim filename literally
	# "sccache" — _ext_sccache_write_shim handles the ld/ar/etc.
	# passthrough that the bare upstream binary can't do.
	export CCACHE="sccache"
	if [[ -n "${__ext_sccache_bin_dir}" ]]; then
		_ext_sccache_write_host_cc_wrappers "${__ext_sccache_bin_dir}"
		export PATH="${__ext_sccache_bin_dir}:${PATH}"
	fi

	# apply_cmdline_params_to_env stores CLI `KEY=value` overrides as plain
	# shell variables, not exported environment — so a child sccache process
	# launched here (the probe, plus ATF/Crust make in the host shell) would
	# never see them. Promote every configured backend var to an export now
	# so probe and host-shell builds see the same config as the docker side.
	local var
	for var in $(_ext_sccache_env_vars); do
		export "${var?}"
	done

	# The container applies config and CLI values again, so loopback endpoints
	# are rewritten here; the host hook only adds the host-gateway mapping.
	if [[ "${ARMBIAN_RUNNING_IN_CONTAINER}" == "yes" ]]; then
		for var in $(_ext_sccache_endpoint_vars); do
			_ext_sccache_rewrite_loopback "${var}" || true
		done
	fi

	# sccache 0.18 with basedirs and the preprocessor cache can hand out an
	# object built against another checkout's headers (mozilla/sccache#2863).
	if [[ -n "${SCCACHE_BASEDIRS}" && -z "${SCCACHE_DIRECT}" ]]; then
		export SCCACHE_DIRECT=false
		display_alert "${EXTENSION}: SCCACHE_BASEDIRS set" "preprocessor cache off (SCCACHE_DIRECT=false), see mozilla/sccache#2863" "wrn"
	fi

	# Default to a local-FS backend rooted in the project cache when the
	# user hasn't selected any remote backend. Mirrors ccache's
	# ${SRC}/cache/ccache default — keeps the cache on the same volume as
	# the build tree (XFS-friendly on cloud builders).
	if [[ -z "${SCCACHE_DIR}" ]] && ! _ext_sccache_remote_configured; then
		export SCCACHE_DIR="${COMPILE_CACHE_DIR:-${SRC}/cache/sccache}"
	fi
	# Backend-specific overrides backend-agnostic; agnostic overrides built-in
	# default. Resolved late so lib.config / user_config / extension_prepare_config
	# overrides of COMPILE_CACHE_SIZE are honored.
	export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-${COMPILE_CACHE_SIZE:-5G}}"
	# Tag local-FS cache so backup tools skip it. Upstream sccache does
	# not write CACHEDIR.TAG itself. No-op for remote backends (SCCACHE_DIR unset).
	if [[ -n "${SCCACHE_DIR}" ]]; then
		export SCCACHE_DIR
		_ext_sccache_write_cachedir_tag "${SCCACHE_DIR}"
	fi
	_ext_sccache_remote_configured || _ext_sccache_lock_local_cache
	_ext_sccache_write_env_file

	# Force a fresh daemon so it boots with the env we just exported. A
	# stale server from a previous build (different SCCACHE_DIR / backend /
	# project) would otherwise keep serving requests against the old
	# config and the new SCCACHE_* exports would silently take no effect.
	sccache --stop-server > /dev/null 2>&1 || true
	# No idle exit, so it lasts until the kernel build; stopped at build exit.
	SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-0}" sccache --start-server > /dev/null 2>&1 || true
	add_cleanup_handler _ext_sccache_stop_server

	# Probe remote backend reachability through sccache itself, falling
	# back to local-FS for the whole compilation if unreachable. Opt-out
	# via COMPILE_CACHE_SKIP_PROBE=yes (or SCCACHE_SKIP_PROBE=yes for
	# backend-specific override). When probing is disabled, no fallback
	# happens either — sccache just stays on the configured backend and
	# accumulates Cache write errors silently if the remote is down.
	if [[ "${COMPILE_CACHE_SKIP_PROBE}" != "yes" && "${SCCACHE_SKIP_PROBE}" != "yes" ]]; then
		_ext_sccache_probe_backend
	fi
}

function _ext_sccache_stop_server() {
	sccache --stop-server > /dev/null 2>&1 || true
}

# Same true values as sccache's bool_from_env_var.
function _ext_sccache_gha_configured() {
	[[ -n "${SCCACHE_GHA_VERSION}" ]] && return 0
	case "${SCCACHE_GHA_ENABLED,,}" in
		true | on | 1) return 0 ;;
	esac
	return 1
}

# Set variables that select a remote backend (docs/Configuration.md, "cache
# configs"); credentials alone select nothing.
function _ext_sccache_remote_vars() {
	local var
	for var in $(_ext_sccache_env_vars); do
		case "${var}" in
			SCCACHE_GHA_ENABLED) _ext_sccache_gha_configured && echo "${var}" ;;
			SCCACHE_BUCKET | SCCACHE_ENDPOINT | SCCACHE_REGION | SCCACHE_S3_* | SCCACHE_REDIS* | \
				SCCACHE_MEMCACHED* | SCCACHE_GCS_* | SCCACHE_AZURE_* | SCCACHE_GHA_* | SCCACHE_WEBDAV_* | \
				SCCACHE_OSS_* | SCCACHE_COS_* | SCCACHE_MULTILEVEL_*)
				echo "${var}"
				;;
		esac
	done
	return 0
}

function _ext_sccache_remote_configured() {
	[[ -n "$(_ext_sccache_remote_vars)" ]]
}

# sccache supports one server per local cache dir (docs/Local.md); concurrent
# builds on one host would race on it, so the later one waits. Held until exit.
function _ext_sccache_lock_local_cache() {
	[[ -n "${__ext_sccache_lock_fd:-}" ]] && return 0
	mkdir -p "${SCCACHE_DIR}"
	exec {__ext_sccache_lock_fd}> "${SCCACHE_DIR}/.armbian-build.lock" ||
		exit_with_error "${EXTENSION}: cannot open lock file" "${SCCACHE_DIR}/.armbian-build.lock"
	flock -n "${__ext_sccache_lock_fd}" && return 0

	display_alert "${EXTENSION}: local cache in use by another build" "waiting for ${SCCACHE_DIR}; a remote backend allows parallel builds" "wrn"
	local -i since=${SECONDS}
	until flock -w 60 "${__ext_sccache_lock_fd}"; do
		display_alert "${EXTENSION}: still waiting for the local cache" "$((SECONDS - since))s; Ctrl+C to abort" "info"
	done
	display_alert "${EXTENSION}: local cache lock obtained" "after $((SECONDS - since))s" "info"
}

# Compile a one-statement C file through sccache, then read its stats.
# If the trivial compile exits non-zero, or sccache reports any cache /
# write errors, use the local disk for the rest of the build: sccache
# 0.18 refuses to start its daemon when the startup check of the remote fails.
function _ext_sccache_probe_backend() {
	# Only probe when a remote backend is actually configured.
	_ext_sccache_remote_configured || return 0

	# Skip the host-cc wrappers in front of PATH: they would call sccache again.
	local cc probe_path="${PATH//"${__ext_sccache_bin_dir}:"/}"
	cc="$(PATH="${probe_path}" command -v cc 2> /dev/null || PATH="${probe_path}" command -v gcc 2> /dev/null || true)"
	if [[ -z "${cc}" ]]; then
		display_alert "${EXTENSION}: backend probe skipped" "no host C compiler in PATH" "wrn"
		return 0
	fi

	local probe_dir
	probe_dir="$(mktemp -d -t sccache-probe-XXXXXX)" || return 0
	local probe_c="${probe_dir}/probe.c"
	printf 'int main(void) { return 0; }\n' > "${probe_c}"

	sccache --zero-stats > /dev/null 2>&1 || true

	local probe_rc=0 probe_err
	probe_err="$(sccache "${cc}" -c "${probe_c}" -o "${probe_dir}/probe.o" 2>&1)" || probe_rc=$?

	# jq is a host build-dep (lib/functions/host/prepare-host.sh); if it
	# fails or is absent the pipe exits non-zero and errs defaults to 1
	# (probe-failed), so the local-FS fallback below triggers conservatively
	# instead of falsely treating an unverifiable remote as healthy.
	local errs
	errs="$(sccache --show-stats --stats-format=json 2> /dev/null |
		jq -r '([.stats.cache_errors.counts[]?] | add // 0) + (.stats.cache_write_errors // 0)' \
			2> /dev/null || echo 1)"

	rm -rf "${probe_dir}"
	sccache --zero-stats > /dev/null 2>&1 || true

	if ((probe_rc != 0)) || ((errs > 0)); then
		display_alert "${EXTENSION}: remote backend probe failed" \
			"falling back to local FS (rc=${probe_rc} errs=${errs})" "wrn"
		[[ -n "${probe_err}" ]] && display_alert "  probe stderr" "${probe_err}" "info"
		_ext_sccache_disable_remote
	else
		display_alert "${EXTENSION}: remote backend probe ok" "${EXTENSION}" "info"
	fi
}

# A chain of only the disk level makes sccache skip the configured remotes,
# whose variables stay as the user set them. The daemon restarts with it.
function _ext_sccache_disable_remote() {
	export SCCACHE_MULTILEVEL_CHAIN=disk
	export SCCACHE_DIR="${SCCACHE_DIR:-${COMPILE_CACHE_DIR:-${SRC}/cache/sccache}}"
	_ext_sccache_write_cachedir_tag "${SCCACHE_DIR}"
	_ext_sccache_write_env_file
	sccache --stop-server > /dev/null 2>&1 || true
	_ext_sccache_lock_local_cache
}

# Only the env file path crosses `env -i`; the values stay out of the logged make command.
function _ext_sccache_inject_envs() {
	local -n envs="$1"
	if [[ -n "${ARMBIAN_SCCACHE_ENV:-}" ]]; then
		envs+=("ARMBIAN_SCCACHE_ENV=${ARMBIAN_SCCACHE_ENV@Q}")
	fi
	return 0
}

function kernel_make_config__sccache() { _ext_sccache_inject_envs common_make_envs; }
function uboot_make_config__sccache() { _ext_sccache_inject_envs uboot_make_envs; }

# Wrap rustc when kernel-rust extension is active. kbuild's
# scripts/rust_is_available.sh validates RUSTC via `command -v
# "$RUSTC"`, which requires a single executable path — so a two-word
# value like `RUSTC='sccache /path/rustc'` fails detection during
# `make olddefconfig` and Kconfig drops CONFIG_RUST=y back to n,
# silently disabling all Rust kernel code. Instead, emit a thin
# shell wrapper at a stable path and point RUSTC at that single
# file. The wrapper exec's sccache + the real rustc. Hook name sorts
# after `__add_rust_compiler` alphabetically so kernel-rust's
# `RUSTC=${RUST_TOOL_RUSTC}` is overridden by this entry.
function custom_kernel_make_params__sccache_wrap_rustc() {
	if [[ -n "${RUST_TOOL_RUSTC:-}" && -n "${__ext_sccache_bin_dir:-}" ]]; then
		# One wrapper per rustc, so concurrent builds on different Rust versions keep theirs.
		local wrap
		wrap="${__ext_sccache_bin_dir}/sccache-rustc-$(echo "${RUST_TOOL_RUSTC}" | sha256sum | cut -c1-12)"
		_ext_sccache_install_script "${wrap}" <<- SCCACHE_RUSTC_WRAP
			#!/bin/sh
			# Auto-generated by extensions/sccache.sh — points RUSTC at a
			# single-file path so kbuild's command -v check passes.
			exec "${__ext_sccache_bin_dir}/sccache" "${RUST_TOOL_RUSTC}" "\$@"
		SCCACHE_RUSTC_WRAP
		common_make_params_quoted+=("RUSTC=${wrap}")
	fi
}
# ATF / Crust run make in the host shell (no `env -i`), so the exports
# from compile_prepare_vars__sccache reach them via the normal env. No
# make_config hook needed.

# Pass the SCCACHE_* vars across the host→docker boundary. core's main
# docker.sh forwards a fixed set, but SCCACHE_* is not in that whitelist.
function host_pre_docker_launch__sccache() {
	# A cache service on the build host's loopback is reached from the container
	# as host.docker.internal: map that name here, compile_prepare_vars rewrites
	# the endpoints inside. Mirrors ccache-remote's docker handling.
	local var item
	for var in $(_ext_sccache_endpoint_vars); do
		for item in ${!var//,/ }; do
			if _ext_sccache_loopback_url "${item}" > /dev/null; then
				DOCKER_EXTRA_ARGS+=("--add-host=host.docker.internal:host-gateway")
				break 2
			fi
		done
	done

	# A user-chosen cache dir is a host path; the container sees only ${SRC}
	# mounts, so bind it at the same path.
	local dir
	local -A mounted=()
	for var in SCCACHE_DIR COMPILE_CACHE_DIR; do
		dir="${!var%/}"
		if [[ -n "${dir}" && -z "${mounted[${dir}]:-}" ]]; then
			mounted[${dir}]=1
			mkdir -p "${dir}"
			DOCKER_EXTRA_ARGS+=("--mount" "type=bind,source=${dir},target=${dir}")
		fi
	done
	# Files named by the variables (SCCACHE_CONF, SCCACHE_GCS_KEY_PATH, …) are host paths as well.
	for var in $(_ext_sccache_env_vars); do
		if [[ "${!var}" == /* && -f "${!var}" ]]; then
			DOCKER_EXTRA_ARGS+=("--mount" "type=bind,source=${!var},target=${!var}")
		fi
	done

	# Pass envs by name (--env VAR with no value) rather than VAR=VAL so
	# that AWS_SECRET_ACCESS_KEY / SCCACHE_WEBDAV_PASSWORD /
	# ACTIONS_RUNTIME_TOKEN aren't echoed verbatim into build logs by
	# docker_cli_prepare_launch's debug dump of DOCKER_EXTRA_ARGS.
	# Docker resolves the value from the launcher's exported env, so we
	# export each var first.
	# The extension's own settings (SCCACHE_PIN_VERSION, SCCACHE_SKIP_PROBE,
	# SCCACHE_SHA256_<TRIPLE>) ride along under the same prefix.
	for var in $(_ext_sccache_env_vars); do
		export "${var?}"
		DOCKER_EXTRA_ARGS+=("--env" "${var}")
	done
}

# Point loopback hosts in an endpoint var (a comma-separated list for
# SCCACHE_REDIS_CLUSTER_ENDPOINTS) at host.docker.internal, so a cache on the
# build host's loopback is reachable from the container. Returns 0 if changed.
function _ext_sccache_rewrite_loopback() {
	local var="$1" value="${!1:-}"
	[[ -z "${value}" ]] && return 1

	local -a items
	local i new_item new changed=0
	IFS=',' read -r -a items <<< "${value}"
	for i in "${!items[@]}"; do
		if new_item="$(_ext_sccache_loopback_url "${items[i]}")"; then
			items[i]="${new_item}"
			changed=1
		fi
	done
	((changed)) || return 1

	new="$(
		IFS=','
		echo "${items[*]}"
	)"
	export "${var?}=${new}"
	display_alert "${EXTENSION}: rewrote loopback for docker" "${var} → host.docker.internal" "debug"
	return 0
}

# Print the URL with its loopback host replaced by host.docker.internal;
# return 1 if the host is not loopback.
function _ext_sccache_loopback_url() {
	local url="$1"

	# Decompose: [scheme://][userinfo@]host[:port][/path]; Redis also takes a bare host:port.
	local scheme="" rest="${url}"
	if [[ "${url}" == *://* ]]; then
		scheme="${url%%://*}"
		rest="${url#*://}"
	fi
	# A unix socket is not reachable from the container under any host name.
	[[ "${scheme}" == "unix" || "${scheme}" == "redis+unix" ]] && return 1

	local userinfo=""
	if [[ "${rest}" == *@* ]]; then
		local pre_path="${rest%%/*}"
		if [[ "${pre_path}" == *@* ]]; then
			userinfo="${pre_path%@*}@"
			rest="${rest:${#userinfo}}"
		fi
	fi

	local host port_path
	if [[ "${rest}" == \[* ]]; then
		host="${rest#\[}"
		host="${host%%\]*}"
		port_path="${rest#*\]}"
	else
		host="${rest%%[:/]*}"
		port_path="${rest:${#host}}"
	fi

	case "${host}" in
		localhost | 127.0.0.1 | ::1)
			# Splice host only; preserve userinfo/port/path verbatim so a
			# credential value containing "localhost" or "127.0.0.1" as a
			# substring isn't silently mutated.
			echo "${scheme:+${scheme}://}${userinfo}host.docker.internal${port_path}"
			return 0
			;;
		*) return 1 ;;
	esac
}

function compile_wrapper_pre__sccache() {
	display_alert "Clearing sccache statistics" "sccache" "sccache"
	run_host_command_logged sccache --zero-stats "||" true

	if [[ "${DEBUG}" == "yes" || "${SHOW_COMPILE_CACHE}" == "yes" ]]; then
		# sccache 0.10+ dropped --show-config; --show-stats already
		# prints the active cache location and limits at the bottom of
		# its output, so a pre-build snapshot of the empty stats is the
		# best stand-in for the old "configuration" dump.
		display_alert "sccache version" "$(sccache --version 2> /dev/null || echo unknown)" "sccache"
	fi

	display_alert "Running sccache'd build..." "$(_ext_sccache_backend_location "$(sccache --show-stats --stats-format=json 2> /dev/null)")" "sccache"
}

# The storage sccache actually picked (env may name several backends), from
# the cache_location of its JSON stats, with URL credentials masked.
function _ext_sccache_backend_location() {
	local location
	location="$(echo "$1" | jq -r '.cache_location // empty' 2> /dev/null)"
	_ext_sccache_mask_credentials "${location:-unknown backend}"
}

function _ext_sccache_mask_credentials() {
	echo "$1" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'
}

function compile_wrapper_post__sccache() {
	# Capture both representations up-front, before anything else can
	# disturb the sccache daemon (signals, cleanup teardown). Reading
	# them sequentially also acts as a smoke test that the daemon is
	# still alive.
	local stats_json stats_txt
	stats_json="$(sccache --show-stats --stats-format=json 2> /dev/null || true)"
	stats_txt="$(sccache --show-stats 2> /dev/null || true)"

	local hits misses errors pct
	if [[ -n "${stats_json}" ]] && command -v jq > /dev/null 2>&1; then
		hits="$(echo "${stats_json}" | jq -r '[.stats.cache_hits.counts[]?] | add // 0')"
		misses="$(echo "${stats_json}" | jq -r '[.stats.cache_misses.counts[]?] | add // 0')"
		# Sum per-language cache_errors + scalar cache_write_errors —
		# remote backends report upload failures via the latter, which
		# would otherwise leave err=0 even when the cache is broken.
		errors="$(echo "${stats_json}" | jq -r '([.stats.cache_errors.counts[]?] | add // 0) + (.stats.cache_write_errors // 0)')"
	else
		hits="$(_ext_sccache_stat_field "${stats_txt}" "Cache hits")"
		misses="$(_ext_sccache_stat_field "${stats_txt}" "Cache misses")"
		local cache_errs write_errs
		cache_errs="$(_ext_sccache_stat_field "${stats_txt}" "Cache errors")"
		write_errs="$(_ext_sccache_stat_field "${stats_txt}" "Cache write errors")"
		errors=$((cache_errs + write_errs))
	fi

	pct="$(_ext_sccache_hit_pct "${hits}" "${misses}")"
	display_alert "Sccache result" "hit=${hits} miss=${misses} err=${errors} (${pct}%) — $(_ext_sccache_backend_location "${stats_json}")" "info"

	# Per-language breakdown (when jq is available) — surfaces Rust vs
	# C/C++ vs Assembler hit ratios and exposes which compilers
	# accumulated cache_errors / non_cacheable_compilations. Quiet by
	# default; full text dump gated by DEBUG=yes or SHOW_COMPILE_CACHE=yes.
	if [[ -n "${stats_json}" ]] && command -v jq > /dev/null 2>&1; then
		_ext_sccache_alert_lang_breakdown "${stats_json}" "cache_hits" "hits"
		_ext_sccache_alert_lang_breakdown "${stats_json}" "cache_misses" "miss"
		_ext_sccache_alert_lang_breakdown "${stats_json}" "cache_errors" "err"
		_ext_sccache_alert_lang_breakdown "${stats_json}" "non_cacheable_compilations" "non-cacheable"
		_ext_sccache_alert_reasons "${stats_json}"
	fi

	if [[ "${DEBUG}" == "yes" || "${SHOW_COMPILE_CACHE}" == "yes" ]]; then
		# Don't re-invoke sccache here — the daemon may already be torn
		# down on SIGINT cleanup. Replay the captured `stats_txt` via
		# display_alert so every line lands in the standard build log
		# (output/logs/log-<artifact>-<uuid>.log) alongside other alerts.
		display_alert "sccache --show-stats" "${EXTENSION}" "sccache"
		local line
		while IFS= read -r line; do
			[[ -z "${line}" ]] && continue
			display_alert "  ${line}" "" "info"
		done <<< "$(_ext_sccache_mask_credentials "${stats_txt}")"
	fi
}

# Emit one `display_alert` per language bucket within a stats counter
# (cache_hits, cache_misses, cache_errors, non_cacheable_compilations).
# Skips zero buckets so the build log isn't cluttered when nothing
# happened for a given language.
function _ext_sccache_alert_lang_breakdown() {
	local stats_json="$1" counter="$2" label="$3"
	local breakdown
	breakdown="$(echo "${stats_json}" |
		jq -r --arg c "${counter}" \
			'.stats[$c].counts | to_entries[] | select(.value > 0) | "\(.key)=\(.value)"' \
			2> /dev/null |
		tr '\n' ' ')"
	if [[ -n "${breakdown}" ]]; then
		display_alert "  sccache ${label}" "${breakdown% }" "info"
	fi
}

# Emit non-cacheable reason buckets per language so we can see why
# certain compilations bypass the cache (e.g. proc-macro crates emit
# `multiple inputs`, build scripts emit `Rust crate type "bin"`).
function _ext_sccache_alert_reasons() {
	local stats_json="$1"
	local reasons
	reasons="$(echo "${stats_json}" |
		jq -r '.stats.not_cached | to_entries[]
		         | select(.value > 0) | "\(.key)=\(.value)"' \
			2> /dev/null |
		tr '\n' ' ')"
	if [[ -n "${reasons}" ]]; then
		display_alert "  sccache non-cacheable reasons" "${reasons% }" "info"
	fi
}

# Parse a "Field name        N" line from `sccache --show-stats`.
# Returns 0 if the line is missing or non-numeric, keeping the stats line
# parseable even when the backend is misbehaving.
function _ext_sccache_stat_field() {
	local stats="$1" field="$2"
	local val
	val="$(echo "${stats}" | awk -v f="${field}" 'index($0, f) == 1 { for (i = NF; i > 0; i--) if ($i ~ /^[0-9]+$/) { print $i; exit } }')"
	[[ "${val}" =~ ^[0-9]+$ ]] || val=0
	echo "${val}"
}

function _ext_sccache_hit_pct() {
	local hit="$1" miss="$2"
	local total=$((hit + miss))
	if ((total > 0)); then
		echo $((hit * 100 / total))
	else
		echo 0
	fi
}
