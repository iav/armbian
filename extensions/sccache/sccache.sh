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
# per-artifact *_make_config hooks to inject SCCACHE_* env vars into the
# `env -i` make environments.
#
# Single extension covers three backends, selected purely via SCCACHE_* env:
#   - Local FS (default; ${SRC}/cache/sccache)
#   - WebDAV  (SCCACHE_WEBDAV_ENDPOINT)
#   - S3-compatible — Garage, MinIO, R2, AWS (SCCACHE_BUCKET + …)
# Plus passthrough for GitHub Actions cache (SCCACHE_GHA_ENABLED).
#
# Enable explicitly via ENABLE_EXTENSIONS=sccache. Not auto-enabled by the
# legacy USE_CCACHE toggle (which still maps to extensions/ccache.sh).
#
# Mutually exclusive with extensions/ccache.sh — mutex enforced in both
# extension_prepare_config__sccache and extension_prepare_config__ccache.

# Defaults — overridable via env at compile.sh invocation time.
# sccache's own default cache size is 10G; 5G is comfortable for
# kernel+u-boot+ATF turns on a CAX21-class builder without hogging the
# project cache disk.
declare -g SCCACHE_PIN_VERSION="${SCCACHE_PIN_VERSION:-v0.15.0}"
# SCCACHE_CACHE_SIZE default is applied later in compile_prepare_vars__sccache
# (lib.config / user_config / extension_prepare_config can set COMPILE_CACHE_SIZE
# between extension source time and compile time; resolving at source time would
# freeze the default before those override points run).

# SHA256 table for the pinned version's prebuilt musl tarballs. Keyed by
# the rust target triple slug used in the GitHub release filename. If
# SCCACHE_PIN_VERSION is overridden, the bootstrap step will accept the
# user-provided SCCACHE_SHA256_<TRIPLE> env override instead.
declare -g -A __ext_sccache_sha256=(
	["x86_64-unknown-linux-musl"]="782d2b5dd7ae0a55ebe368ab258114d0928d019ac2d949ab85d5d02f3926709e"
	["aarch64-unknown-linux-musl"]="3a6a3712b49da3d263bf2d30d702de4302793016019e800bfb81c0c69401d8f8"
	["armv7-unknown-linux-musleabi"]="c6d7171ee9216ec8035b9b639526f68d27c4a0b5e6f914ac0147d3153c3b2261"
	["i686-unknown-linux-musl"]="cb4a90e7da62517a6595ed438765db1a0fba933c7c91818302130902942437b3"
	["riscv64gc-unknown-linux-musl"]="d24b685ca21bf9388da5311c4dfe88de813acea84ca85b12d67f4e4b9a7a983a"
	["loongarch64-unknown-linux-musl"]="60d56ba90a3e6cc616be84b3bd72fe44b3d6dedc5d51a50116a24e884a991f75"
	["s390x-unknown-linux-musl"]="729618c5fe016aa553f372ec28bfeff4288ba5d99baee6dc04031336a789b6f1"
)

# Mutually-exclusive list of compile-cache extensions. `ccache-remote`
# is included alongside `ccache` because enabling ccache-remote alone
# (without auto-enabling ccache, e.g. when sccache is in the list) still
# leaves CCACHE_REMOTE_STORAGE exported and ccache_post_compilation hooks
# running — they'd silently fight with sccache's CCACHE export. Both
# arrays (here + __ext_ccache_conflicting_exts in extensions/ccache.sh)
# must stay in sync so the mutex fires regardless of enable order.
declare -g -a __ext_sccache_conflicting_exts=("ccache" "ccache-remote")

# Env vars passed through to the inside of the docker container and into
# the `env -i make` arrays for kernel/u-boot. Mirrors the role of
# CCACHE_PASSTHROUGH_VARS in extensions/ccache-remote. Any SCCACHE_*
# variable set at compile.sh invocation time is forwarded.
declare -g -a SCCACHE_PASSTHROUGH_VARS=(
	SCCACHE_DIR
	SCCACHE_CACHE_SIZE
	SCCACHE_BASEDIRS
	SCCACHE_IDLE_TIMEOUT
	SCCACHE_IGNORE_SERVER_IO_ERROR
	SCCACHE_WEBDAV_ENDPOINT
	SCCACHE_WEBDAV_USERNAME
	SCCACHE_WEBDAV_PASSWORD
	SCCACHE_WEBDAV_TOKEN
	SCCACHE_WEBDAV_KEY_PREFIX
	SCCACHE_BUCKET
	SCCACHE_REGION
	SCCACHE_ENDPOINT
	SCCACHE_S3_USE_SSL
	SCCACHE_S3_KEY_PREFIX
	SCCACHE_S3_ENABLE_VIRTUAL_HOST_STYLE
	SCCACHE_S3_NO_CREDENTIALS
	SCCACHE_S3_SERVER_SIDE_ENCRYPTION
	AWS_ACCESS_KEY_ID
	AWS_SECRET_ACCESS_KEY
	AWS_SESSION_TOKEN
	SCCACHE_GHA_ENABLED
	SCCACHE_GHA_CACHE_URL
	SCCACHE_GHA_CACHE_TO
	SCCACHE_GHA_CACHE_FROM
	SCCACHE_GHA_RUNTIME_TOKEN
	ACTIONS_CACHE_URL
	ACTIONS_RESULTS_URL
	ACTIONS_RUNTIME_TOKEN
	SCCACHE_ERROR_LOG
	SCCACHE_LOG
)

function extension_prepare_config__sccache() {
	# Use the shared normalization (EXT fallback + comma/whitespace handling,
	# plus extensions enabled programmatically via enable_extension from user
	# configs) — same mutex pattern as extensions/ccache.sh.
	local _ext_list other
	_ext_list="$(extension_list_normalized)"
	for other in "${__ext_sccache_conflicting_exts[@]}"; do
		if [[ "${_ext_list}" == *",${other},"* ]]; then
			exit_with_error "${EXTENSION}: 'sccache' and '${other}' extensions are mutually exclusive — choose one compile-cache backend"
		fi
	done

	# Warn (don't abort) when env points sccache at more than one remote
	# backend. sccache itself resolves precedence (GHA > S3 > Azure > GCS >
	# Redis > Memcached > WebDAV > local); the warning just surfaces the
	# misconfiguration in the build log.
	local backends_set=0
	[[ -n "${SCCACHE_BUCKET}" ]] && ((backends_set++)) || true
	[[ -n "${SCCACHE_WEBDAV_ENDPOINT}" ]] && ((backends_set++)) || true
	[[ "${SCCACHE_GHA_ENABLED}" == "on" || "${SCCACHE_GHA_ENABLED}" == "true" ]] && ((backends_set++)) || true
	if ((backends_set > 1)); then
		display_alert "${EXTENSION}: multiple remote backends configured" \
			"sccache will pick by built-in precedence (GHA > S3 > WebDAV)" "wrn"
	fi

	_ext_sccache_bootstrap_binary
}

# Download + verify the pinned sccache binary into cache/tools/sccache/,
# and overlay it with a thin shim — both named "sccache". The shim lives
# in ${tools_dir} (added to PATH); the real binary stays in ${bin_dir}
# under its versioned subdir and is referenced from the shim by absolute
# path. Idempotent: fast path skips when both files are in place.
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
	local shim="${tools_dir}/sccache"

	declare -g __ext_sccache_bin_dir="${tools_dir}"

	mkdir -p "${tools_dir}"
	_ext_sccache_write_cachedir_tag "${tools_dir}"

	# Fast path: both files present and shim still references this real binary.
	if [[ -x "${real}" && -x "${shim}" ]] && grep -q "REAL=${real}" "${shim}" 2> /dev/null; then
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
		local tarball="${bin_dir}/sccache.tar.gz"

		display_alert "${EXTENSION}: downloading sccache" "${ver} (${triple})" "info"
		run_host_command_logged curl --fail --location --silent --show-error --output "${tarball}" "${url}" ||
			exit_with_error "${EXTENSION}: failed to download" "${url}"

		local got
		got="$(sha256sum "${tarball}" | awk '{print $1}')"
		if [[ "${got}" != "${sha}" ]]; then
			rm -f "${tarball}"
			exit_with_error "${EXTENSION}: SHA256 mismatch" "expected ${sha}, got ${got}"
		fi

		run_host_command_logged tar -xzf "${tarball}" -C "${bin_dir}" --strip-components=1 "sccache-${ver}-${triple}/sccache" ||
			exit_with_error "${EXTENSION}: tar extract failed" "${tarball}"
		rm -f "${tarball}"
		chmod +x "${real}"
	fi

	_ext_sccache_write_shim "${shim}" "${real}"
	display_alert "${EXTENSION}: installed sccache" "${ver} (${triple})" "ext"
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
	cat > "${shim}" <<- SCCACHE_SHIM
		#!/bin/sh
		# Auto-generated by extensions/sccache.sh — do not edit.
		# REAL=${real}
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
	chmod +x "${shim}"
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
	# CCACHE substitutes into CROSS_COMPILE='${CCACHE} <prefix>-' at the
	# kernel/u-boot/atf/crust call sites. The "sccache" name is also
	# special-cased by u-boot's HOST_ARCH detection regex (matches
	# `.*ccache <space>`), so we keep the shim filename literally
	# "sccache" — _ext_sccache_write_shim handles the ld/ar/etc.
	# passthrough that the bare upstream binary can't do.
	export CCACHE="sccache"
	if [[ -n "${__ext_sccache_bin_dir}" ]]; then
		export PATH="${__ext_sccache_bin_dir}:${PATH}"
	fi

	# apply_cmdline_params_to_env stores CLI `KEY=value` overrides as plain
	# shell variables, not exported environment — so a child sccache process
	# launched here (the probe, plus ATF/Crust make in the host shell) would
	# never see them. Promote every configured backend var to an export now
	# so probe and host-shell builds see the same config as the docker side.
	local var
	for var in "${SCCACHE_PASSTHROUGH_VARS[@]}"; do
		[[ -n "${!var}" ]] && export "${var?}"
	done

	# Default to a local-FS backend rooted in the project cache when the
	# user hasn't selected any remote backend. Mirrors ccache's
	# ${SRC}/cache/ccache default — keeps the cache on the same volume as
	# the build tree (XFS-friendly on cloud builders).
	if [[ -z "${SCCACHE_DIR}" &&
		-z "${SCCACHE_BUCKET}" &&
		-z "${SCCACHE_WEBDAV_ENDPOINT}" &&
		"${SCCACHE_GHA_ENABLED}" != "on" &&
		"${SCCACHE_GHA_ENABLED}" != "true" ]]; then
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

	# Force a fresh daemon so it boots with the env we just exported. A
	# stale server from a previous build (different SCCACHE_DIR / backend /
	# project) would otherwise keep serving requests against the old
	# config and the new SCCACHE_* exports would silently take no effect.
	sccache --stop-server > /dev/null 2>&1 || true

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

# Compile a one-statement C file through sccache, then read its stats.
# If the trivial compile exits non-zero, or sccache reports any cache /
# write errors, treat the remote backend as broken and disable it for
# the rest of the build — unset every SCCACHE_*_REMOTE-ish env var,
# re-point SCCACHE_DIR at a local path, and stop the running daemon so
# the next sccache invocation re-spawns with the new env. No-op for
# pure local-FS configurations (nothing to fall back from).
function _ext_sccache_probe_backend() {
	# Only probe when a remote backend is actually configured.
	if [[ -z "${SCCACHE_WEBDAV_ENDPOINT}" &&
		-z "${SCCACHE_BUCKET}" &&
		"${SCCACHE_GHA_ENABLED}" != "on" &&
		"${SCCACHE_GHA_ENABLED}" != "true" ]]; then
		return 0
	fi

	local cc
	cc="$(command -v cc 2> /dev/null || command -v gcc 2> /dev/null || true)"
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

# Unset every remote-backend env var, repoint SCCACHE_DIR at a local
# default, and stop the running daemon so the next invocation re-spawns
# with the local-only config. Idempotent.
function _ext_sccache_disable_remote() {
	unset SCCACHE_WEBDAV_ENDPOINT SCCACHE_WEBDAV_USERNAME \
		SCCACHE_WEBDAV_PASSWORD SCCACHE_WEBDAV_TOKEN \
		SCCACHE_BUCKET SCCACHE_REGION SCCACHE_ENDPOINT \
		SCCACHE_S3_USE_SSL SCCACHE_S3_KEY_PREFIX \
		AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
		SCCACHE_GHA_ENABLED ACTIONS_CACHE_URL ACTIONS_RUNTIME_TOKEN
	export SCCACHE_DIR="${COMPILE_CACHE_DIR:-${SRC}/cache/sccache}"
	_ext_sccache_write_cachedir_tag "${SCCACHE_DIR}"
	sccache --stop-server > /dev/null 2>&1 || true
}

# Inject every set SCCACHE_PASSTHROUGH_VARS entry into the given env-i
# make envs array, except credential-bearing variables. sccache daemon
# was spawned in compile_wrapper_pre with the full env (secrets baked
# in); env-i make children just talk to the running daemon over its
# socket and don't need credentials of their own. Skipping credentials
# here keeps run_host_command_logged's command echo (kernel/u-boot
# 'env -i ... make' line) free of raw passwords / tokens / secrets.
# Pattern-based to catch future *_TOKEN / *_PASSWORD / *_SECRET vars
# without maintaining an explicit allowlist.
function _ext_sccache_inject_envs() {
	local -n envs="$1"
	local var val
	for var in "${SCCACHE_PASSTHROUGH_VARS[@]}"; do
		case "${var}" in
			*PASSWORD* | *TOKEN* | *SECRET*) continue ;;
		esac
		val="${!var}"
		if [[ -n "${val}" ]]; then
			# Skip URL values with embedded userinfo (e.g.
			# SCCACHE_REDIS=redis://:pass@host:6379); daemon
			# already has these from compile_wrapper_pre's env.
			[[ "${val}" == *"://"*":"*"@"* ]] && continue
			envs+=("${var}=${val@Q}")
		fi
	done
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
		local wrap="${__ext_sccache_bin_dir}/sccache-rustc"
		cat > "${wrap}" <<- SCCACHE_RUSTC_WRAP
			#!/bin/sh
			# Auto-generated by extensions/sccache.sh — points RUSTC at a
			# single-file path so kbuild's command -v check passes.
			exec "${__ext_sccache_bin_dir}/sccache" "${RUST_TOOL_RUSTC}" "\$@"
		SCCACHE_RUSTC_WRAP
		chmod +x "${wrap}"
		common_make_params_quoted+=("RUSTC=${wrap}")
	fi
}
# ATF / Crust run make in the host shell (no `env -i`), so the exports
# from compile_prepare_vars__sccache reach them via the normal env. No
# make_config hook needed.

# Pass the SCCACHE_* vars across the host→docker boundary. core's main
# docker.sh forwards a fixed set, but SCCACHE_* is not in that whitelist.
function host_pre_docker_launch__sccache() {
	# Rewrite loopback host references (localhost / 127.0.0.1 / ::1) in
	# SCCACHE_WEBDAV_ENDPOINT and SCCACHE_ENDPOINT to host.docker.internal
	# so a cache service bound to the build host's loopback is reachable
	# from inside the container. Mirrors ccache-remote's docker handling.
	local _rewrote_loopback=0
	_ext_sccache_rewrite_loopback SCCACHE_WEBDAV_ENDPOINT && _rewrote_loopback=1
	_ext_sccache_rewrite_loopback SCCACHE_ENDPOINT && _rewrote_loopback=1
	if ((_rewrote_loopback)); then
		DOCKER_EXTRA_ARGS+=("--add-host=host.docker.internal:host-gateway")
	fi

	# Pass envs by name (--env VAR with no value) rather than VAR=VAL so
	# that AWS_SECRET_ACCESS_KEY / SCCACHE_WEBDAV_PASSWORD /
	# ACTIONS_RUNTIME_TOKEN aren't echoed verbatim into build logs by
	# docker_cli_prepare_launch's debug dump of DOCKER_EXTRA_ARGS.
	# Docker resolves the value from the launcher's exported env, so we
	# export each var first.
	local var
	for var in "${SCCACHE_PASSTHROUGH_VARS[@]}" SCCACHE_PIN_VERSION; do
		if [[ -n "${!var}" ]]; then
			export "${var?}"
			DOCKER_EXTRA_ARGS+=("--env" "${var}")
		fi
	done

	# When user overrides SCCACHE_PIN_VERSION to a version not in the
	# built-in SHA256 table, they pass SCCACHE_SHA256_<TRIPLE>=<sha> on
	# the host; bootstrap inside docker needs it too. Glob the env at
	# launch time rather than enumerate triples.
	while IFS= read -r var; do
		if [[ -n "${!var}" ]]; then
			export "${var?}"
			DOCKER_EXTRA_ARGS+=("--env" "${var}")
		fi
	done < <(compgen -v SCCACHE_SHA256_ 2> /dev/null || true)
}

# Rewrite the host part of an URL-valued env var from loopback
# (localhost / 127.0.0.1 / [::1]) to host.docker.internal so a cache
# service bound to the build host's loopback is reachable from the
# container. Returns 0 if the var was rewritten, 1 otherwise.
function _ext_sccache_rewrite_loopback() {
	local var="$1" url="${!1:-}"
	[[ -z "${url}" ]] && return 1

	# Decompose: scheme://[userinfo@]host[:port][/path]
	local scheme="${url%%://*}"
	[[ "${scheme}" == "${url}" ]] && return 1
	local rest="${url#*://}"

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
			local new="${scheme}://${userinfo}host.docker.internal${port_path}"
			export "${var?}=${new}"
			display_alert "${EXTENSION}: rewrote loopback for docker" \
				"${var}: ${host} → host.docker.internal" "debug"
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

	display_alert "Running sccache'd build..." "sccache" "sccache"
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
	display_alert "Sccache result" "hit=${hits} miss=${misses} err=${errors} (${pct}%)" "info"

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
		done <<< "${stats_txt}"
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
		jq -r '.stats.non_cacheable_reasons.counts | to_entries[]
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
