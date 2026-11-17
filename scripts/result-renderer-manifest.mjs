#!/usr/bin/env node

import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

const argumentsMap = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  argumentsMap.set(process.argv[index], process.argv[index + 1]);
}

const metafilePath = argumentsMap.get("--metafile");
const lockfilePath = argumentsMap.get("--lockfile");
const outputPath = argumentsMap.get("--output");
const licensesPath = argumentsMap.get("--licenses");
if (!metafilePath || !lockfilePath || !outputPath || !licensesPath) {
  process.stderr.write(
    "usage: result-renderer-manifest.mjs --metafile FILE --lockfile FILE --output FILE --licenses DIR\n",
  );
  process.exit(64);
}

const metafile = JSON.parse(readFileSync(metafilePath, "utf8"));
const lockfile = JSON.parse(readFileSync(lockfilePath, "utf8"));
const webRoot = dirname(resolve(lockfilePath));
const packagePaths = Object.keys(lockfile.packages)
  .filter((path) => path.includes("node_modules/"))
  .sort((left, right) => right.length - left.length);
const usedPackagePaths = new Set();

for (const input of Object.keys(metafile.inputs)) {
  const packagePath = packagePaths.find(
    (candidate) => input === candidate || input.startsWith(`${candidate}/`),
  );
  if (packagePath) usedPackagePaths.add(packagePath);
}

function packageName(packagePath) {
  const marker = "node_modules/";
  const finalSegment = packagePath.lastIndexOf(marker);
  return packagePath.slice(finalSegment + marker.length);
}

function packageURL(name, version) {
  const encodedName = encodeURIComponent(name).replace("%2F", "/");
  return `pkg:npm/${encodedName}@${version}`;
}

function integrityHash(integrity) {
  const match = /^sha512-([A-Za-z0-9+/]+={0,2})$/.exec(integrity ?? "");
  if (!match) throw new Error(`unsupported package integrity: ${integrity}`);
  return Buffer.from(match[1], "base64").toString("hex");
}

function licenseFile(packagePath) {
  const directory = join(webRoot, packagePath);
  const file = readdirSync(directory).find((name) => /^(license|licence|copying)(\.|$)/i.test(name));
  if (!file) throw new Error(`missing license file for ${packagePath}`);
  return join(directory, file);
}

const components = [...usedPackagePaths]
  .map((packagePath) => {
    const metadata = lockfile.packages[packagePath];
    const name = metadata.name ?? packageName(packagePath);
    if (!metadata.version || !metadata.integrity || !metadata.license) {
      throw new Error(`incomplete lock metadata for ${name}`);
    }
    return {
      type: "library",
      name,
      version: metadata.version,
      purl: packageURL(name, metadata.version),
      hashes: [{ alg: "SHA-512", content: integrityHash(metadata.integrity) }],
      licenses: [{ license: { id: metadata.license } }],
      properties: [{ name: "mien:bundle", value: "result-renderer" }],
      packagePath,
    };
  })
  .sort((left, right) => left.name.localeCompare(right.name) || left.version.localeCompare(right.version));

rmSync(licensesPath, { recursive: true, force: true });
mkdirSync(licensesPath, { recursive: true });
for (const component of components) {
  const safeName = component.name.replaceAll("@", "").replaceAll("/", "-");
  const destination = join(licensesPath, `${safeName}-${component.version}.txt`);
  copyFileSync(licenseFile(component.packagePath), destination);
  delete component.packagePath;
}

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(
  outputPath,
  `${JSON.stringify({
    schemaVersion: 1,
    artifact: {
      name: basename(resolve(metafilePath)),
      sha256: createHash("sha256")
        .update(readFileSync(join(dirname(resolve(metafilePath)), "renderer.js")))
        .digest("hex"),
    },
    components,
  }, null, 2)}\n`,
);
