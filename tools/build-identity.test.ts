import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const directories: string[] = [];

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true });
});

function workspace() {
  const directory = mkdtempSync(join(tmpdir(), "ward-build-identity-"));
  directories.push(directory);
  return { config: join(directory, "application-id"), source: join(directory, "WardBuildIdentity.swift") };
}

function run(args: string[], identity?: string) {
  const env = { ...process.env };
  delete env.WARD_BUNDLE_ID;
  if (identity !== undefined) env.WARD_BUNDLE_ID = identity;
  return Bun.spawnSync(["/bin/bash", "tools/build-identity.sh", ...args], { env });
}

test("arbitrary configured identities reach generated Swift and changes replace the old identity", () => {
  const { config, source } = workspace();
  for (const identity of ["org.example.wallet", "io.example.ward2.dev"]) {
    expect(run(["configure", config], identity).exitCode).toBe(0);
    expect(run(["generate", config, source]).exitCode).toBe(0);
    expect(readFileSync(config, "utf8")).toBe(identity + "\n");
    expect(readFileSync(source, "utf8")).toContain(`applicationID = "${identity}"`);
  }
});

test("missing or invalid identity fails without overwriting valid configuration", () => {
  const { config } = workspace();
  expect(run(["configure", config], "org.example.wallet").exitCode).toBe(0);
  for (const identity of [undefined, "", "invalid", "org..wallet", "org.example/$HOME", "org.example\nother"]) {
    expect(run(["configure", config], identity).exitCode).not.toBe(0);
    expect(readFileSync(config, "utf8")).toBe("org.example.wallet\n");
  }
});

test("unchanged configuration keeps its timestamp for incremental builds", () => {
  const { config } = workspace();
  expect(run(["configure", config], "org.example.wallet").exitCode).toBe(0);
  const before = statSync(config).mtimeMs;
  expect(run(["configure", config], "org.example.wallet").exitCode).toBe(0);
  expect(statSync(config).mtimeMs).toBe(before);
});
