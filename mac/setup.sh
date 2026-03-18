#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_NAME="firecracker"

echo "=== Firecracker on macOS (via Lima) ==="
echo "Requires: Apple Silicon + macOS 13+ (for nested virtualization)"
echo ""

# Step 1: Install Lima
if ! command -v limactl &> /dev/null; then
    echo "[1/4] Installing Lima..."
    brew install lima
else
    echo "[1/4] Lima already installed: $(limactl --version)"
fi

# Step 2: Create and start the Lima VM
if limactl list --format '{{.Name}}' 2>/dev/null | grep -q "^${VM_NAME}$"; then
    STATUS=$(limactl list --format '{{.Status}}' --filter "name=${VM_NAME}" 2>/dev/null)
    if [ "$STATUS" = "Running" ]; then
        echo "[2/4] Lima VM '${VM_NAME}' already running."
    else
        echo "[2/4] Starting existing Lima VM '${VM_NAME}'..."
        limactl start "$VM_NAME"
    fi
else
    echo "[2/4] Creating and starting Lima VM '${VM_NAME}'..."
    limactl create --name="$VM_NAME" "$SCRIPT_DIR/firecracker.yaml"
    limactl start "$VM_NAME"
fi

# Verify KVM
echo "     Verifying KVM..."
limactl shell "$VM_NAME" -- bash -c 'test -e /dev/kvm && echo "     KVM: OK" || (echo "     KVM: MISSING - nested virtualization not working"; exit 1)'

# Step 3: Run the inner setup inside the VM
echo "[3/4] Setting up Firecracker environment inside Lima VM..."
limactl shell "$VM_NAME" -- bash -s <<'INNER_SETUP'
set -e
WORKDIR=~/firecracker-env
mkdir -p "$WORKDIR"

ARCH=$(uname -m)
echo "     Architecture: $ARCH"

# Install Firecracker
if command -v firecracker &> /dev/null; then
    echo "     Firecracker already installed: $(firecracker --version 2>&1 | head -1)"
else
    echo "     Installing Firecracker..."
    FC_VERSION="v1.12.0"
    curl -sL "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz" -o /tmp/firecracker.tgz
    tar xzf /tmp/firecracker.tgz -C /tmp
    sudo mv "/tmp/release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" /usr/local/bin/firecracker
    sudo chmod +x /usr/local/bin/firecracker
    rm -rf /tmp/firecracker.tgz /tmp/release-*
    echo "     Firecracker $(firecracker --version 2>&1 | head -1)"
fi

# Get kernel
if [ -f "$WORKDIR/vmlinux" ] && [ "$(stat -c%s "$WORKDIR/vmlinux")" -gt 1000000 ]; then
    echo "     Kernel already present."
else
    echo "     Extracting kernel from host..."
    sudo apt-get update -qq > /dev/null 2>&1
    sudo apt-get install -y -qq linux-image-generic > /dev/null 2>&1
    VMLINUZ=$(find /boot -name "vmlinuz-*" -type f 2>/dev/null | sort -V | tail -1)
    HEADERS_DIR=$(find /usr/src -maxdepth 1 -name "linux-headers-*" -type d 2>/dev/null | sort -V | tail -1)
    if [ -n "$HEADERS_DIR" ] && [ -f "$HEADERS_DIR/scripts/extract-vmlinux" ]; then
        sudo "$HEADERS_DIR/scripts/extract-vmlinux" "$VMLINUZ" > "$WORKDIR/vmlinux" 2>/dev/null || true
    fi
    # Fallback: direct gzip extraction
    if [ ! -f "$WORKDIR/vmlinux" ] || [ "$(stat -c%s "$WORKDIR/vmlinux" 2>/dev/null)" -lt 1000000 ]; then
        OFFSET=$(LC_ALL=C sudo grep -aboP '\x1f\x8b\x08' "$VMLINUZ" 2>/dev/null | head -1 | cut -d: -f1)
        if [ -n "$OFFSET" ]; then
            sudo dd if="$VMLINUZ" bs=1 skip="$OFFSET" 2>/dev/null | gunzip > "$WORKDIR/vmlinux" 2>/dev/null
        fi
    fi
    echo "     Kernel: $(file "$WORKDIR/vmlinux")"
fi

# Build rootfs
if [ -f "$WORKDIR/rootfs.ext4" ] && [ "$(stat -c%s "$WORKDIR/rootfs.ext4")" -gt 10000000 ]; then
    echo "     Rootfs already present."
else
    echo "     Building rootfs with Bun (this takes a few minutes)..."
    ROOTFS="$WORKDIR/rootfs"
    sudo rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"

    sudo apt-get install -y -qq debootstrap e2fsprogs > /dev/null 2>&1
    sudo debootstrap --arch=arm64 --variant=minbase \
        --include=systemd,systemd-sysv,udev,dbus,iproute2,curl,ca-certificates,unzip \
        noble "$ROOTFS" http://ports.ubuntu.com/ubuntu-ports/

    # Install Bun
    sudo chroot "$ROOTFS" bash -c '
        curl -fsSL https://bun.sh/install | bash
        ln -sf /root/.bun/bin/bun /usr/local/bin/bun
        /usr/local/bin/bun --version
    '

    # Hello world script
    sudo tee "$ROOTFS/root/hello.ts" > /dev/null <<'BUNEOF'
console.log("Hello from Bun inside Firecracker!");
console.log(`Bun version: ${Bun.version}`);
console.log(`Platform: ${process.platform} ${process.arch}`);
BUNEOF

    # Systemd service to run hello world on boot
    sudo tee "$ROOTFS/etc/systemd/system/bun-hello.service" > /dev/null <<'SVCEOF'
[Unit]
Description=Run Bun Hello World
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bun run /root/hello.ts
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
    sudo chroot "$ROOTFS" systemctl enable bun-hello.service

    # Auto-login on serial console
    sudo mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"
    sudo tee "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" > /dev/null <<'LOGINEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
LOGINEOF

    # Passwordless root
    sudo sed -i 's|^root:[^:]*:|root::|' "$ROOTFS/etc/shadow"

    echo "firecracker-bun" | sudo tee "$ROOTFS/etc/hostname" > /dev/null
    printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" | sudo tee "$ROOTFS/etc/resolv.conf" > /dev/null

    # Pack into ext4
    dd if=/dev/zero of="$WORKDIR/rootfs.ext4" bs=1M count=512 status=none
    mkfs.ext4 -q "$WORKDIR/rootfs.ext4"
    MOUNT_DIR=$(mktemp -d)
    sudo mount "$WORKDIR/rootfs.ext4" "$MOUNT_DIR"
    sudo cp -a "$ROOTFS"/* "$MOUNT_DIR"/
    sudo umount "$MOUNT_DIR"
    rmdir "$MOUNT_DIR"
    sudo rm -rf "$ROOTFS"

    echo "     Rootfs: $(ls -lh "$WORKDIR/rootfs.ext4" | awk '{print $5}')"
fi

# Write Firecracker VM config
cat > "$WORKDIR/vm_config.json" <<CFGEOF
{
  "boot-source": {
    "kernel_image_path": "$WORKDIR/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$WORKDIR/rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 512
  }
}
CFGEOF

echo "     Setup complete. Files in $WORKDIR:"
ls -lh "$WORKDIR"/*.ext4 "$WORKDIR"/vmlinux "$WORKDIR"/vm_config.json
INNER_SETUP

echo "[4/4] Done!"
echo ""
echo "To run the microVM interactively:"
echo "  $SCRIPT_DIR/run.sh"
echo ""
echo "To run and just capture the Bun output:"
echo "  $SCRIPT_DIR/run-and-capture.sh"
