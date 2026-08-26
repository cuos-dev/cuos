# CuOS – Container Update OS

**CuOS** (short for **Container Update OS**) is a revolutionary operating system built entirely from Docker container images. It brings the power, flexibility, and familiarity of container development to the world of operating systems.

---

## 🚀 What is CuOS?

CuOS is a minimal, reliable, and automatically updating operating system that is **generated from a Docker container image**. This means:

- You define your OS as a container.
- You deploy it like a container.
- You update it like a container.

If you know how to build and manage Docker containers, you already know how to manage CuOS.

---

## ✅ Why CuOS?

### 🔄 Familiar Workflow

CuOS uses the same tools and workflows you already use for container development. No need to learn a new packaging system or configuration language.

### 🧰 All Your Tools, All Your Knowledge

Since CuOS is built from a container image, **everything you know about Docker applies**:

- Use your existing Dockerfiles.
- Reuse your CI/CD pipelines.
- Leverage your container registries.

### 🔧 Automatic Updates & Rollbacks

CuOS includes a built-in update container that:

- Automatically checks for updates.
- Applies them safely.
- Rolls back if something goes wrong.

### 🧪 Repeatable & Reliable

Every CuOS system is built from a versioned container image, ensuring:

- High reproducibility.
- Easy testing and validation.
- Consistent deployments across fleets.

### 🛳️ Fleet-Ready

CuOS is designed for **mass deployment**:

- Perfect for edge devices, kiosks, and embedded systems.
- Easy to manage across thousands of nodes.

---

## 📛 Why the Name "CuOS"?

**CuOS** stands for **Container Update OS**:

- **Container**: The OS is built from a container image.
- **Update**: It updates itself automatically and safely.
- **OS**: It’s a full operating system, ready to boot and run.

---

## 📦 Getting Started

For system administrators looking to deploy services using CuOS, please visit [cuos-iac](https://github.com/cuos-dev/cuos-iac/), our Infrastructure as Code repository. It provides tools and templates for deploying and managing services on CuOS.

For developers looking to create custom CuOS-based systems, check out our [CuOS Development Guide](docs/development-guide.md).

---

## 🧭 Supported Platforms

| Platform | Boards / form factor | Docker platform | Support level |
|---|---|---|---|
| x86_64 | BIOS and UEFI machines, VMs | `linux/amd64` | Supported |
| LXC | Containers on an LXC host | `linux/amd64` | Supported |
| Raspberry Pi 64-bit | Pi 3, Pi 4, Pi 5, Zero 2 | `linux/arm64` | Supported |
| Raspberry Pi 32-bit | Pi 1, Pi 2, Zero | `linux/arm/v6` | Legacy — may be removed |
| Orange Pi Zero 3 | Orange Pi Zero 3 only | `linux/arm64` | Example — that board only |

**32-bit Raspberry Pi** is a legacy compatibility target. The image is built for `linux/arm/v6`, so a single image covers Pi 1, Pi 2 and Zero. Debian provides no usable ARMv6 base for these boards, so this target is built from the Raspberry Pi OS repositories instead. Note that most upstream projects no longer publish 32-bit ARM images at all — CuOS may boot while the application containers you want do not exist for the board. This support may be removed in a future release.

**Orange Pi Zero 3** is kept as a worked example of a board-specific boot chain — kernel, device tree blob (DTB) and U-Boot at fixed image offsets — rather than as a ready-made target. An image is published as `cuos-system-orangepi-zero3`, but it is tuned for that exact board and will not boot on anything else.

See [Platform and Architecture Support](docs/common/platform-support.md) for the boot chains, the constraints behind these levels, and what adding a new board involves.

---

## 📄 License

CuOS is open-source and licensed under the **Apache License, Version 2.0**.

Please refer to the [LICENSE.txt](LICENSE.txt) file for full license details, and to [NOTICE](NOTICE) for attribution. Each source file carries an `SPDX-License-Identifier` line.

## Disclaimer

This software is provided without warranty. See [DISCLAIMER.md](DISCLAIMER.md) for more information.

---

## 🤝 Contributing

We welcome contributions! Please check out our [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 📣 Stay Tuned

More documentation, examples, and community links coming soon. Follow us for updates!
