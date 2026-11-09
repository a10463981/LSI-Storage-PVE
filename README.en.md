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
# 1. download and unpack (pin to a Release tag, not a raw main-branch link)
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.03/LSI-Storage-PVE-0.1.03.tar.gz
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.03/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
tar xzf LSI-Storage-PVE-0.1.03.tar.gz && cd LSI-Storage-PVE-0.1.03

# 2. health check first (read-only, changes nothing)
sudo ./installer/install.sh doctor

# 3. install (bring your own LSA package, see below)
sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip

# 4. open http://<pve-host>:2463
```

Set a login password afterwards (LSA authenticates against system accounts):

```bash
sudo chroot /opt/lsi-storage/rootfs passwd lsiadmin
```

## Requirements

| | |
|---|---|
| OS | PVE 7.x / 8.x (Debian 11/12), systemd running |
| Privileges | root |
| Disk | ≥ 2 GB free on the filesystem holding `/opt` |
| Ports | 2463 and 9000 free (change with `--port` / `--backend-port`) |
| Network | reachable `mirrors.tuna.tsinghua.edu.cn`, or install offline with `--rootfs-file` |
| Hardware | a MegaRAID card visible to the host. **Installs fine without one** — the console will just be empty |
| Not needed | no apt, no Docker, no host reboot |

## Where to get the LSA package

LSA is proprietary Broadcom software and is **not** redistributed here. You supply it:

- Typically named `008.018.012.000_MR_7.38_LSA_Linux.zip` (~166 MB)
- Vendor support portals (Dell/HPE/Inspur/Huawei…) usually offer it without registration;
  or Broadcom support → your card model → Management Software (account required)
- It must contain the **`gcc_8.3.x`** baseline — builds against `gcc_14.2.x` require AVX and
  fail with `CPU ISA level is lower than required` on virtual CPUs

If `--lsa-package` is missing, the installer stops at the preflight stage and prints this
guidance instead of failing halfway.

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

1. **Materialise a standalone Ubuntu 24.04 rootfs** (`ubuntu-base`, hard SHA256 check) at
   `/opt/lsi-storage/rootfs`
2. **Install LSA inside that chroot**: `apt-get install` the runtime dependencies, `dpkg -i`
   the `gcc_8.3.x` debs, then apply compatibility patches (library symlinks, ports, log level,
   a pre-created account)
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
