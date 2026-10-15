CTRL ALT RECYCLE - UBUNTU SPECS
Version 1.3.0

Designed for Ubuntu Desktop 24.04 and newer, including Try Ubuntu sessions.
No packages are installed. Keep ubuntu-specs.sh on a writable USB drive.

RUN DIRECTLY FROM THE USB (NO SHORTCUT SETUP)
1. Open the USB folder in Ubuntu Files.
2. Double-click Ubuntu Specs.exe for an ordinary 64-bit Intel/AMD PC.
   For a computer running ARM64 Ubuntu, use Ubuntu Specs ARM64.exe instead.
3. A terminal opens and runs ubuntu-specs.sh from the same USB folder.
4. Enter your Ubuntu password for hardware read access. Press Ctrl+D to skip.
   Live Ubuntu usually does not require a password. Do not use sudo to start
   the whole program.
5. HTML and JSON reports go into Reports beside the script. Firefox opens HTML.
   For Firefox Snap, a preview copy is also saved in ~/CtrlAltRecycle-Preview.
   Press Enter in the terminal when finished.

Keep the .exe files and ubuntu-specs.sh together. The launcher finds its own
folder, so USB names, mount paths, and usernames do not need to match.
Nothing is installed; no Desktop/app-menu shortcut or trust metadata is needed.

THE .EXE FILES ARE NATIVE LINUX PROGRAMS
They are static Linux ELF executables. They do not require Windows, Wine, Go,
FUSE, an AppImage runtime, or any downloaded packages on the Ubuntu computer.
This USB is FAT-formatted. Ubuntu normally mounts FAT with showexec, which only
gives executable permissions to .exe/.com/.bat filenames. The .exe suffix handles
that restriction; it does not make the program a Windows executable.
The actual report collector remains the readable ubuntu-specs.sh file.

IF THE COMPUTER BLOCKS USB EXECUTION
A noexec mount or local policy can still prevent any USB program from starting.
Double-clicking cannot override that computer's mount policy.
Open the USB folder in Files, right-click empty space > Open in Terminal, enter:
   bash ubuntu-specs.sh
No installation or launcher setup is needed for this fallback either.
To skip the password prompt entirely:
   bash ubuntu-specs.sh --no-sudo
On a filesystem supporting Unix permissions, Properties > Permissions > Allow
executing file as program may be needed if copying removed the executable bit.
If the file manager offers Run as a Program instead of launching on double-click,
use that action. Use the terminal fallback if it offers a Windows/Wine application.

OPTIONAL DESKTOP/APP-MENU SHORTCUT
This is optional; it is not needed for USB launch. To create one, enter:
   bash ubuntu-specs.sh --install-launcher
Keep the USB connected and recreate the shortcut if its mount path changes.

SMART HEALTH
Uses Ubuntu's UDisks service, the backend for GNOME Disks, via system Python Gio.
SATA: reports SMART failure, bad sectors, failing attributes, past failures.
NVMe: reports controller critical warnings and failed self-test status if exposed.
The report shows when UDisks last updated its cached data. This is a snapshot,
not a new disk test, a surface scan, or a guarantee of drive condition.
Missing/uncollected/disabled SMART stays Unknown, never an assumed PASS.
An existing smartctl installation is an optional fallback; it is not required
when UDisks exposes the drive's health. USB bridges and RAID may hide health.
No drive settings are changed; no SMART enable, repair, or self-test is run.

OTHER LIMITATIONS
Missing utilities or permissions can leave some fields Unknown/Tool unavailable.
Firmware may misreport RAM slots or hide security/management state.
BIOS passwords and Absolute/Computrace require a manual firmware check.
Reports include serial numbers and other device identifiers.
Launcher setup creates shortcuts in your own Desktop and application directory.
The collector only reads hardware; it writes report files and Firefox previews.

VERIFICATION
Bash/Python syntax and automated simulated SATA/NVMe/failure tests pass.
Native-launcher tests cover path resolution, terminal selection and argument
transport. Both Linux architectures compile to static ELF binaries.
A real Ubuntu hardware/desktop test is still required; development was on macOS.
The previous CAR-SPECS.sh and ReadMeUbuntu.txt are preserved as .bak files on USB.
