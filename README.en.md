# Broadcom LSA Controller for Debian / PVE

English | [中文](README.md)

Run the full Broadcom LSI Storage Authority (LSA) console on a **Proxmox VE host (Debian 11/12)**.
Open `http://<pve-host>:2463` and watch your MegaRAID array. No storcli, no Docker, no host
reboot, and nothing installed into the host's package set.

> Sister project (fnOS): [LSI-Storage-Fnos](https://github.com/a10463981/LSI-Storage-Fnos)
> Both share one core; this repo pulls it in as a `vendor/core/` snapshot.

**Status: first release (0.1.03).** The installer is feature-complete; end-to-end installation
on a real PVE host has not been verified yet — see "Not yet verified" below.

## Quick start

```bash
# 1. download and unpack (~66 MB, bundles the Ubuntu runtime + LSA)
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.04/LSI-Storage-PVE-0.1.04.tar.gz
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.04/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
tar xzf LSI-Storage-PVE-0.1.04.tar.gz && cd LSI-Storage-PVE-0.1.04

# 2. health check first (read-only, changes nothing)
sudo ./installer/install.sh doctor

# 3. install (offline, 1–2 minutes; no LSA package needed)
sudo ./installer/install.sh install

# 4. set a login password, then open http://<pve-host>:2463
sudo chroot /opt/lsi-storage/rootfs passwd lsiadmin
```

**No network, no apt, no Docker, no host reboot.** The installer only unpacks the runtime,
writes your ports, installs a systemd unit and starts it.

## Requirements

| | |
|---|---|
| OS | PVE 7.x / 8.x (Debian 11/12), systemd running |
| Privileges | root |
| Disk | ≥ 2 GB free on the filesystem holding `/opt` |
| Ports | 2463 and 9000 free (change with `--port` / `--backend-port`) |
| Hardware | a MegaRAID card visible to the host. **Installs fine without one** — the console will just be empty |
| Not needed | no network, no LSA package, no apt, no Docker, no host reboot |

## Why the tarball is 66 MB

Because it **ships a ready-to-run environment**: Ubuntu 24.04 base + Broadcom LSA
(the `gcc_8.3.x` baseline) + runtime dependencies, ~66 MB compressed, ~101 MB unpacked.

The alternative — ship only scripts and build on the target — means the target needs network
access to a mirror, needs a 166 MB LSA installer you supply separately, and runs `apt-get`
inside a chroot. Both paths fail more often on a PVE host. We chose "download once, install offline".

**The payload contains Broadcom's proprietary LSA binaries** (owned by Broadcom; Ubuntu by
Canonical). It is meant for personal use on hardware you own; our own code is MIT.
See "Notice and license" at the end.

## Advanced: build from source with your own LSA package

If you already have the LSA installer and the host has network access, skip the payload:

```bash
sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip
```

That path downloads the Ubuntu base, `apt-get install`s dependencies inside the chroot and
`dpkg -i`s LSA — 10–20 minutes. The package must contain the **`gcc_8.3.x`** baseline;
newer baselines require AVX and fail with `CPU ISA level is lower than required` on virtual CPUs.

## Subcommands

```
install.sh doctor                read-only health check (no root required)
install.sh install               fresh install
install.sh status                unit / ports / API state
install.sh upgrade               replace rootfs, keep config, keep the old one for rollback
install.sh rollback --to <path>  roll back
install.sh uninstall [--purge]   uninstall, then assert zero residue
install.sh repair                whitelisted fixes only
```

Options: `--lsa-package` `--rootfs-file` `--port` `--backend-port` `--prefix` `--timeout`
`--yes` `--dry-run` `--force` `--purge`.

`--dry-run` prints every action without writing anything, so it is safe to try on any machine.

## How it works

Three steps:

1. **Verify and unpack the runtime bundled in the tarball** (`payload/rootfs.tar.gz`, hard
   SHA256 check) into `/opt/lsi-storage/rootfs` — no network, no apt
2. **Write your ports**: the LSA configs inside the payload keep port placeholders, replaced at
   install time with `--port` / `--backend-port`; then idempotently verify three library symlinks
3. **Register `lsa-pve.service`**: `Type=oneshot` + `RemainAfterExit=yes` with
   `PrivateMounts=yes`, so systemd gives the unit its own mount namespace. Mounts die with the
   unit, which is why this tooling **never calls `umount`** and cannot touch the host's
   `/dev`, `/proc` or `/sys`.

**A note on apt**: every `apt-get` call runs inside `chroot /opt/lsi-storage/rootfs`. That is a
different system with its own `/etc/apt` and package database. The host's apt is never used —
even a broken host apt index cannot affect this. On the host, the installer only uses
`systemctl` and plain file operations.

## Uninstall

```bash
sudo ./installer/install.sh uninstall --purge
```

Stops and removes the unit, clears residual mounts under our prefix, deletes `/opt/lsi-storage`,
config and logs, then asserts zero residue (directory / unit / config / mounts) and prints the result.

## Relationship with the fnOS project

The build core is not maintained here; it is synced one-way into `vendor/core/`:

```bash
scripts/sync-core.sh --from /path/to/LSI-Storage-Fnos
scripts/sync-core.sh --check --from /path/to/LSI-Storage-Fnos   # CI gate
```

The current snapshot pins `CORE_VERSION` 0.1.03; the upstream commit is in `UPSTREAM`.
Any hand edit inside `vendor/core/` is caught by `--check`.

## Not yet verified

1. Full install on a clean PVE host (only `doctor` and `--dry-run` have run, on a Debian 12 box)
2. Whether `--port` actually relocates the LSA front end (do the 8 placeholders cover every reference?)
3. `upgrade` rootfs swap and `rollback`
4. `uninstall --purge` zero-residue assertions
5. Controller enumeration, VD/PD state, rebuild progress on real hardware
6. Whether `readonly_access_groups` really blocks writes
7. PVE 8.x / Debian 12 vs PVE 7.2 / Debian 11 differences

## Notice and license

This is an **unofficial third-party integration**, not affiliated with, endorsed by, or
authorized by Broadcom Inc. Broadcom, LSI, MegaRAID and LSI Storage Authority are trademarks or
registered trademarks of Broadcom Inc.

Our code is MIT licensed. Broadcom's LSA installer and the Ubuntu root filesystem belong to
Broadcom and Canonical respectively and are not covered by that license; you supply them yourself.
