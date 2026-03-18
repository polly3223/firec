#!/bin/bash
set -e

VM_NAME="firecracker"

echo "=== Starting Firecracker microVM (interactive) ==="
echo "Bun hello world runs automatically on boot."
echo "After boot, you get a root shell inside the microVM."
echo "Press Ctrl+C to kill the VM."
echo "==================================================="
echo ""

limactl shell "$VM_NAME" -- sudo bash -c '
    WORKDIR=~/firecracker-env
    rm -f "$WORKDIR/firecracker.sock"
    firecracker --api-sock "$WORKDIR/firecracker.sock" --config-file "$WORKDIR/vm_config.json"
'
