#!/bin/bash
set -e

VM_NAME="firecracker"

echo "Starting Firecracker microVM (capturing output)..."

limactl shell "$VM_NAME" -- sudo bash -c '
    WORKDIR=~/firecracker-env
    rm -f "$WORKDIR/firecracker.sock" "$WORKDIR/vm_output.log"

    firecracker --api-sock "$WORKDIR/firecracker.sock" --config-file "$WORKDIR/vm_config.json" > "$WORKDIR/vm_output.log" 2>&1 &
    FC_PID=$!

    TIMEOUT=60
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if grep -q "Hello from Bun inside Firecracker" "$WORKDIR/vm_output.log" 2>/dev/null; then
            echo ""
            echo "=== Bun Hello World Output ==="
            grep -A3 "Hello from Bun" "$WORKDIR/vm_output.log"
            echo "==============================="
            echo ""
            echo "SUCCESS! Bun ran inside Firecracker microVM."
            kill $FC_PID 2>/dev/null || true
            exit 0
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        printf "."
    done

    echo ""
    echo "Timeout. Last 30 lines:"
    tail -30 "$WORKDIR/vm_output.log"
    kill $FC_PID 2>/dev/null || true
    exit 1
'
