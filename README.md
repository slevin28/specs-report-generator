# System Specs Report Generator

Small Windows and macOS scripts for generating a local HTML system specification report.

## Files

- `windows-specs.bat` generates a Windows system specification report, including touchscreen capability, activation status, connectivity, basic storage health, and available management-state checks.
- `mac-specs.command` generates a macOS system specification report using Lion-compatible Bash, storage detection, connectivity checks, basic SMART status, and available management-state checks.

## Buyer-Facing Checks

Where the operating system exposes trustworthy data, reports include RAM slots used/free, Wi-Fi generation, Ethernet link state/speed, fingerprint and optical-drive detection, keyboard-backlight detection, basic storage health, and laptop-only built-in display size/refresh rate.

Management checks report only status, never credentials or bypass codes. Depending on platform and manufacturer, these can include domain or directory binding, MDM enrollment, BIOS or firmware password state, Absolute/Computrace state, and Mac Activation Lock state. Unsupported or ambiguous checks are labeled `Unknown`, `Not reported`, or `Not exposed` instead of being presented as negative results.

## Privacy Note

Generated reports may include device identifiers such as serial numbers, computer names, battery information, and hardware details. Windows activation is reported only as a status; no product key is collected. Do not commit generated `*_SystemReport.html` files to this repository.

## Usage

### Windows

Double-click `windows-specs.bat`. The report will be saved to the current user's Desktop and opened automatically.

### macOS

Double-click `mac-specs.command`. The report will be saved to the current user's Desktop and opened automatically.

The script is designed to run on OS X Lion 10.7 and newer. Its report uses layout features compatible with Lion's Safari 5.1.

If macOS blocks the script, clear quarantine attributes for your local copy:

```sh
xattr -cr /path/to/mac-specs.command
```
