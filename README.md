# firec

Run a Bun hello world inside a [Firecracker](https://github.com/firecracker-microvm/firecracker) microVM.

Separate setups for **macOS** (via Lima + nested virtualization) and **Linux** (direct KVM).

## Quick start

### macOS (Apple Silicon, macOS 13+)

```bash
cd mac
./setup.sh            # installs Lima, creates VM, installs Firecracker + kernel + rootfs
./run-and-capture.sh  # boots microVM, prints Bun output, kills VM
./run.sh              # boots microVM with interactive serial console
```

Requires [Homebrew](https://brew.sh). Setup installs Lima automatically.

### Linux (Ubuntu, x86_64 or arm64)

```bash
cd linux
./setup.sh            # installs Firecracker, extracts kernel, builds rootfs with Bun
./run-and-capture.sh  # boots microVM, prints Bun output, kills VM
./run.sh              # boots microVM with interactive serial console
```

Requires KVM (`/dev/kvm`). If not accessible, add your user to the `kvm` group:

```bash
sudo usermod -aG kvm $USER
```

## What it does

`setup.sh` prepares three things:

1. **Firecracker** v1.12.0 binary
2. **Linux kernel** extracted from the host
3. **Root filesystem** (minimal Ubuntu 24.04 + Bun) as an ext4 image

The microVM boots with 2 vCPUs and 512MB RAM. A systemd service runs `bun hello.ts` on boot, then the VM stays alive with a root shell on the serial console.

## Example output

```
$ ./run-and-capture.sh
Starting Firecracker microVM (capturing output)...
............
=== Bun Hello World Output ===
[   18.923845] bun[174]: Hello from Bun inside Firecracker!
[   18.949359] bun[174]: Bun version: 1.3.11
[   18.955430] bun[174]: Platform: linux arm64
[  OK  ] Finished bun-hello.service - Run Bun Hello World.
===============================

SUCCESS! Bun ran inside Firecracker microVM.
```

## Architecture

```
macOS host                          Linux host
┌─────────────────────────┐         ┌─────────────────────────┐
│  Lima VM (vz + KVM)     │         │  KVM                    │
│  ┌───────────────────┐  │         │  ┌───────────────────┐  │
│  │  Firecracker       │  │         │  │  Firecracker       │  │
│  │  ┌──────────────┐ │  │         │  │  ┌──────────────┐ │  │
│  │  │ Linux + Bun  │ │  │         │  │  │ Linux + Bun  │ │  │
│  │  └──────────────┘ │  │         │  │  └──────────────┘ │  │
│  └───────────────────┘  │         │  └───────────────────┘  │
└─────────────────────────┘         └─────────────────────────┘
```

On macOS, Lima provides a Linux VM with nested virtualization so Firecracker can use KVM. On Linux, Firecracker runs directly.
