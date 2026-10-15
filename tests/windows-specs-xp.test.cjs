const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const scriptPath = path.join(__dirname, "..", "windows-specs-xp.vbs");
const script = fs.readFileSync(scriptPath, "utf8");

const querySafe = script.match(/Function QuerySafe\([\s\S]*?End Function/);
assert.ok(querySafe, "QuerySafe is present");
assert.match(
    querySafe[0],
    /resultCount\s*=\s*results\.Count[\s\S]*If Err\.Number <> 0[\s\S]*Set QuerySafe = Nothing/,
    "lazy XP WMI queries are forced and failures become an empty result"
);

assert.match(
    script,
    /HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0\\ProcessorNameString/,
    "the CPU name uses the registry value displayed by Windows XP"
);
assert.match(
    script,
    /installedRamText = installedRamText & " installed \/ " & usableRamText & " usable by Windows XP"/,
    "installed and XP-usable RAM are distinguished"
);

const physicalAdapter = script.match(/Function IsPhysicalNetworkAdapter\([\s\S]*?End Function/);
assert.ok(physicalAdapter, "physical network adapter filtering is present");
assert.match(physicalAdapter[0], /PhysicalAdapter/, "the native physical-adapter flag is preferred");
assert.match(physicalAdapter[0], /miniport/, "software miniports are rejected");
assert.match(physicalAdapter[0], /packet scheduler/, "the XP packet scheduler is rejected");
assert.match(physicalAdapter[0], /Left\(pnpIdentifier, 5\) = "ROOT\\"/, "software-created ROOT adapters are rejected");

const pseudoOptical = script.match(/Function IsPseudoOpticalDevice\([\s\S]*?End Function/);
assert.ok(pseudoOptical, "pseudo-optical filtering is present");
assert.match(pseudoOptical[0], /cruzer/, "SanDisk Cruzer U3 virtual discs are rejected");
assert.match(pseudoOptical[0], /USBSTOR\\CDROM&VEN_SANDISK/, "the U3 virtual-CD hardware ID is rejected");

console.log("windows-specs-xp.vbs: regression checks passed");
