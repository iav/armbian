# @description Enables Rust in the Linux kernel (`CONFIG_RUST`) with the target release's own rustc, so out-of-tree Rust modules (DKMS) build on the target with the same compiler. The kernel is built for one release: `RELEASE` goes into the kernel version and the packages' Provides, and linux-headers depend on the exact rustc package.

# Enable Rust in the kernel with the target release's rustc.
#
# A Rust module built on the target must use exactly the rustc that built the
# kernel, down to the distribution build. So the kernel is built with the
# rustc, rustfmt, bindgen and rust-src packages of RELEASE, installed in the
# build container, and linux-headers depend on that rustc package version.
#
# Requirements:
# - the build container runs RELEASE;
# - for out-of-tree Rust modules, a native build: proc-macro rust/*.so in
#   linux-headers are build-host binaries.
#
# Usage:  ./compile.sh kernel BOARD=... BRANCH=... RELEASE=trixie ENABLE_EXTENSIONS="kernel-rust-distro"
# Do not combine with kernel-rust.

# Supported releases and their exact rustc package version.
declare -g -A KERNEL_RUST_DISTRO_RUSTC=(
	["trixie"]="1.85.1+dfsg1-1+deb13u1"
)

# Set to "yes" to build rust_minimal, rust_print, rust_driver_faux as modules.
RUST_KERNEL_SAMPLES="${RUST_KERNEL_SAMPLES:-no}"

# Resolved by host_dependencies_ready, used by custom_kernel_make_params.
declare -g KERNEL_RUST_DISTRO_SYSROOT=""

function extension_prepare_config__kernel_rust_distro() {
	if declare -F add_host_dependencies__add_rust_compiler > /dev/null; then
		exit_with_error "${EXTENSION}: do not enable together with kernel-rust"
	fi
	if [[ -z "${RELEASE}" ]]; then
		exit_with_error "${EXTENSION}: RELEASE must be set, the kernel is built for one release"
	fi
	if [[ -z "${KERNEL_RUST_DISTRO_RUSTC[${RELEASE}]:-}" ]]; then
		exit_with_error "${EXTENSION}: release not supported" "${RELEASE}; supported: ${!KERNEL_RUST_DISTRO_RUSTC[*]}"
	fi

	declare -g KERNEL_IMAGE_EXTRA_PROVIDES="${KERNEL_IMAGE_EXTRA_PROVIDES:+${KERNEL_IMAGE_EXTRA_PROVIDES}, }linux-image-${BRANCH}-${LINUXFAMILY}-${RELEASE}"
	declare -g KERNEL_DTB_EXTRA_PROVIDES="${KERNEL_DTB_EXTRA_PROVIDES:+${KERNEL_DTB_EXTRA_PROVIDES}, }linux-dtb-${BRANCH}-${LINUXFAMILY}-${RELEASE}"
	declare -g KERNEL_HEADERS_EXTRA_PROVIDES="${KERNEL_HEADERS_EXTRA_PROVIDES:+${KERNEL_HEADERS_EXTRA_PROVIDES}, }linux-headers-${BRANCH}-${LINUXFAMILY}-${RELEASE}"
	declare -g KERNEL_HEADERS_EXTRA_DEPENDS="${KERNEL_HEADERS_EXTRA_DEPENDS:+${KERNEL_HEADERS_EXTRA_DEPENDS}, }rustc (= ${KERNEL_RUST_DISTRO_RUSTC[${RELEASE}]})"
}

function add_host_dependencies__kernel_rust_distro() {
	display_alert "Adding Rust kernel build dependencies from the distribution" "${EXTENSION}" "info"
	EXTRA_BUILD_DEPS+=("rust::rustc" "rust::rustfmt" "rust::rust-src" "rust::bindgen" "clang::libclang-dev")
}

function host_dependencies_ready__kernel_rust_distro() {
	if [[ "${HOSTRELEASE}" != "${RELEASE}" ]]; then
		exit_with_error "${EXTENSION}: build container runs '${HOSTRELEASE}', target is '${RELEASE}'" "they must match"
	fi
	local host_arch
	host_arch="$(dpkg --print-architecture)"
	if [[ "${host_arch}" != "${ARCH}" ]]; then
		display_alert "${EXTENSION}: cross build ${host_arch} -> ${ARCH}" "proc-macro rust/*.so in linux-headers are ${host_arch} binaries: out-of-tree Rust modules will not build on the target" "wrn"
	fi

	local want="${KERNEL_RUST_DISTRO_RUSTC[${RELEASE}]}" have
	have="$(dpkg-query -W -f='${Version}' rustc 2> /dev/null || true)"
	if [[ "${have}" != "${want}" ]]; then
		exit_with_error "${EXTENSION}: rustc package is '${have:-not installed}', expected '${want}'" "update KERNEL_RUST_DISTRO_RUSTC[${RELEASE}]"
	fi

	local tool
	for tool in rustc rustfmt bindgen; do
		[[ -x "/usr/bin/${tool}" ]] || exit_with_error "${EXTENSION}: /usr/bin/${tool} not found"
	done

	KERNEL_RUST_DISTRO_SYSROOT="$(/usr/bin/rustc --print sysroot)"
	if [[ ! -d "${KERNEL_RUST_DISTRO_SYSROOT}/lib/rustlib/src/rust/library" ]]; then
		exit_with_error "${EXTENSION}: Rust library source not found" "${KERNEL_RUST_DISTRO_SYSROOT}/lib/rustlib/src/rust/library"
	fi

	display_alert "Rust toolchain ready" "$(/usr/bin/rustc --version), $(/usr/bin/bindgen --version 2>&1)" "info"
}

function artifact_kernel_version_parts__kernel_rust_distro() {
	# Readable release in the version and file name; rustc version as a short hash.
	local short
	short="$(echo -n "${KERNEL_RUST_DISTRO_RUSTC[${RELEASE}]:-}" | sha256sum | cut -c1-4)"
	artifact_version_parts["_RREL"]="${RELEASE}"
	artifact_version_parts["_RRUSTC"]="rustc${short}"
	artifact_version_part_order+=("0086-_RREL" "0087-_RRUSTC")
}

function custom_kernel_config__kernel_rust_distro() {
	# https://docs.kernel.org/rust/quick-start.html
	opts_y+=("RUST")

	# RUST depends on !MODVERSIONS || GENDWARFKSYMS; Debian's Rust kernels drop MODVERSIONS too.
	if [[ -f .config ]] && grep -q '^CONFIG_MODVERSIONS=y' .config; then
		display_alert "${EXTENSION}: disabling MODVERSIONS" "CONFIG_RUST needs it off, or GENDWARFKSYMS" "info"
	fi
	opts_n+=("MODVERSIONS")

	if [[ "${RUST_KERNEL_SAMPLES}" == "yes" ]]; then
		display_alert "Enabling Rust sample modules" "${EXTENSION}" "info"
		opts_y+=("SAMPLES" "SAMPLES_RUST")
		opts_m+=("SAMPLE_RUST_MINIMAL" "SAMPLE_RUST_PRINT" "SAMPLE_RUST_DRIVER_FAUX")
	fi
}

function pre_package_kernel_headers__kernel_rust_distro() {
	# Out-of-tree Rust modules need the crate metadata (rust/*.rmeta), proc-macro
	# dylibs (rust/*.so) and, with CONFIG_RUST_INLINE_HELPERS, rust/helpers/*.bc.
	# The set varies per kernel version and config, so copy by glob.
	# shellcheck disable=SC2154 # kernel_work_dir is defined in the calling packaging function
	if ! grep -q "^CONFIG_RUST=y" "${kernel_work_dir}/include/config/auto.conf" 2> /dev/null; then
		exit_with_error "${EXTENSION}: kernel built without CONFIG_RUST"
	fi

	declare -a rust_artifacts=()
	local f
	for f in "${kernel_work_dir}/rust/"*.rmeta "${kernel_work_dir}/rust/"*.so "${kernel_work_dir}/rust/helpers/"*.bc; do
		if [[ -f "${f}" ]]; then
			rust_artifacts+=("${f#"${kernel_work_dir}/"}")
		fi
	done
	if [[ ${#rust_artifacts[@]} -eq 0 ]]; then
		exit_with_error "${EXTENSION}: CONFIG_RUST=y but no rust/*.rmeta artifacts in the kernel tree"
	fi

	display_alert "Adding Rust artifacts to linux-headers" "${EXTENSION}: ${#rust_artifacts[@]} files" "info"
	# shellcheck disable=SC2154 # headers_target_dir is defined in the calling packaging function
	tar -c -f - -C "${kernel_work_dir}" "${rust_artifacts[@]}" | tar -xf - -C "${headers_target_dir}"
	if [[ "${PIPESTATUS[0]}" -ne 0 || "${PIPESTATUS[1]}" -ne 0 ]]; then
		exit_with_error "${EXTENSION}: failed to copy Rust artifacts into linux-headers"
	fi
}

function custom_kernel_make_params__kernel_rust_distro() {
	# Kernel make runs under env -i, so pass the tools as make parameters.
	common_make_params_quoted+=("RUSTC=/usr/bin/rustc" "RUSTFMT=/usr/bin/rustfmt" "BINDGEN=/usr/bin/bindgen")
	common_make_envs+=("RUST_LIB_SRC='${KERNEL_RUST_DISTRO_SYSROOT}/lib/rustlib/src/rust/library'")
}
