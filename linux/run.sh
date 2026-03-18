#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$SCRIPT_DIR/firecracker-env"

if [ ! -f "$WORKDIR/vm_config.json" ]; then
    echo "Run setup.sh first."
    exit 1
fi

rm -f "$WORKDIR/firecracker.sock"

echo "=== Starting Firecracker microVM (interactive) ==="
echo "Bun hello world runs automatically on boot."
echo "After boot, you get a root shell inside the microVM."
echo "Press Ctrl+C to kill the VM."
echo "==================================================="
echo ""

sudo firecracker --api-sock "$WORKDIR/firecracker.sock" --config-file "$WORKDIR/vm_config.json"
