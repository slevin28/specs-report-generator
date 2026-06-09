# System Specs Report Generator

Small Windows and macOS scripts for generating a local HTML system specification report.

## Files

- `windows-specs.bat` generates a Windows system specification report.
- `mac-specs.command` generates a macOS system specification report.

## Privacy Note

Generated reports may include device identifiers such as serial numbers, computer names, battery information, and hardware details. Do not commit generated `*_SystemReport.html` files to this repository.

## Usage

### Windows

Double-click `windows-specs.bat`. The report will be saved to the current user's Desktop and opened automatically.

### macOS

Double-click `mac-specs.command`. The report will be saved to the current user's Desktop and opened automatically.

If macOS blocks the script, clear quarantine attributes for your local copy:

```sh
xattr -cr /path/to/mac-specs.command
```
