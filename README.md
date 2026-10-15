# System Specs Report Generator

Small Windows, macOS, Ubuntu, and ChromeOS tools for generating a local HTML system specification report.

## Files

- `windows-specs.bat` generates a Windows system specification report, including touchscreen capability, activation status, connectivity, basic storage health, and available management-state checks.
- `windows-specs-xp.vbs` is the Windows XP compatibility reporter automatically launched by `windows-specs.bat` on XP. Keep both Windows files in the same folder.
- `mac-specs.command` generates a macOS system specification report using Lion-compatible Bash, storage detection, connectivity checks, basic SMART status, and available management-state checks.
- `chromeos-specs.html` is a standalone, offline ChromeOS report generator. It requires no extension, installation, developer mode, or Google sign-in and is designed to work in a Guest session.

- `Ubuntu Specs.exe` is the native Linux USB entry point for Intel/AMD PCs; `Ubuntu Specs ARM64.exe` supports ARM64 Ubuntu. Keep them beside `ubuntu-specs.sh`.
- `ubuntu-specs.sh` generates an Ubuntu Desktop report with native UDisks SMART health, optional `smartctl` fallback, and an optional Desktop/app-menu launcher.
- `README-Ubuntu.txt` contains USB and click-to-run instructions.

## Buyer-Facing Checks

Where the operating system exposes trustworthy data, reports include RAM slots used/free, Wi-Fi generation, Ethernet link state/speed, fingerprint and optical-drive detection, keyboard-backlight detection, basic storage health, and laptop-only built-in display size/refresh rate.

Management checks report only status, never credentials or bypass codes. Depending on platform and manufacturer, these can include domain or directory binding, MDM enrollment, BIOS or firmware password state, Absolute/Computrace state, and Mac Activation Lock state. Unsupported or ambiguous checks are labeled `Unknown`, `Not reported`, or `Not exposed` instead of being presented as negative results.

## Privacy Note

Generated reports may include device identifiers such as serial numbers, computer names, battery information, and hardware details. Windows activation is reported only as a status; no product key is collected. Do not commit generated `*_SystemReport.html` files to this repository.

## Usage

### Windows

Double-click `windows-specs.bat`. The report will be saved to the current user's Desktop and opened automatically.

On Windows XP, the batch launcher automatically uses the companion `windows-specs-xp.vbs` reporter because PowerShell is not included with XP. The compatibility report uses XP-native WMI and Windows Script Host. Checks unavailable on XP are labeled as unsupported or unknown.

### macOS

Double-click `mac-specs.command`. The report will be saved to the current user's Desktop and opened automatically.

The script is designed to run on OS X Lion 10.7 and newer. Its report uses layout features compatible with Lion's Safari 5.1.

If macOS blocks the script, clear quarantine attributes for your local copy:

```sh
xattr -cr /path/to/mac-specs.command
```

### Ubuntu Desktop

Designed for Ubuntu Desktop 24.04 and newer; no package installation is performed.
Double-click **Ubuntu Specs.exe** in the USB folder on an Intel/AMD PC, or
**Ubuntu Specs ARM64.exe** on ARM64 Ubuntu. These are native, statically linked
Linux ELF programs; no Windows/Wine, Go, FUSE, or AppImage runtime is needed on
the target. They locate `ubuntu-specs.sh` beside themselves and open a terminal
to run it. USB labels, usernames, mount paths, and working directories can vary.
The terminal stays open until Enter is pressed. No per-computer shortcut setup
is required.

The `.exe` extension is deliberate: Ubuntu's default FAT `showexec` mount option
only assigns execute permissions to `.exe`, `.com`, and `.bat` files. The launchers
pass arguments directly to the terminal and Bash, including paths with spaces.
An explicit `noexec` mount or local policy can still block execution. If that
happens, or the file manager opens a Windows handler, open the USB folder in a
terminal and run:

```sh
bash ubuntu-specs.sh
```

Optionally, create a Desktop shortcut and app-menu entry on that Ubuntu session:

```sh
bash ubuntu-specs.sh --install-launcher
```

Then open **Ubuntu Specs** from the Desktop or Show Applications. If Ubuntu asks,
right-click the Desktop icon and select **Allow Launching**. The launcher invokes
Bash directly, so a USB mounted with `noexec` can still host the script. Keep the
USB connected; recreate the shortcut if its mount path changes. In a live session,
repeat launcher setup after reboot. `--no-sudo` skips the hardware-access password
prompt. Run as a regular user; accept the password prompt for DMI and optional
`smartctl` queries.

HTML and JSON reports are saved in `Reports` beside the script. Firefox opens the
HTML automatically; a home-folder preview is used for Firefox Snap. Hardware
queries are read-only. Launcher setup separately writes shortcuts to the current
user's Desktop and application directory.

SMART health primarily reads the same UDisks service used by GNOME Disks through
system Python's Gio bindings, including SATA/ATA health and NVMe critical warnings.
Reports show the service's cached update time. Zero/unavailable timestamps, disabled
SMART, and hidden USB/RAID health never produce a PASS. Bad sectors, failing
attributes, and prior failed self-tests are surfaced as warnings. Existing
`smartctl` is an optional fallback; the script never enables SMART or starts tests.
Some utilities for extra fields, such as `iw`, `ethtool`, `realm`, and `nvidia-smi`,
may be absent. The report labels missing data instead of installing software.

Validation:

```sh
bash -n ubuntu-specs.sh
python3 -W error -m unittest discover -s tests -p 'test_ubuntu_specs.py' -v
GO111MODULE=off go test ./tools/ubuntu-usb-launcher
```

To rebuild both USB executables with Go installed on the development machine:

```sh
bash tools/build-ubuntu-usb-launchers.sh
```

The tests simulate service/hardware responses, shortcut setup, and native-launcher terminal invocation. A real Ubuntu
Desktop run is still needed to validate machine-specific hardware, display-session,
and file-manager behavior. Linux ELF headers and static linking are checked at build time; the Linux binaries have not been executed here.

### ChromeOS

1. Put `chromeos-specs.html` on a USB drive or download it to the Chromebook.
2. Open a regular or Guest session, then double-click the file in the Files app.
3. Import the ChromeOS Diagnostics text log. Then paste the complete Crosh output from `diag battery_health` into **Add captured ChromeOS details** and select **Add to report**. Previously populated values are preserved. Individual report fields are review-only and do not need to be completed.
4. Select **Save HTML Report** and save the finished report to USB before leaving Guest mode.

You can also save a ChromeOS Diagnostics session log and select **Import text file**. The importer recognizes common CPU, memory, battery, device, and ChromeOS fields. For raw battery capacity, open Crosh with `Ctrl`+`Alt`+`T`, run `diag battery_health`, copy its output, and add it to the report. ChromeOS Diagnostics is available on ChromeOS 90 and newer.

`chrome://system` is optional because bulk selection is not reliable across ChromeOS versions. Only use it when that device provides a working **Copy all** or **Save as text** control; otherwise skip it without entering fields individually.

ChromeOS intentionally prevents ordinary local pages from reading serial number, exact model, physical storage health, battery health/cycles, and enterprise-management state. The generator labels missing protected values as `Not exposed` and never treats them as negative results. All detection and log parsing happens locally; the tool makes no network requests.

No single-field entry is required. If a value is absent from all bulk captures, leave it absent; the report will label it accurately rather than blocking generation.

Guest-mode files are deleted when the Guest session ends. Keep the generator on USB and save or move the finished report to USB before signing out.

The USB launch design follows [Nautilus 46 file activation](https://github.com/GNOME/nautilus/blob/46.0/src/nautilus-mime-actions.c)
and [UDisks 2.10.1 default mount options](https://github.com/storaged-project/udisks/blob/udisks-2.10.1/data/builtin_mount_options.conf).
An execution-blocked USB requires the terminal fallback; the launcher does not
change mount options, file associations, or system settings.
