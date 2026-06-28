# Dell/OEM → generic Intel X710 crossflash: procedure & rationale

This is the procedure `crossflash.sh` automates, why each step exists, and the
recovery story. Distilled from the community sources below plus testing on a
Dell-OEM X710-DA2.

## Sources

- mietzen, *How to crossflash intel X710 OEM cards* (the canonical guide):
  https://gist.github.com/mietzen/736583d37a1d370273c0775aaaa57aa5
- Level1Techs, *Crossflashing Intel official firmware on Dell/Lenovo X710-DA2
  (Solved)*:
  https://forum.level1techs.com/t/crossflashing-intel-official-firmware-on-dell-lenovo-pcie-x710-da2-nics-solved/196357
- Intel Ethernet NVM Update Tool — Quick Usage Guide (Linux):
  https://cdrdv2-public.intel.com/332161/

## Why OEM cards are locked

OEM-branded X710s carry vendor data in **VPD** (e.g. Dell shows `MN=1028`,
`PN=Y5M7N`) even when the PCI subsystem id looks generic. On that firmware:

- `bootutil -FD` (disable option-ROM) returns **"Unsupported feature"**, and
- stock `nvmupdate` reports `update="0"` and refuses the card.

So the option-ROM can't be disabled — which hangs UEFI-only boards that dispatch
it at POST and have no per-device option-ROM toggle. Crossflashing to generic
Intel firmware removes the lock.

## The procedure

1. **Identify the card and its etrack id.** `ethtool -i <iface>` →
   `firmware-version: 5.40 0x80002e8d ...` → etrack `80002E8D`.

2. **Confirm SPI flash size.** 700-series cards ship with 4 MB or 8 MB flash.
   **Using an image built for the wrong size is the #1 hard-brick cause.** A full
   NVM dump's byte size is the ground truth (8 MB = 8,388,608 bytes). The tool
   makes this a hard gate: it won't flash unless a backup of the matching size
   exists.

3. **Load the QV driver.** `bootutil` talks to the card through Intel's
   `iqvlinux` kernel module. On kernel >= 6.8, `iommu_present()` was removed, so
   `inc/linux/linuxdefs.h` must gate `NAL_IOMMU_API_PRESENT` with
   `&& LINUX_VERSION_CODE < KERNEL_VERSION(6,8,0)`. If bootutil reports
   *"inaccessible device memory"*, boot with `iomem=relaxed` so the QV driver can
   map device memory.

4. **Replace the OEM option-ROM first** — `bootutil64e -NIC=N -up=combo`. The
   community is consistent that nvmupdate "refuses to deal with" the Dell OROM,
   so it's swapped for Intel's combined image (`BootIMG.FLB`) first. Say **Yes**
   to the "create restore image" prompt.

5. **Inject the etrack into `nvmupdate.cfg`.** nvmupdate decides candidacy by
   matching `REPLACES` etrack + VENDOR + DEVICE. Append the card's etrack to the
   `REPLACES:` line of the block whose `NVM IMAGE` is your target image. Edit the
   shipped cfg in place (a hand-written cfg is often rejected; the modified
   original works). Note the cfg uses **CRLF** line endings — keep them.

6. **Flash the NVM** — `nvmupdate64e -u -m <MAC> -rd -b -s`. `-rd` resets Dell
   user settings to default (needed for OEM cards), `-b` keeps a backup, `-m`
   restricts to one card, `-s` is silent. **Do not interrupt or power off.**

7. **Cold power-cycle.** Full A/C off — a warm reboot will not load the new NVM.

8. **Verify, then disable the option-ROM** — `ethtool -i` should show 9.x; then
   `bootutil64e -NIC=N -FD` now succeeds (no longer OEM-locked), which is what
   stops the UEFI-only board from hanging.

Do **one card at a time**, proving each end-to-end before the next.

## Recovery

Tiered — and the only *unrecoverable* tier is the one the step-2 size gate
prevents:

- **Wrong card options / "kinda bricked"** — `nvmupdate64e -rd` resets the card
  to factory defaults; on its own this has rescued cards after a bad flash. (It's
  why the flash step always passes `-rd`.)
- **Soft fail** (interrupted, recovery mode) — the X710 enters Firmware Recovery
  Mode; re-flash, or restore the saved backup via
  `bootutil -RESTOREIMAGE -FILE=<backup>` (or re-run nvmupdate in EFI), then
  cold-cycle.
- **Hard brick — flash-size mismatch only** — a 4M image on an 8M card (or
  vice-versa) corrupts the chip so it won't enumerate, and **no software path
  recovers it**: you need a hardware SPI flasher (CH341A + SOIC-8 clip) to write
  the backup back. This is the single reported unrecoverable case. Confirming
  flash size up front — and the tool's size gate — is what keeps you out of it.

Keep the pre-flash NVM backup in at least two places.
