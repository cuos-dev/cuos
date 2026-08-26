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

## 🧭 Supported Platforms

CuOS currently targets:

- x86_64 system images
- ARM64 Raspberry Pi images for Pi 3, Pi 4, Pi 5 and Zero 2
- LXC-based deployments
- Legacy ARM32 Raspberry Pi support for Pi 1, Pi 2, and Zero — status: legacy
- Board-specific embedded targets such as Orange Pi Zero 3 — status: alpha, example

Note: some platform integrations are intentionally limited and are kept as compatibility or reference implementations. The ARM32 Raspberry Pi path is legacy and requires matching Docker target architectures (`linux/arm/v7` for Pi 2 and `linux/arm/v6` for Pi 1 / Zero). Orange Pi Zero 3 support relies on a board-specific boot chain: kernel, DTB, and U-Boot. See [Platform and Architecture Support](docs/common/platform-support.md) for details.

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
