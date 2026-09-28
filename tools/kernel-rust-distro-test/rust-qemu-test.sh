#!/bin/bash
# Boot an Armbian uefi-x86 image in qemu with a one-shot test: build rust-out-of-tree via DKMS,
# load it, print the result on the serial console, power off.
# Usage: rust-qemu-test.sh <image.img> <dir with rust-out-of-tree sources + dkms.conf> <serial log>
set -euo pipefail
src=$(realpath "$1")
mod=$(realpath "$2")
log=$(realpath -m "$3")
img="${src%.img}-rusttest.img"
cp --reflink=auto "${src}" "${img}"

loop=$(sudo losetup -Pf --show "${img}")
mnt=$(mktemp -d)
trap 'sudo umount "${mnt}" 2> /dev/null || true; sudo losetup -d "${loop}" 2> /dev/null || true' EXIT
sudo udevadm settle
root=""
for part in "${loop}"p*; do
	case "$(sudo blkid -o value -s TYPE "${part}" 2> /dev/null)" in
		btrfs | ext4)
			root="${part}"
			break
			;;
	esac
done
[[ -n "${root}" ]] || {
	echo "no btrfs/ext4 partition on ${loop}"
	exit 1
}
echo "rootfs: ${root}"
sudo mount "${root}" "${mnt}"
# Armbian images may use a default btrfs subvolume; the mount above follows it.
sudo cp -r "${mod}" "${mnt}/usr/src/rust-out-of-tree-0.1"
sudo tee "${mnt}/usr/local/sbin/rust-dkms-selftest" > /dev/null << 'EOF'
#!/bin/sh
exec > /dev/ttyS0 2>&1
echo "RUSTTEST: kernel $(uname -r)"
dpkg-query -W -f='RUSTTEST: ${Package} ${Version}\n' rustc 'linux-headers-*' dkms 2> /dev/null
dkms add rust-out-of-tree/0.1
if dkms install rust-out-of-tree/0.1 -k "$(uname -r)"; then echo "RUSTTEST: dkms install ok"; else echo "RUSTTEST: dkms install FAILED"; fi
if modprobe rust_out_of_tree; then echo "RUSTTEST: modprobe ok"; else echo "RUSTTEST: modprobe FAILED"; fi
dmesg | grep -E 'rust_out_of_tree|Rust out-of-tree' | sed 's/^/RUSTTEST: dmesg: /'
dkms status | sed 's/^/RUSTTEST: dkms status: /'
echo "RUSTTEST: done"
systemctl poweroff
EOF
sudo chmod +x "${mnt}/usr/local/sbin/rust-dkms-selftest"
sudo tee "${mnt}/etc/systemd/system/rust-dkms-selftest.service" > /dev/null << 'EOF'
[Unit]
Description=rust-out-of-tree DKMS self-test
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rust-dkms-selftest

[Install]
WantedBy=multi-user.target
EOF
sudo ln -sf /etc/systemd/system/rust-dkms-selftest.service "${mnt}/etc/systemd/system/multi-user.target.wants/rust-dkms-selftest.service"
sudo umount "${mnt}"
sudo losetup -d "${loop}"
trap - EXIT

cp /usr/share/OVMF/OVMF_VARS_4M.fd "${img%.img}.vars.fd"
timeout 7200 qemu-system-x86_64 -m 4096 -smp 4 \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
	-drive if=pflash,format=raw,file="${img%.img}.vars.fd" \
	-drive file="${img}",format=raw,if=virtio \
	-serial "file:${log}" -monitor none -display none
grep RUSTTEST "${log}" || echo "no RUSTTEST lines in ${log}"
