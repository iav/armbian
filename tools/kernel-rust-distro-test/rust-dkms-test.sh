#!/bin/bash
# Build the rust-out-of-tree DKMS module against our linux-headers in a clean trixie container.
# Usage: rust-dkms-test.sh <dir with linux-headers-*.deb> <dir with rust-out-of-tree sources + dkms.conf>
set -euo pipefail
debs=$(realpath "$1")
mod=$(realpath "$2")
headers=$(ls -t "${debs}"/linux-headers-*trixie*.deb | head -1)
echo "headers: $(basename "${headers}")"
docker run --rm -v "${debs}:/debs:ro" -v "${mod}:/mod:ro" debian:trixie bash -c '
	set -euo pipefail
	export DEBIAN_FRONTEND=noninteractive
	apt-get -qq update
	# python3: headers postinst builds resolve_btfids, but linux-headers does not depend on it.
	apt-get -qq install -y --no-install-recommends dkms kmod python3 "/debs/'"$(basename "${headers}")"'" > /tmp/apt.log 2>&1 || { tail -30 /tmp/apt.log; exit 1; }
	dpkg-query -W -f="\${Package} \${Version}\n" rustc linux-headers-\* 2> /dev/null
	kver=$(ls /usr/src | sed -n "s/^linux-headers-//p" | head -1)
	echo "kernel: ${kver}"
	cp -r /mod /usr/src/rust-out-of-tree-0.1
	dkms add rust-out-of-tree/0.1
	dkms build rust-out-of-tree/0.1 -k "${kver}" || { cat /var/lib/dkms/rust-out-of-tree/0.1/build/make.log; exit 1; }
	find /var/lib/dkms/rust-out-of-tree -name "*.ko*" -exec modinfo {} \; | grep -E "^(filename|name|vermagic|description):"
'
