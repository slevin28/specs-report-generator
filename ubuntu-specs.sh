#!/usr/bin/env bash
# Ctrl Alt Recycle Ubuntu Desktop inventory. Hardware queries are read-only.
# Run: bash ubuntu-specs.sh; use --install-launcher for a desktop/app shortcut.
set -u
if [ "$(uname -s)" != Linux ]; then
    echo 'Run this on Ubuntu Desktop (24.04 or newer).' >&2
    exit 1
fi
if [ "${EUID}" -eq 0 ]; then
    echo 'Run: bash ubuntu-specs.sh (without sudo). Only hardware read queries need elevation.' >&2
    exit 2
fi
if [ ! -x /usr/bin/python3 ]; then
    echo 'Python 3 is not available. This script targets Ubuntu Desktop.' >&2
    exit 1
fi
car_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
car_privilege_flags=()
car_setup=false
car_pause=false
car_skip_sudo=false
for car_arg in "$@"; do
    case "$car_arg" in
        --install-launcher|--help|-h|--render-json) car_setup=true ;;
        --wait) car_pause=true ;;
        --no-sudo) car_skip_sudo=true ;;
    esac
done
if ! "$car_setup" && ! "$car_skip_sudo" && command -v sudo >/dev/null 2>&1; then
    echo 'Enter your Ubuntu password for hardware read access, or press Ctrl+D to skip.'
    if sudo -v; then car_privilege_flags=(--sudo); else echo 'Continuing with limited permissions.'; fi
fi
/usr/bin/python3 -I - --script-path "$car_script_dir/$(basename -- "${BASH_SOURCE[0]}")" --output-dir "$car_script_dir/Reports" --open ${car_privilege_flags[@]+"${car_privilege_flags[@]}"} "$@" <<'CAR_PYTHON'
#!/usr/bin/env python3
"""Ctrl Alt Recycle Ubuntu inventory. Python 3.12; read-only hardware queries.

Run as a normal desktop user. --sudo permits sudo -n for a fixed set of queries.
No shell, networking, repairs, self-tests, partition writes or firmware changes.
"""
import argparse
import datetime as dt
import html
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys

VERSION = "1.3.0-ubuntu"
UNKNOWN = "Unknown"
MANUAL = "Unknown—manual firmware check required"
STATUS_TEXT = {"unknown": UNKNOWN, "not_detected": "Not detected",
               "permission_required": "Permission required", "tool_unavailable": "Tool unavailable"}


def field(value=None, source="", status=None, detail=""):
    return {"status": status or ("detected" if value is not None else "unknown"),
            "value": value, "source": source, "detail": detail}


def text(f):
    if not isinstance(f, dict):
        return str(f)
    value = f.get("value")
    base = str(value) if value is not None else STATUS_TEXT.get(f.get("status"), UNKNOWN)
    return base + (" — " + f["detail"] if f.get("detail") else "")


def number(v, default=None):
    try:
        return int(v)
    except (ValueError, TypeError):
        return default


def capacity(v, binary=False):
    if v is None:
        return UNKNOWN
    base, units = (1024, ["B", "KiB", "MiB", "GiB", "TiB"]) if binary else (1000, ["B", "KB", "MB", "GB", "TB"])
    n = float(v)
    for u in units:
        if abs(n) < base or u == units[-1]:
            return f"{n:.2f}".rstrip("0").rstrip(".") + " " + u
        n /= base


def clean(v):
    if not v or v.strip().lower() in {"unknown", "not specified", "none", "to be filled by o.e.m.",
                                    "default string", "system serial number", "not provided", "n/a"}:
        return None
    return v.strip()


class Probe:
    def __init__(self, sudo=False):
        self.sudo = sudo
        self.diagnostics = []
        self._udisks = None
        self.env = dict(os.environ, LC_ALL="C", LANG="C",
                        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")

    def run(self, args, privileged=False, timeout=12):
        exe = shutil.which(args[0], path=self.env["PATH"])
        if not exe:
            result = {"status": "tool_unavailable", "stdout": "", "stderr": "", "returncode": None}
        else:
            cmd = [exe] + args[1:]
            if privileged and os.geteuid() != 0:
                if not self.sudo or not shutil.which("sudo", path=self.env["PATH"]):
                    result = {"status": "permission_required", "stdout": "", "stderr": "", "returncode": None}
                    self.diagnostics.append({"command": args, **result})
                    return result
                cmd = ["/usr/bin/sudo", "-n", "--"] + cmd
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, errors="replace",
                                   env=self.env, timeout=timeout, check=False)
                denied = re.search(r"permission denied|operation not permitted|a password is required|not allowed to execute|authentication.*required", p.stderr + p.stdout, re.I)
                result = {"status": "permission_required" if denied else ("detected" if p.returncode == 0 else "unknown"),
                          "stdout": p.stdout, "stderr": p.stderr, "returncode": p.returncode}
            except subprocess.TimeoutExpired:
                result = {"status": "unknown", "stdout": "", "stderr": "Query timed out", "returncode": None}
            except OSError as e:
                result = {"status": "unknown", "stdout": "", "stderr": str(e), "returncode": None}
        self.diagnostics.append({"command": args, **result})
        return result

    def read(self, path):
        try:
            return field(Path(path).read_text(errors="replace").strip(), str(path))
        except PermissionError:
            return field(source=str(path), status="permission_required")
        except (OSError, ValueError):
            return field(source=str(path))


    def udisks(self):
        """Read one typed D-Bus snapshot, using Ubuntu Desktop's system PyGObject.

        GetManagedObjects only reads service properties. Never enable SMART,
        start a self-test, mount a volume, or change drive settings.
        """
        if self._udisks is not None:
            return self._udisks
        objects, status, detail = {}, "unknown", ""
        try:
            import gi
            gi.require_version("Gio", "2.0")
            from gi.repository import Gio
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            objects = bus.call_sync("org.freedesktop.UDisks2", "/org/freedesktop/UDisks2",
                                    "org.freedesktop.DBus.ObjectManager", "GetManagedObjects",
                                    None, None, Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
            status = "detected"
        except ImportError:
            status, detail = "tool_unavailable", "System Python Gio bindings unavailable"
        except Exception as e:
            detail = str(e)
            if re.search(r"AccessDenied|NotAuthorized|permission denied", detail, re.I):
                status = "permission_required"
        self._udisks = objects, status
        self.diagnostics.append({"command": ["UDisks2", "GetManagedObjects"],
                                 "status": status, "stderr": detail})
        return self._udisks


def failed(r, source, detail=""):
    return field(source=source, status=r["status"] if r["status"] != "detected" else "unknown", detail=detail)


def parse_dmi(raw):
    blocks = []
    for part in re.split(r"(?m)^Handle ", raw)[1:]:
        typ = re.search(r"DMI type (\d+)", part.splitlines()[0])
        if not typ:
            continue
        values = {}
        for line in part.splitlines()[2:]:
            m = re.match(r"\t([^\t:]+):\s*(.*)", line)
            if m:
                values[m[1]] = m[2].strip()
        blocks.append((int(typ[1]), values))
    return blocks


def memory_data(blocks, fallback):
    # Only system-memory arrays; ignore GPU memory arrays and caches.
    arrays = [b for t, b in blocks if t == 16 and b.get("Use") == "System Memory"]
    # Handles aren't needed on ordinary firmware: Type 17 entries are system DIMMs.
    # Filtering an explicit non-system Type 16 array is performed by collect().
    modules, sizes, uncertain = [], [], False
    entries = [b for t, b in blocks if t == 17]
    for b in entries:
        size = b.get("Size", "Unknown")
        if size in {"No Module Installed", "Not Installed", "0 MB", "0 GB"}:
            continue
        m = re.fullmatch(r"(\d+) (kB|KB|MB|GB|TB)", size)
        n = int(m[1]) * {"kB": 1024, "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}[m[2]] if m else None
        uncertain |= n is None
        if n is not None:
            sizes.append(n)
        modules.append({"slot": field(clean(b.get("Locator")) or clean(b.get("Bank Locator")), "SMBIOS Type 17"),
                        "capacity": field(capacity(n, True) if n is not None else None, "SMBIOS Type 17"),
                        "capacity_bytes": n, "type": field(clean(b.get("Type")), "SMBIOS Type 17"),
                        "speed": field(clean(b.get("Configured Memory Speed") or b.get("Configured Clock Speed")), "SMBIOS configured speed"),
                        "manufacturer": field(clean(b.get("Manufacturer")), "SMBIOS Type 17"),
                        "part_number": field(clean(b.get("Part Number")), "SMBIOS Type 17")})
    totals = [number(b.get("Number Of Devices")) for b in arrays]
    total_slots = sum(totals) if totals and all(x is not None for x in totals) else (len(entries) if entries else None)
    used = len(modules) if entries and not uncertain else None
    total_bytes = sum(sizes) if modules and not uncertain else None
    slots = field(f"{used} used / {total_slots} total / {total_slots-used} free (SMBIOS positions)" if
                  used is not None and total_slots is not None and total_slots >= used else None, "SMBIOS Types 16/17")
    if not entries:
        slots = fallback
    return {"modules": modules, "slots": slots, "installed_bytes": total_bytes,
            "total": field(capacity(total_bytes, True) if total_bytes is not None else None, "SMBIOS installed modules") if entries else fallback,
            "status": "detected" if entries else fallback["status"],
            "note": "Firmware reports memory positions; soldered RAM may be included. Speed is configured, not rated. OS-usable RAM can be lower."}


def pci_inventory(p):
    r = p.run(["lspci", "-Dnnk"])
    devices, item = [], None
    for line in r["stdout"].splitlines():
        m = re.match(r"^([0-9a-fA-F:.]+) (.+)", line)
        if m:
            item = {"address": m[1].lower(), "description": m[2], "driver": None}
            devices.append(item)
        elif item and "Kernel driver in use:" in line:
            item["driver"] = line.split(":", 1)[1].strip()
    return devices, r


def adapter(p, devpath, pci):
    resolved = str(Path(devpath).resolve())
    cur = Path(devpath).resolve()
    for parent in [cur] + list(cur.parents):
        v = p.read(parent / "product")["value"]
        if v:
            return field(v, "USB sysfs product")
    for dev in reversed(pci):
        if dev["address"] in resolved:
            return field(dev["description"], "lspci + sysfs device ancestry")
    driver = Path(devpath) / "driver"
    if driver.exists():
        return field(driver.resolve().name + " (model unknown)", "sysfs driver")
    return field(source="sysfs/lspci")


def flatten(nodes):
    out = {}
    def visit(n):
        key = n.get("path") or "/dev/" + n.get("kname", n.get("name", "?"))
        if key not in out:
            out[key] = n
        else:
            old = out[key]
            old["children"] = old.get("children", []) + n.get("children", [])
        for child in n.get("children", []):
            visit(child)
    for n in nodes:
        visit(n)
    return out


def smartctl_health(p, path):
    r = p.run(["smartctl", "-a", "-j", path], privileged=True, timeout=20)
    try:
        data = json.loads(r["stdout"])
    except (ValueError, TypeError):
        return failed(r, "smartctl -a -j", "Health not verified"), {}
    msgs = "; ".join(x.get("string", "") for x in data.get("smartctl", {}).get("messages", []))
    if r["status"] == "permission_required" or re.search(r"permission denied|operation not permitted", msgs, re.I):
        return field(source="smartctl", status="permission_required", detail="Health not verified"), data
    passed = data.get("smart_status", {}).get("passed")
    critical = data.get("nvme_smart_health_information_log", {}).get("critical_warning")
    rc = data.get("smartctl", {}).get("exit_status", r["returncode"]) or 0
    if passed is False or (isinstance(critical, int) and critical != 0) or rc & 8:
        return field("SMART FAIL / critical warning", "smartctl reported status"), data
    if passed is True:
        if rc & 7:
            return field("SMART reports PASS; query incomplete—review JSON", "smartctl"), data
        if rc & 240:
            return field("SMART reports PASS; error/attribute/log warnings—review JSON", "smartctl"), data
        return field("SMART reports PASS (not a full disk test)", "smartctl smart_status.passed"), data
    return field(source="smartctl", detail="SMART status inaccessible or unsupported; health not verified"), data


UDISKS = "org.freedesktop.UDisks2."


def udisks_health(p, path):
    objects, status = p.udisks()
    source = "Ubuntu UDisks2 (GNOME Disks backend)"
    if status != "detected":
        return field(source=source, status=status, detail="SMART health not verified"), {}
    # Use Block.Drive rather than guessing a drive object from its model/serial.
    # Device is a NUL-terminated D-Bus byte array; Symlinks are byte arrays too.
    drive = None
    for interfaces in objects.values():
        block = interfaces.get(UDISKS + "Block", {})
        names = [block.get("Device", [])] + list(block.get("Symlinks", []))
        if any(bytes(n).rstrip(b"\0").decode("utf-8", "replace") == path for n in names):
            drive = objects.get(block.get("Drive"), {})
            break
    if not drive:
        return field(source=source, detail="No UDisks drive health exposed for this device"), {}
    ata = drive.get(UDISKS + "Drive.Ata")
    nvme = drive.get(UDISKS + "NVMe.Controller")
    props = ata if ata is not None else nvme
    if props is None:
        return field(source=source, detail="SMART unsupported or hidden by USB/RAID/virtual device"), {}
    raw = {"source": source, "protocol": "ata" if ata is not None else "nvme", "properties": props}
    updated = number(props.get("SmartUpdated"), 0)
    if ata is not None and (props.get("SmartSupported") is not True or props.get("SmartEnabled") is not True):
        return field(source=source, detail="SMART unsupported or disabled; health not verified"), raw
    # UDisks explicitly says every other SMART property is meaningless if 0.
    if updated <= 0:
        return field(source=source, detail="SMART data not yet available; health not verified"), raw
    try:
        checked = dt.datetime.fromtimestamp(updated).astimezone().isoformat(timespec="seconds")
    except (OSError, OverflowError, ValueError):
        return field(source=source, detail="Invalid SMART timestamp; health not verified"), raw
    detail = f"UDisks snapshot {checked}; not a full disk test"
    if ata is not None:
        failing = props.get("SmartFailing")
        warnings = [f"{label}: {props[key]}" for key, label in (
            ("SmartNumBadSectors", "bad/pending/reallocated sectors"),
            ("SmartNumAttributesFailing", "failing attributes"),
            ("SmartNumAttributesFailedInThePast", "previously failed attributes"))
            if number(props.get(key), 0) > 0]
        last_test = props.get("SmartSelftestStatus", "")
        if last_test == "fatal" or last_test.startswith("error_"):
            warnings.append("last self-test: " + last_test)
        if failing is True:
            result = "SMART FAIL"
        elif warnings:
            result = "SMART WARNING: " + "; ".join(warnings)
        elif failing is False:
            result = "SMART reports PASS"
        else:
            return field(source=source, detail="SMART result missing; health not verified"), raw
    else:
        warnings = props.get("SmartCriticalWarning")
        if not isinstance(warnings, (list, tuple)):
            return field(source=source, detail="NVMe critical-warning status missing; health not verified"), raw
        result = "NVMe critical warning: " + ", ".join(warnings) if warnings else "NVMe reports no critical warnings"
        last_test = props.get("SmartSelftestStatus", "")
        if not warnings and last_test in {"fatal_error", "unknown_seg_fail", "known_seg_fail"}:
            result = "NVMe WARNING: last self-test " + last_test
    return field(result, source, detail=detail), raw


def smart_health(p, path):
    health, raw = udisks_health(p, path)
    if health["value"] is not None:
        return health, {"udisks": raw}
    # Optional compatibility fallback; never install packages automatically.
    fallback, smart = smartctl_health(p, path)
    if fallback["value"] is not None:
        return fallback, {**smart, "udisks": raw}
    health["detail"] += "; smartctl fallback: " + text(fallback)
    if health["status"] == "unknown" and fallback["status"] == "permission_required":
        health["status"] = "permission_required"
    return health, {**smart, "udisks": raw}


def storage_data(p, pci):
    columns = "NAME,KNAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA,RM,FSTYPE,LABEL,MOUNTPOINTS,PKNAME,WWN"
    r = p.run(["lsblk", "--bytes", "--json", "--output", columns])
    try:
        raw = json.loads(r["stdout"])
        nodes = raw["blockdevices"]
    except (ValueError, KeyError):
        return {"disks": [], "volumes": [], "count": None, "bytes": None, "status": r["status"], "note": "Disk inventory unavailable."}, {}, r
    allnodes = flatten(nodes)
    disks, volumes, counted, total = [], [], set(), 0
    controllers = [d for d in pci if "RAID bus controller" in d["description"] or d["driver"] in {"megaraid_sas", "hpsa", "smartpqi", "cciss", "arcmsr"}]
    for path, n in allnodes.items():
        typ = n.get("type", "")
        if typ not in {"disk", "rom", "part", "loop"}:
            volumes.append({"device": path, "type": typ, "size": capacity(number(n.get("size"))),
                            "included_in_total": False})
        if typ != "disk":
            continue
        k = n.get("kname", n.get("name"))
        ancestry = str(Path("/sys/class/block", k, "device").resolve())
        owned = [c for c in controllers if c["address"] in ancestry]
        model = clean(n.get("model"))
        virtual = bool(re.search(r"virtual|logical|raid|qemu|vmware|vbox", model or "", re.I) or "virtio" in ancestry)
        kind = "Controller virtual disk" if virtual and owned else ("Virtual disk" if virtual else ("Controller disk—physical/virtual unknown" if owned else "OS-visible disk (no virtual indication)"))
        children = list(flatten([n]).values())
        mounts = [m for c in children for m in (c.get("mountpoints") or []) if m]
        usb = n.get("tran") == "usb" or "/usb" in ancestry
        confirmed = usb and any(m in {"/cdrom", "/isodevice", "/run/live/medium", "/run/archiso/bootmnt"} for m in mounts)
        iso = usb and any(c.get("fstype") in {"iso9660", "udf"} for c in children)
        media = "USB live/install media (mounted boot medium)" if confirmed else ("USB ISO media—possible installer; verify" if iso else ("USB disk (purpose unknown)" if usb else "System/storage disk"))
        # Exclude confirmed boot media only; a USB disk is not automatically an installer.
        key = clean(n.get("wwn")) or path
        include = not confirmed and key not in counted
        if include:
            counted.add(key)
            total += number(n.get("size"), 0)
        health, smart = smart_health(p, path)
        if virtual or owned:
            dtype = field("Unknown (controller)" if owned else "Unknown (virtual)", source="controller/virtual presentation", status="unknown")
        elif smart.get("rotation_rate") == 0 or smart.get("device", {}).get("type") == "nvme" or n.get("tran") == "nvme":
            dtype = field("SSD", "SMART/NVMe")
        elif number(smart.get("rotation_rate"), 0) > 0:
            dtype = field("HDD", "SMART rotation rate")
        elif n.get("rota") in {True, 1}:
            dtype = field("HDD (kernel rotational flag)", "lsblk ROTA")
        else:
            dtype = field("Non-rotating (SSD/flash; unverified)" if n.get("rota") in {False, 0} else None, "lsblk ROTA")
        disks.append({"device": field(path, "lsblk"), "model": field(model, "lsblk"),
                      "capacity": field(capacity(number(n.get("size"))), "lsblk"), "capacity_bytes": number(n.get("size")),
                      "type": dtype, "bus": field(clean(n.get("tran")), "lsblk TRAN"),
                      "serial": field(clean(n.get("serial")) or clean(smart.get("serial_number")), "lsblk/SMART"),
                      "health": health, "presentation": kind, "media": media,
                      "included_in_total": include, "smart": smart,
                      "controller": [c["description"] for c in owned], "identity_key": key})
    note = "SMART uses Ubuntu UDisks2 cached health with its update time; smartctl is an optional fallback. No self-tests run. Totals count unique OS-visible disks; exclude confirmed USB boot media, partitions, loop devices and software RAID/LVM/crypt volumes. Capacity is raw, not usable filesystem space."
    if controllers or any("virtual" in d["presentation"].lower() for d in disks):
        note += " RAID/virtual presentation detected: a controller may hide physical members. Physical member count, capacities and health are unknown; controller-specific inventory is required. Virtual-disk SMART does not verify members."
    return {"disks": disks, "volumes": volumes, "count": len(counted), "bytes": total,
            "status": "detected", "controllers": controllers, "note": note}, allnodes, r


def connectivity(p, pci, ls_nodes, inventory_status="detected"):
    wifi, ethernet = [], []
    for n in sorted(Path("/sys/class/net").glob("*")):
        if n.name == "lo" or not (n / "device").exists():
            continue
        model = adapter(p, n / "device", pci)
        is_wifi = (n / "wireless").exists() or (n / "phy80211").exists()
        if is_wifi:
            phy = (n / "phy80211").resolve().name
            r = p.run(["iw", "phy", phy, "info"])
            standard = None
            # Capabilities, not association speed, establish the highest standard.
            for pattern, label in [(r"EHT (Iftypes|Capabilities|MAC|PHY)", "802.11be / Wi-Fi 7"),
                                   (r"HE (Iftypes|Capabilities|MAC|PHY)", "802.11ax / Wi-Fi 6; 6E unknown"),
                                   (r"VHT Capabilities", "802.11ac / Wi-Fi 5"),
                                   (r"HT Capabilities|HT20/HT40|HT RX MCS", "802.11n / Wi-Fi 4")]:
                if re.search(pattern, r["stdout"]):
                    standard = label
                    break
            wifi.append({"interface": n.name, "adapter": model,
                         "standard": field(standard, "iw phy capabilities", detail="Highest exposed capability" if standard else "") if standard else failed(r, "iw phy capabilities")})
        elif p.read(n / "type")["value"] == "1":
            carrier = p.read(n / "carrier")
            speed = p.read(n / "speed")
            rate = number(speed["value"])
            link = field(f"{rate} Mb/s negotiated" if rate and rate > 0 and carrier["value"] == "1" else
                         ("No link negotiated" if carrier["value"] == "0" else None), "sysfs carrier/speed")
            if link["value"] is None:
                er = p.run(["ethtool", n.name])
                es = re.search(r"Speed:\s*(\d+)Mb/s", er["stdout"])
                el = re.search(r"Link detected:\s*(yes|no)", er["stdout"])
                if es and el and el[1] == "yes":
                    link = field(es[1] + " Mb/s negotiated", "ethtool")
                elif el and el[1] == "no":
                    link = field("No link negotiated", "ethtool")
                else:
                    link = failed(er, "ethtool/sysfs")
            if link["value"] is None and speed["status"] == "permission_required":
                link = speed
            ethernet.append({"interface": n.name, "adapter": model, "link": link})
    # Also surface unbound PCI network hardware.
    if not wifi:
        wifi = [{"interface": "unbound", "adapter": field(d["description"], "lspci"),
                 "standard": field(detail="No Wi-Fi interface/capabilities exposed")}
                for d in pci if "Network controller" in d["description"] and re.search(r"wireless|wi-fi|802\.11", d["description"], re.I)]
    if not ethernet:
        ethernet = [{"interface": "unbound", "adapter": field(d["description"], "lspci"),
                     "link": field(detail="No Ethernet interface exposed")} for d in pci if "Ethernet controller" in d["description"]]
    bluetooth = [adapter(p, x / "device", pci) for x in Path("/sys/class/bluetooth").glob("hci*")]
    touch, fingerprint, input_statuses = [], [], []
    for event in Path("/sys/class/input").glob("event*"):
        r = p.run(["udevadm", "info", "--query=property", "--path", str(event)])
        input_statuses.append(r["status"])
        if "ID_INPUT_TOUCHSCREEN=1" in r["stdout"]:
            touch.append(p.read(event / "device/name")["value"] or event.name)
    # libfprint-backed readers via a read-only D-Bus call; never enroll/authenticate.
    fr = p.run(["gdbus", "call", "--system", "--dest", "net.reactivated.Fprint", "--object-path",
                "/net/reactivated/Fprint/Manager", "--method", "net.reactivated.Fprint.Manager.GetDevices"])
    fingerprint = re.findall(r"/net/reactivated/Fprint/Device/[^'\s,)]+", fr["stdout"])
    usb = p.run(["lsusb"])
    usbfp = [line for line in usb["stdout"].splitlines() if re.search(r"fingerprint|validity sensors|synaptics.*(reader|sensor)", line, re.I)]
    usb_bt = [line for line in usb["stdout"].splitlines() if re.search(r"bluetooth", line, re.I)]
    optical = [field((clean(x.get("model")) or "Optical drive") + " (" + path + ")", "lsblk TYPE=rom")
               for path, x in ls_nodes.items() if x.get("type") == "rom"]
    leds = [x.name for x in Path("/sys/class/leds").glob("*") if "kbd_backlight" in x.name or "keyboard_backlight" in x.name]
    udev_missing = not shutil.which("udevadm", path=p.env["PATH"])
    missing_inputs = "permission_required" if "permission_required" in input_statuses else ("unknown" if "unknown" in input_statuses else "not_detected")
    return {"wifi": wifi, "ethernet": ethernet, "network_inventory_status": inventory_status,
            "bluetooth": field("; ".join(text(x) for x in bluetooth) or "; ".join(usb_bt) or None, "sysfs Bluetooth / lsusb",
                               status="detected" if bluetooth or usb_bt else ("not_detected" if usb["status"] == "detected" else usb["status"])),
            "touchscreen": field("; ".join(touch) if touch else None, "udev input properties",
                                 status="detected" if touch else ("tool_unavailable" if udev_missing else missing_inputs)),
            "fingerprint": field("; ".join(usbfp) or (f"Detected ({len(fingerprint)} libfprint reader(s))" if fingerprint else None), "libfprint D-Bus / USB names",
                                 status="detected" if fingerprint or usbfp else ("permission_required" if fr["status"] == "permission_required" else ("tool_unavailable" if fr["status"] == usb["status"] == "tool_unavailable" else "unknown")),
                                 detail="Driver support varies; absence is not proof of no reader" if not fingerprint and not usbfp else ""),
            "optical": optical, "keyboard_backlight": field("Detected: " + ", ".join(leds) if leds else None, "sysfs LED class", detail="Manual keyboard/firmware check required" if not leds else ""),
            "note": "Not detected means this scan found no device; disconnected/disabled hardware may be missed. Wi-Fi standard describes exposed capability, not current connection speed."}


def gnome_displays():
    try:
        import gi
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        result = bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                               "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None, None,
                               Gio.DBusCallFlags.NONE, 3500, None).unpack()
        monitors, logical = result[1], result[2]
        scales = {spec[0]: log[2] for log in logical for spec in log[5]}
        out = []
        for spec, modes, props in monitors:
            current = [m for m in modes if m[6].get("is-current")]
            out.append({"connector": field(spec[0], "GNOME Mutter"),
                        "model": field(props.get("display-name") or " ".join(x for x in spec[1:3] if x), "GNOME Mutter"),
                        "resolution": field(f"{current[0][1]} × {current[0][2]} @ {current[0][3]:.1f} Hz" if current else None, "GNOME current physical mode"),
                        "scale": scales.get(spec[0])})
        return out
    except Exception:
        return []


def display_data(p, pci):
    displays = gnome_displays() if os.geteuid() != 0 else []
    wayland = os.environ.get("XDG_SESSION_TYPE") == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
    if not displays and not wayland and os.environ.get("DISPLAY"):
        r = p.run(["xrandr", "--current"])
        for line in r["stdout"].splitlines():
            m = re.match(r"(\S+) connected(?: primary)?(?: (\d+)x(\d+)[+-]\d+[+-]\d+)?", line)
            if m:
                displays.append({"connector": field(m[1], "X11 xrandr"), "model": field(),
                                 "resolution": field(f"{m[2]} × {m[3]}" if m[2] else None, "X11 current mode")})
    if not displays:
        for x in Path("/sys/class/drm").glob("card*-*"):
            if p.read(x / "status")["value"] == "connected":
                displays.append({"connector": field(x.name, "DRM connector status"), "model": field(),
                                 "resolution": field(detail="Current mode unavailable; advertised modes are not current resolution")})
    nr = p.run(["nvidia-smi", "--query-gpu=pci.bus_id,name,memory.total,driver_version", "--format=csv,noheader,nounits"])
    nvidia = {}
    for line in nr["stdout"].splitlines():
        parts = [x.strip() for x in line.split(",")]
        if len(parts) == 4:
            nvidia[parts[0].lower()[-12:]] = parts
    gpus = []
    for d in pci:
        if not any(x in d["description"] for x in ["VGA compatible controller", "3D controller", "Display controller"]):
            continue
        dev = Path("/sys/bus/pci/devices", d["address"])
        model = d["description"]
        driver = d["driver"] or ((dev / "driver").resolve().name if (dev / "driver").exists() else None)
        intel_shared = "Intel" in model and bool(re.search(r"\b(UHD|HD Graphics|Iris)\b", model, re.I))
        if intel_shared:
            vram = field("Integrated/shared system memory; no dedicated VRAM reported", "Intel integrated model identification")
        elif d["address"] in nvidia and number(nvidia[d["address"]][2]) is not None:
            entry = nvidia[d["address"]]
            vram = field(capacity(int(entry[2]) * 1024**2, True) + " dedicated (driver reported)", "nvidia-smi memory.total")
            driver = (driver or "nvidia") + " " + entry[3]
        else:
            pool = number(p.read(dev / "mem_info_vram_total")["value"])
            vram = field(capacity(pool, True) + " driver VRAM pool; dedicated/shared classification unknown" if pool else None,
                         "amdgpu sysfs" if pool else "GPU driver", detail="No reliable dedicated-memory measurement" if not pool else "")
        gpus.append({"model": field(model, "lspci"), "driver": field(driver, "active kernel driver"), "vram": vram, "pci_address": d["address"]})
    if not gpus:
        for card in Path("/sys/class/drm").glob("card[0-9]*"):
            if "-" in card.name:
                continue
            drv = card / "device/driver"
            gpus.append({"model": field(source="lspci", status="tool_unavailable" if not shutil.which("lspci", path=p.env["PATH"]) else "unknown"),
                         "driver": field(drv.resolve().name if drv.exists() else None, "DRM sysfs"), "vram": field()})
    return {"displays": displays, "gpus": gpus, "gpu_inventory_status": "detected" if shutil.which("lspci", path=p.env["PATH"]) else "tool_unavailable", "note": "Physical pixel modes shown when exposed. Wayland uses GNOME state; Xwayland emulated sizes are not treated as physical modes. PCI aperture size is never used as VRAM."}


def battery_data(p):
    out = []
    for b in sorted(Path("/sys/class/power_supply").glob("*")):
        if p.read(b / "type")["value"] != "Battery" or p.read(b / "present")["value"] == "0":
            continue
        design = number(p.read(b / "energy_full_design")["value"])
        full = number(p.read(b / "energy_full")["value"])
        unit = "Wh"
        if not design or full is None:
            design = number(p.read(b / "charge_full_design")["value"])
            full = number(p.read(b / "charge_full")["value"])
            unit = "Ah"
        health = 100 * full / design if design and full is not None else None
        cycles = p.read(b / "cycle_count")
        # Zero is ambiguous in the power_supply ABI; don't promise a new battery.
        if cycles["value"] == "0":
            cycles = field(detail="Driver returned 0; zero cycles or unsupported")
        out.append({"battery": field(b.name, "power_supply sysfs"),
                    "design": field(f"{design/1e6:.2f} {unit}" if design else None, "power_supply design capacity"),
                    "full_charge": field(f"{full/1e6:.2f} {unit}" if full is not None else None, "power_supply full-charge capacity"),
                    "health": field(f"{health:.1f}%" if health is not None else None, "full/design × 100; not state of charge"),
                    "cycles": cycles, "status": p.read(b / "status")})
    return {"batteries": out, "status": "detected" if out else "not_detected"}


def root_encryption(p, nodes):
    r = p.run(["findmnt", "--json", "--target", "/", "--output", "SOURCE,FSTYPE"])
    try:
        root = json.loads(r["stdout"])["filesystems"][0]
    except (ValueError, KeyError, IndexError):
        return failed(r, "findmnt/lsblk")
    src, fs = root.get("source", ""), root.get("fstype", "")
    if fs in {"overlay", "squashfs", "tmpfs", "nfs", "nfs4", "cifs", "zfs"}:
        return field(detail=f"Root is {fs}; backing encryption not established", source="findmnt")
    source = src.split("[")[0]
    real = os.path.realpath(source)
    # Reverse parent links from lsblk's nested tree, including LVM on crypt on RAID.
    parents = {}
    for path, n in nodes.items():
        for c in n.get("children", []):
            cp = c.get("path") or "/dev/" + c.get("kname", c.get("name", "?"))
            parents.setdefault(cp, set()).add(path)
    matching = [path for path in nodes if os.path.realpath(path) == real]
    visited = set()
    def walk(path):
        if path in visited:
            return
        visited.add(path)
        for parent in parents.get(path, []):
            walk(parent)
    for path in matching:
        walk(path)
    if any(nodes[x].get("type") == "crypt" or nodes[x].get("fstype") == "crypto_LUKS" for x in visited):
        return field("Detected: dm-crypt/LUKS in root block-device ancestry", "findmnt + lsblk")
    if not matching:
        return field(source="findmnt + lsblk", detail="Root backing chain unresolved")
    return field("Not detected in visible root block-device ancestry", "findmnt + lsblk", status="not_detected",
                 detail="Does not rule out hardware encryption or fscrypt per-directory encryption")


def security_data(p, nodes):
    if Path("/sys/firmware/efi").exists():
        r = p.run(["mokutil", "--sb-state"])
        if "SecureBoot enabled" in r["stdout"]:
            secure = field("Enabled", "mokutil")
        elif "SecureBoot disabled" in r["stdout"]:
            secure = field("Disabled", "mokutil")
        else:
            ef = list(Path("/sys/firmware/efi/efivars").glob("SecureBoot-*"))
            try:
                v = ef[0].read_bytes()[4]
                secure = field("Enabled" if v == 1 else ("Disabled" if v == 0 else None), "UEFI SecureBoot variable")
            except PermissionError:
                secure = field(status="permission_required", source="UEFI SecureBoot variable")
            except (OSError, IndexError):
                secure = failed(r, "mokutil/UEFI variable")
    else:
        secure = field(source="No EFI sysfs", detail="EFI not exposed in current boot; firmware state not established")
    tpms = list(Path("/sys/class/tpm").glob("tpm[0-9]*"))
    tpm = field("; ".join(x.name + " (TPM " + (p.read(x / "tpm_version_major")["value"] or "version unknown") + ")" for x in tpms) if tpms else None,
                "sysfs TPM class", status="detected" if tpms else "not_detected", detail="Firmware may disable or hide TPM" if not tpms else "")
    r = p.run(["realm", "list"])
    if r["status"] == "detected" and r["stdout"].strip():
        domain = field("; ".join(x.strip() for x in r["stdout"].splitlines() if x and not x[0].isspace()), "realm list local configuration")
    elif r["status"] == "detected":
        domain = field("Not detected by realmd", "realm list", status="not_detected", detail="Other membership mechanisms may exist; no online trust test")
    else:
        domain = failed(r, "realm list", "Membership not established")
    return {"secure_boot": secure, "tpm": tpm, "domain": domain,
            "root_encryption": root_encryption(p, nodes),
            "bios_password": field(MANUAL, "No portable reliable firmware query", status="unknown"),
            "absolute": field(MANUAL, "No portable reliable firmware query", status="unknown"),
            "note": "Absence of a Linux agent does not establish Absolute/Computrace firmware state. Detection is an inventory snapshot, not a security certification."}


def collect(p):
    dmi = p.run(["dmidecode", "--type", "0,1,3,16,17"], privileged=True)
    blocks = parse_dmi(dmi["stdout"])
    # Filter Type 17 by their array handles to avoid adding non-system memory.
    system_handles, non_system_handles = set(), set()
    for part in re.split(r"(?m)^Handle ", dmi["stdout"])[1:]:
        if "DMI type 16," in part.splitlines()[0]:
            if re.search(r"(?m)^\tUse: System Memory$", part):
                system_handles.add(part.split(",", 1)[0])
            elif re.search(r"(?m)^\tUse: (Video Memory|Flash Memory|Non-volatile RAM|Cache Memory)$", part):
                non_system_handles.add(part.split(",", 1)[0])
    blocks = [(t, b) for t, b in blocks if t != 17 or b.get("Array Handle") not in non_system_handles]
    fallback = failed(dmi, "dmidecode", "SMBIOS unavailable")
    memory = memory_data(blocks, fallback)
    def dmi_field(typ, key, sysname=None):
        for t, b in blocks:
            if t == typ and clean(b.get(key)):
                return field(clean(b[key]), f"SMBIOS Type {typ}")
        if sysname:
            f = p.read(Path("/sys/class/dmi/id", sysname))
            f["value"] = clean(f["value"])
            if f["value"] is not None:
                return f
            if f["status"] == "permission_required":
                return f
        return fallback if not blocks else field(source=f"SMBIOS Type {typ}")
    chassis = dmi_field(3, "Type")
    if chassis["value"] is None:
        cr = p.read("/sys/class/dmi/id/chassis_type")
        types = {3:"Desktop",4:"Low-profile desktop",5:"Pizza box",6:"Mini tower",7:"Tower",8:"Portable",9:"Laptop",10:"Notebook",
                 11:"Handheld",12:"Docking station",13:"All-in-one",14:"Sub-notebook",15:"Space-saving",16:"Lunch box",17:"Main server chassis",
                 23:"Rack mount",24:"Sealed-case PC",30:"Tablet",31:"Convertible",32:"Detachable",33:"IoT gateway",34:"Embedded PC",35:"Mini PC",36:"Stick PC"}
        code = number(cr["value"])
        if code is not None:
            chassis = field(types.get(code, f"SMBIOS chassis code {code}"), cr["source"])
    cpu = p.run(["lscpu", "--json"])
    try:
        cv = {x["field"].rstrip(":"): str(x["data"]) for x in json.loads(cpu["stdout"])["lscpu"]}
    except (ValueError, KeyError):
        cv = {}
    topo = p.run(["lscpu", "--parse=CPU,CORE,SOCKET,ONLINE"])
    cores, threads = set(), set()
    for line in topo["stdout"].splitlines():
        if line.startswith("#"):
            continue
        vals = line.split(",")
        if len(vals) == 4:
            threads.add(vals[0])
            cores.add((vals[2], vals[1]))
    memtxt = p.read("/proc/meminfo")["value"] or ""
    match = re.search(r"MemTotal:\s+(\d+)", memtxt)
    usable = int(match[1])*1024 if match else None
    osinfo = p.read("/etc/os-release")["value"] or ""
    release = re.search(r'^PRETTY_NAME=[\'"]?(.+?)[\'"]?$', osinfo, re.M)
    installed = memory["total"] if memory["installed_bytes"] is not None else field(source="SMBIOS", status=memory["status"] if memory["status"] != "detected" else "unknown")
    if usable:
        installed = dict(installed, detail=f"OS usable: {capacity(usable, True)}" + ("; installed total unavailable" if installed["value"] is None else ""))
    general = {"manufacturer": dmi_field(1, "Manufacturer", "sys_vendor"), "model": dmi_field(1, "Product Name", "product_name"),
               "chassis": chassis, "serial": dmi_field(1, "Serial Number", "product_serial"),
               "cpu": field(cv.get("Model name"), "lscpu") if cv else failed(cpu, "lscpu"),
               "cores_threads": field(f"{len(cores)} cores / {len(threads)} threads (OS-visible)" if threads else None, "lscpu topology"),
               "ram": installed, "slots": memory["slots"], "ubuntu": field(release[1] if release else None, "/etc/os-release"),
               "kernel": field(os.uname().release, "uname"), "bios": dmi_field(0, "Version", "bios_version"),
               "boot": field("UEFI" if Path("/sys/firmware/efi").exists() else "Legacy BIOS (or EFI not exposed)", "EFI sysfs"),
               "hostname": field(socket.gethostname(), "hostname")}
    pci, pci_result = pci_inventory(p)
    storage, nodes, ls_result = storage_data(p, pci)
    return {"schema_version": 1, "collector_version": VERSION,
            "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "hostname": socket.gethostname(), "collection_mode": "Privileged validation environment" if os.geteuid() == 0 else ("sudo read queries enabled" if p.sudo else "unprivileged"),
            "general": general, "memory": memory, "connectivity": connectivity(p, pci, nodes, pci_result["status"]),
            "display": display_data(p, pci), "storage": storage, "battery": battery_data(p),
            "security": security_data(p, nodes), "diagnostics": p.diagnostics,
            "limitations": ["Firmware/driver data can be incomplete or inaccurate.", "Only read queries run; no SMART self-test or surface scan.",
                            "Hidden RAID members need controller-specific inspection.", "Current graphics mode requires a supported local desktop session."]}


CSS = """*{box-sizing:border-box}html{background:#e7ece9}body{font-family:Arial,Helvetica,sans-serif;color:#1d2f35;margin:0;font-size:12px;line-height:1.22}.report{max-width:1248px;margin:12px auto;padding:10px;background:#f9fbfa;border:1px solid #aab9b2;border-radius:9px;box-shadow:0 4px 24px #173d1e14}header{display:flex;align-items:center;justify-content:space-between;gap:20px;background:linear-gradient(110deg,#236875,#30882d);color:#fff;border-radius:7px;padding:13px 16px;margin-bottom:10px}.brand{display:flex;gap:6px;align-items:center;white-space:nowrap}.key{font-weight:700;background:#23383b;border:1px solid #becbc9;border-radius:5px;padding:9px 12px;box-shadow:inset 0 0 0 2px #ffffff20;font-size:17px}.key.recycle{background:#418034;font-size:24px;padding:3px 11px}h1{font-size:24px;letter-spacing:.4px;margin:0;text-align:right}.subtitle{font-size:10px;opacity:.85;margin-top:4px;text-align:right}.grid{display:grid;grid-template-columns:1fr 1fr;gap:9px}.column{display:flex;flex-direction:column;gap:9px;min-width:0}section{border:1px solid #aebbb6;border-radius:7px;padding:7px 9px;background:#fff;break-inside:avoid}h2{font-size:15px;text-transform:uppercase;letter-spacing:1px;margin:0 0 5px;border-bottom:1px solid #a8b6b0;padding-bottom:4px;color:#254b50}table{width:100%;border-collapse:collapse;table-layout:fixed}th,td{text-align:left;vertical-align:top;padding:2.5px 4px;overflow-wrap:anywhere}thead th{background:#e6eeeb;font-size:11px;border-bottom:1px solid #abbdb5}tbody tr+tr td{border-top:1px solid #e5ebe8}.kv td:first-child{width:37%;font-weight:bold}.modules,.gpu,.drives,.battery{font-size:11px}.note{font-size:10px;color:#526960;margin:6px 0 0;line-height:1.3}.total{font-weight:bold;font-size:12px;border-top:1px solid #c0cec7;margin-top:5px;padding-top:5px}.meta{display:flex;justify-content:space-between;align-items:center;font-size:10px;color:#53655e;margin-top:10px;gap:12px}.status-unknown,.status-tool_unavailable,.status-permission_required{color:#765824}.toolbar{display:flex;gap:8px;align-items:center;margin-bottom:9px;font-size:11px;color:#4b6659}button{border:1px solid #a6b9ae;border-radius:4px;background:#edf4ef;color:#234f35;padding:5px 10px;cursor:pointer;font:inherit}.legend{font-size:9px;color:#63786a;flex:1}.empty{padding:3px 0}.sub{font-size:10px;color:#526960;margin-top:2px}.diskmodel{font-weight:bold}.volumes{font-size:10px;color:#526960;margin-top:5px}@media(max-width:800px){.grid{grid-template-columns:1fr}.report{margin:5px}h1{font-size:18px}header{gap:10px}.key{padding:7px}.legend{display:none}}@page{size:A4 landscape;margin:8mm}@media print{html,body{background:white;font-size:10px;-webkit-print-color-adjust:exact;print-color-adjust:exact}.report{width:1060px;max-width:none;margin:0;padding:0;border:0;border-radius:0;box-shadow:none;zoom:var(--print-zoom,1)}header{padding:8px 12px;margin-bottom:6px}h1{font-size:20px}.key{font-size:14px;padding:6px 9px}.key.recycle{font-size:21px}.grid{grid-template-columns:1fr 1fr;gap:6px}.column{gap:6px}section{padding:5px 7px}h2{font-size:12px;margin-bottom:3px;padding-bottom:3px}th,td{padding:2px 3px}.modules,.gpu,.drives,.battery{font-size:9px}thead th{font-size:9px}.note,.sub,.volumes{font-size:8px;line-height:1.15;margin-top:3px}.total{font-size:10px;margin-top:3px;padding-top:3px}.meta{font-size:8px;margin-top:5px}.toolbar{display:none}}
""".replace("\\+", "")


def esc(v):
    return html.escape(str(v), quote=True)


def cell(v):
    if isinstance(v, dict):
        return '<span class="status-' + esc(v.get("status", "unknown")) + '" title="' + esc(v.get("source", "")) + '">' + esc(text(v)) + '</span>'
    return esc(v)


def kv(rows):
    return '<table class="kv"><tbody>' + ''.join('<tr><td>' + esc(k) + '</td><td>' + cell(v) + '</td></tr>' for k, v in rows) + '</tbody></table>'


def table(headings, rows, cls="", widths=None):
    cols = '<colgroup>' + ''.join(f'<col style="width:{w}%">' for w in widths) + '</colgroup>' if widths else ''
    return '<table class="' + cls + '">' + cols + '<thead><tr>' + ''.join('<th>' + esc(x) + '</th>' for x in headings) + '</tr></thead><tbody>' + ''.join('<tr>' + ''.join('<td>' + cell(x) + '</td>' for x in row) + '</tr>' for row in rows) + '</tbody></table>'


def section(title, content, note=""):
    return '<section><h2>' + esc(title) + '</h2>' + content + ('<p class="note">' + esc(note) + '</p>' if note else '') + '</section>'


def render(data):
    g, mem, c, dp, st, bat, sec = [data[k] for k in ("general", "memory", "connectivity", "display", "storage", "battery", "security")]
    labels = [("Manufacturer", "manufacturer"), ("Model", "model"), ("Chassis type", "chassis"), ("Serial / service tag", "serial"),
              ("Processor", "cpu"), ("Cores / threads", "cores_threads"), ("Installed RAM", "ram"), ("RAM positions", "slots"),
              ("Ubuntu version", "ubuntu"), ("Kernel", "kernel"), ("BIOS version", "bios"), ("Boot mode", "boot"), ("Hostname", "hostname")]
    left = section("General System", kv([(label, g[key]) for label, key in labels]))
    if mem["modules"]:
        mcontent = table(["Slot", "Capacity", "DDR type", "Config. speed", "Manufacturer", "Part number"],
                         [[m[k] for k in ("slot", "capacity", "type", "speed", "manufacturer", "part_number")] for m in mem["modules"]], "modules", [13, 12, 12, 17, 18, 28])
    else:
        mcontent = '<div class="empty">' + cell(field(status=mem["status"], detail="Module inventory unavailable")) + '</div>'
    left += section("Memory Modules", mcontent + '<div class="total">Total memory: ' + cell(mem["total"]) + '</div>', mem["note"])
    net_status = c.get("network_inventory_status", "detected")
    w = field("; ".join(x["interface"] + ": " + text(x["adapter"]) + "; " + text(x["standard"]) for x in c["wifi"])) if c["wifi"] else field(status="not_detected" if net_status == "detected" else net_status)
    e = field("; ".join(x["interface"] + ": " + text(x["adapter"]) + "; " + text(x["link"]) for x in c["ethernet"])) if c["ethernet"] else field(status="not_detected" if net_status == "detected" else net_status)
    o = field("; ".join(text(x) for x in c["optical"])) if c["optical"] else field(status=st["status"] if st["status"] != "detected" else "not_detected")
    left += section("Connectivity & Features", kv([("Wi-Fi adapter / standard", w), ("Ethernet / link speed", e),
                    ("Bluetooth", c["bluetooth"]), ("Touchscreen", c["touchscreen"]), ("Fingerprint reader", c["fingerprint"]),
                    ("Optical drives", o), ("Keyboard backlight", c["keyboard_backlight"])]), c["note"])
    displays = '<div class="empty">Not detected — no connected display exposed</div>' if not dp["displays"] else kv([(text(d["connector"]), field((text(d["model"]) + "; " if d["model"].get("value") else "") + text(d["resolution"]) + (f'; scale {d["scale"]}×' if d.get("scale") else ""))) for d in dp["displays"]])
    gpu = table(["GPU model", "Active driver", "Graphics memory"], [[x["model"], x["driver"], x["vram"]] for x in dp["gpus"]], "gpu", [43, 18, 39]) if dp["gpus"] else '<div class="empty">' + cell(field(status=dp.get("gpu_inventory_status", "unknown"), detail="GPU inventory unavailable")) + '</div>'
    right = section("Display & Graphics", displays + gpu, dp["note"])
    diskrows = []
    for d in st["disks"]:
        model = {"value": text(d["model"]) + "; " + d["presentation"] + ("; " + d["media"] if d["media"].startswith("USB") else ""), "status": "detected"}
        diskrows.append([d["device"], model, d["capacity"], d["type"], d["bus"], d["serial"], d["health"]])
    ds = table(["Device", "Model / presentation", "Size", "Type", "Bus", "Serial", "SMART health"], diskrows, "drives", [10, 23, 10, 13, 7, 14, 23]) if diskrows else '<div class="empty">' + cell(field(status=st["status"] if st["status"] != "detected" else "not_detected")) + '</div>'
    ds += '<div class="total">Counted disks: ' + esc(st["count"] if st["count"] is not None else UNKNOWN) + ' &nbsp; • &nbsp; Raw capacity: ' + esc(capacity(st["bytes"])) + '</div>'
    if st["volumes"]:
        ds += '<div class="volumes">Logical volumes (excluded from totals): ' + esc('; '.join(f'{v["device"]}: {v["type"]}, {v["size"]}' for v in st["volumes"])) + '</div>'
    right += section("Storage Drives", ds, st["note"])
    bc = table(["Battery", "Design", "Full charge", "Health", "Cycles", "Status"], [[b[k] for k in ("battery", "design", "full_charge", "health", "cycles", "status")] for b in bat["batteries"]], "battery") if bat["batteries"] else '<div class="empty">No battery detected.</div>'
    right += section("Battery Health", bc)
    right += section("Management & Security", kv([("Secure Boot", sec["secure_boot"]), ("TPM", sec["tpm"]), ("Domain membership", sec["domain"]),
                                                ("Root-volume encryption", sec["root_encryption"]), ("BIOS password", sec["bios_password"]), ("Absolute / Computrace", sec["absolute"])]), sec["note"])
    embedded = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    return '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>System Specification Report — ' + esc(data["hostname"]) + '</title><style>' + CSS + '</style></head><body><main class="report"><header><div class="brand" aria-label="Ctrl Alt Recycle"><span class="key">Ctrl</span><span class="key">Alt</span><span class="key recycle">♻</span></div><div><h1>System Specification Report</h1><div class="subtitle">CONTROL ALT RECYCLE &nbsp; / &nbsp; UBUNTU INVENTORY</div></div></header><div class="toolbar"><button onclick="window.print()">Print report</button><button id="json-button">Save JSON</button><span class="legend">Not detected: scan found none · Unknown: not established · Permission required: access blocked · Tool unavailable: utility missing</span></div><div class="grid"><div class="column">' + left + '</div><div class="column">' + right + '</div></div><footer class="meta"><span>Read-only inventory · Collector ' + VERSION + ' · ' + esc(data["collection_mode"]) + '</span><span>Generated ' + esc(data["generated_at"].replace("T", " ")) + '</span></footer></main><script type="application/json" id="report-data">' + embedded + '</script><script>window.addEventListener("beforeprint",function(){const r=document.querySelector(".report");r.style.setProperty("--print-zoom","1");const h=r.getBoundingClientRect().height;r.style.setProperty("--print-zoom",String(Math.min(1,720/h)))});window.addEventListener("afterprint",function(){document.querySelector(".report").style.removeProperty("--print-zoom")});document.getElementById("json-button").onclick=function(){const blob=new Blob([document.getElementById("report-data").textContent],{type:"application/json"});const a=document.createElement("a");a.href=URL.createObjectURL(blob);a.download=location.pathname.split("/").pop().replace(/\\.html$/,".json");a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)};</script></body></html>'


def desktop_quote(value):
    # Desktop Entry Exec quoting has two layers: string and argument escapes.
    value = str(value).replace("%", "%%")
    value = re.sub(r'([\\"`$])', lambda m: "\\" + m[0], value)
    return '"' + value.replace("\\", "\\\\") + '"'


def install_launcher(script):
    script = script.resolve()
    terminal = shutil.which("gnome-terminal")
    if not terminal:
        raise OSError("GNOME Terminal unavailable; run bash ubuntu-specs.sh from a terminal")
    command = " ".join(desktop_quote(x) for x in [terminal, "--", "/usr/bin/bash", str(script), "--wait"])
    entry = ("[Desktop Entry]\nType=Application\nVersion=1.0\n"
             "Name=Ubuntu Specs — Ctrl Alt Recycle\n"
             "Comment=Generate a local system specification and SMART health report\n"
             f"Exec={command}\nIcon=computer\nTerminal=false\nCategories=System;Utility;\n")
    apps = Path(os.environ.get("XDG_DATA_HOME") or Path.home()/".local/share")/"applications"
    apps.mkdir(parents=True, exist_ok=True)
    targets = [apps/"ctrl-alt-recycle-ubuntu-specs.desktop"]
    xdg = shutil.which("xdg-user-dir")
    if xdg:
        result = subprocess.run([xdg, "DESKTOP"], capture_output=True, text=True, check=False)
        desktop = Path(result.stdout.strip())
        if result.returncode == 0 and desktop.is_absolute() and desktop != Path.home():
            desktop.mkdir(parents=True, exist_ok=True)
            targets.append(desktop/"Ubuntu Specs.desktop")
    gio = shutil.which("gio")
    for target in targets:
        target.write_text(entry, encoding="utf-8")
        target.chmod(0o755)
        if gio:
            subprocess.run([gio, "set", str(target), "metadata::trusted", "true"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        print(f"Launcher: {target}")
    print("Open Ubuntu Specs from Show Applications or the Desktop. If prompted, right-click > Allow Launching.")
    print("Keep the USB connected. Run --install-launcher again if the script moves or the USB mount path changes.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script-path", type=Path, required=True, help=argparse.SUPPRESS)
    parser.add_argument("--install-launcher", action="store_true", help="Create Desktop and app-menu shortcuts for this script")
    parser.add_argument("--wait", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--no-sudo", action="store_true", help="Skip the password prompt; use accessible hardware data only")
    parser.add_argument("--sudo", action="store_true", help="Use cached sudo credentials for read-only DMI/SMART queries. Run sudo -v first.")
    parser.add_argument("--output-dir", type=Path, default=Path.home()/"CtrlAltRecycle-Reports")
    parser.add_argument("--open", action="store_true", help="Open HTML in Firefox as the current normal user")
    parser.add_argument("--render-json", type=Path, help="Render an existing collected JSON without probing hardware")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Run this script as your normal desktop user, not with sudo. Use sudo -v then --sudo for privileged read queries.")
    try:
        if args.install_launcher:
            return install_launcher(args.script_path)
        data = json.loads(args.render_json.read_text()) if args.render_json else collect(Probe(args.sudo and not args.no_sudo))
        if not args.render_json:
            data["generated_at"] = dt.datetime.now().astimezone().isoformat(timespec="microseconds")
        args.output_dir.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.fromisoformat(data["generated_at"]).strftime("%Y%m%d-%H%M%S-%f")
        host = re.sub(r"[^a-zA-Z0-9_.-]", "_", data["hostname"])[:80] or "computer"
        stem = f"system-specs_{host}_{stamp}"
        hp, jp = args.output_dir/(stem+".html"), args.output_dir/(stem+".json")
        # Exclusive creation prevents silently overwriting an earlier report.
        with jp.open("x", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        with hp.open("x", encoding="utf-8") as f:
            f.write(render(data))
        print(f"HTML: {hp.resolve()}\nJSON: {jp.resolve()}")
        if args.open:
            firefox = shutil.which("firefox")
            if firefox:
                # Firefox Snap can be denied USB access. Keep the canonical report
                # on USB, and open a normal-user HTML preview in the home folder.
                view = hp
                if Path("/snap/firefox/current").exists():
                    preview_dir = Path.home()/"CtrlAltRecycle-Preview"
                    preview_dir.mkdir(parents=True, exist_ok=True)
                    view = preview_dir/hp.name
                    shutil.copyfile(hp, view)
                subprocess.Popen([firefox, view.resolve().as_uri()], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                print("Firefox: Tool unavailable. Open the HTML from your file manager.", file=sys.stderr)
    except (OSError, ValueError, KeyError) as e:
        print(f"Report failed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

CAR_PYTHON
car_result=$?
if "$car_pause" && [ -r /dev/tty ]; then
    read -r -p 'Press Enter to close this window… ' < /dev/tty || true
fi
exit "$car_result"
