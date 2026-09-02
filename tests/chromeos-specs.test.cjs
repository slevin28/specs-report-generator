const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const pagePath = path.join(__dirname, "..", "chromeos-specs.html");
const html = fs.readFileSync(pagePath, "utf8");
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
assert.ok(scriptMatch, "the page contains an inline script");
assert.match(html, /id="brand-logo" src="data:image\/png;base64,/, "the original embedded brand logo is present");

class FakeElement {
    constructor(id) {
        this.id = id;
        this.value = id === "form-factor" ? "Chromebook / Portable" : "";
        this.textContent = "";
        this.innerHTML = "";
        this.className = "";
        this.download = "";
        this.listeners = {};
        this.classList = { add() {}, remove() {} };
    }

    addEventListener(name, listener) {
        (this.listeners[name] ||= []).push(listener);
    }

    appendChild() {}
    click() { this.clicked = true; }
    remove() {}
}

const elements = {};
for (const match of html.matchAll(/\bid="([^"]+)"/g)) {
    elements[match[1]] = new FakeElement(match[1]);
}
elements["brand-logo"].src = "data:image/png;base64,test-logo";

let lastAnchor = null;
let animationTime = 0;
const document = {
    hidden: false,
    body: { appendChild() {} },
    getElementById(id) { return elements[id] ||= new FakeElement(id); },
    querySelector(selector) {
        if (selector === "style[data-report-style]") return { textContent: ".spec-report{}" };
        return null;
    },
    createElement(tag) {
        if (tag === "canvas") return { getContext() { return null; } };
        const element = new FakeElement(tag);
        if (tag === "a") lastAnchor = element;
        return element;
    }
};

const navigator = {
    userAgent: "Mozilla/5.0 (X11; CrOS x86_64 15917.45.0) AppleWebKit/537.36 Chrome/126.0.6478.0 Safari/537.36",
    platform: "Linux x86_64",
    hardwareConcurrency: 8,
    deviceMemory: 8,
    maxTouchPoints: 10,
    onLine: true,
    connection: { effectiveType: "4g", downlink: 50, rtt: 20 },
};

const window = {
    devicePixelRatio: 2,
    location: { reload() {} },
    print() {}
};

const context = {
    Blob,
    URL,
    console,
    document,
    navigator,
    performance: { now: () => animationTime },
    requestAnimationFrame(callback) {
        animationTime += 1000 / 60;
        setImmediate(() => callback(animationTime));
    },
    screen: { width: 1366, height: 768, colorDepth: 24 },
    setTimeout,
    clearTimeout,
    setImmediate,
    window
};

vm.runInNewContext(scriptMatch[1], context, { filename: "chromeos-specs.html" });

const flush = () => new Promise((resolve) => setTimeout(resolve, 30));

(async () => {
    await flush();

    const initialReport = elements["report-preview"].innerHTML;
    assert.match(initialReport, /15917\.45\.0/, "ChromeOS version is read from the user agent");
    assert.match(initialReport, /At least 8 GB/, "browser-capped RAM is labeled as an estimate");
    assert.match(initialReport, /10 touch points/, "touch support is reported");
    assert.doesNotMatch(initialReport, /On battery|Charging \/ connected/, "current battery state is omitted");
    assert.match(initialReport, /2732 × 1536/, "scaled pixel resolution is reported");
    assert.match(initialReport, /data:image\/png;base64,test-logo/, "the branded logo is carried into the report");

    elements.serial.value = "ABC<123";
    for (const listener of elements.serial.listeners.input) listener();
    assert.match(elements["report-preview"].innerHTML, /ABC&lt;123/, "manual values are HTML escaped");
    assert.doesNotMatch(elements["report-preview"].innerHTML, /ABC<123/, "manual markup is never injected");

    const diagnosticsText = [
        "CHROMEOS_RELEASE_VERSION=15917.45.0",
        "CHROMEOS_RELEASE_BOARD=octopus-signed-mp-v31keys",
        "Product Name: Acer Chromebook 314",
        "CPU Name: Intel(R) Celeron(R) N4020 CPU @ 1.10GHz",
        "MemTotal: 8053064 kB",
        "Battery health: 92%"
    ].join("\n");
    const file = { name: "Diagnostics_log.txt", size: diagnosticsText.length, text: async () => diagnosticsText };
    for (const listener of elements["log-file"].listeners.change) {
        await listener({ target: { files: [file] } });
    }
    await flush();

    assert.equal(elements.model.value, "Acer Chromebook 314");
    assert.equal(elements.board.value, "octopus-signed-mp-v31keys");
    assert.equal(elements["cpu-model"].value, "Intel(R) Celeron(R) N4020 CPU @ 1.10GHz");
    assert.equal(elements["installed-ram"].value, "7.7 GB");
    assert.equal(elements["battery-health"].value, "92%");
    assert.match(elements["import-status"].textContent, /Added 5 fields[\s\S]*preserved 1 existing value/);

    elements["capture-text"].value = [
        "hardware_class: OCTOPUS C6B-A4C-D3B-Q4E-A6A",
        "model name : Intel(R) Celeron(R) N4020 CPU @ 1.10GHz",
        "chargeFullAh: 5.52",
        "chargeFullDesignAh: 6.0",
        "cycleCount: 41"
    ].join("\n");
    for (const listener of elements["parse-capture"].listeners.click) listener();

    assert.equal(elements.board.value, "octopus-signed-mp-v31keys", "later captures do not overwrite populated fields");
    assert.equal(elements["cpu-model"].value, "Intel(R) Celeron(R) N4020 CPU @ 1.10GHz", "duplicate values are preserved");
    assert.equal(elements["battery-design"].value, "6.0 Ah");
    assert.equal(elements["battery-full"].value, "5.52 Ah");
    assert.equal(elements["battery-cycles"].value, "41");
    assert.equal(elements["capture-text"].value, "", "successfully parsed pasted text is cleared");
    assert.match(elements["import-status"].textContent, /Added 3 fields[\s\S]*preserved 3 existing values/);
    assert.match(elements["report-preview"].innerHTML, /Capacity Remaining[\s\S]*92%/, "full charge divided by design capacity is reported");

    for (const listener of elements["save-report"].listeners.click) await listener();
    assert.ok(lastAnchor && lastAnchor.clicked, "download fallback is triggered");
    assert.equal(lastAnchor.download, "ABC_123_SystemReport.html");

    console.log("chromeos-specs.html: all tests passed");
})().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
