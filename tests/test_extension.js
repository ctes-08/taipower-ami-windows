"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const extensionRoot = path.join(repoRoot, "chrome_extension");
const manifest = JSON.parse(fs.readFileSync(path.join(extensionRoot, "manifest.json"), "utf8"));
const background = fs.readFileSync(path.join(extensionRoot, "background.js"), "utf8");
const popup = fs.readFileSync(path.join(extensionRoot, "popup.js"), "utf8");

const digest = crypto.createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest();
const alphabet = "abcdefghijklmnop";
const extensionId = [...digest.subarray(0, 16)]
  .map((byte) => alphabet[byte >> 4] + alphabet[byte & 0x0f])
  .join("");

assert.equal(extensionId, "ajnbiemabobkigpbnfmoekolceigkica");
assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.version, "2.0.1");
assert.deepEqual(manifest.host_permissions, ["https://service.taipower.com.tw/*"]);
assert.match(background, /tw\.taipower_ami\.native_host_v2/u);
assert.match(background, /NATIVE_TIMEOUT_MS = 50000/u);
assert.match(background, /secrets_printed: false/u);
assert.match(popup, /https:\/\/service\.taipower\.com\.tw/u);
assert.doesNotMatch(popup, /password|remoteDebugging|debugger/u);

console.log("Chrome extension contract tests passed: 10");
