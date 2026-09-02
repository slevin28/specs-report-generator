# System Specs Report Generator

Small Windows, macOS, and ChromeOS tools for generating a local HTML system specification report.

## Files

- `windows-specs.bat` generates a Windows system specification report, including touchscreen capability, activation status, connectivity, basic storage health, and available management-state checks.
- `windows-specs-xp.vbs` is the Windows XP compatibility reporter automatically launched by `windows-specs.bat` on XP. Keep both Windows files in the same folder.
- `mac-specs.command` generates a macOS system specification report using Lion-compatible Bash, storage detection, connectivity checks, basic SMART status, and available management-state checks.
- `chromeos-specs.html` is a standalone, offline ChromeOS report generator. It requires no extension, installation, developer mode, or Google sign-in and is designed to work in a Guest session.

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
