import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import manifest from "../../src/app/manifest.ts";
import { getPwaInstallGuidance } from "../../src/lib/pwa-installation.ts";

test("PWA manifest points to the same web app with install-sized icons", async () => {
  const result = manifest();

  assert.equal(result.name, "OpenKanban");
  assert.equal(result.short_name, "OpenKanban");
  assert.equal(result.start_url, "/");
  assert.equal(result.scope, "/");
  assert.equal(result.display, "standalone");
  assert.deepEqual(
    result.icons.map(({ sizes, type }) => ({ sizes, type })),
    [
      { sizes: "192x192", type: "image/svg+xml" },
      { sizes: "512x512", type: "image/svg+xml" },
    ],
  );

  for (const icon of result.icons) {
    const asset = await readFile(
      new URL(`../../public${icon.src}`, import.meta.url),
      "utf8",
    );
    assert.match(asset, /<svg\b/);
    assert.match(asset, new RegExp(`width="${icon.sizes.split("x")[0]}"`));
  }
});

test("installation guidance offers a direct prompt only when the browser provides it", () => {
  assert.deepEqual(
    getPwaInstallGuidance({
      canPrompt: true,
      isStandalone: false,
      userAgent: "Mozilla/5.0 Chrome/130.0.0.0",
    }),
    { kind: "direct", instructions: null },
  );
});

test("iPhone Safari receives a manual home screen path without a fake success", () => {
  assert.deepEqual(
    getPwaInstallGuidance({
      canPrompt: false,
      isStandalone: false,
      userAgent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Version/18.0 Mobile/15E148 Safari/604.1",
    }),
    {
      kind: "manual",
      instructions:
        "En Safari, tocá Compartir y elegí «Añadir a pantalla de inicio».",
    },
  );
});

test("unsupported Firefox remains available as web access", () => {
  assert.deepEqual(
    getPwaInstallGuidance({
      canPrompt: false,
      isStandalone: false,
      userAgent: "Mozilla/5.0 Firefox/135.0",
    }),
    {
      kind: "web",
      instructions:
        "Este navegador no ofrece instalación como app. Podés seguir usando OpenKanban desde la web.",
    },
  );
});

test("Safari for Mac gets its own optional Dock instructions", () => {
  assert.deepEqual(
    getPwaInstallGuidance({
      canPrompt: false,
      isStandalone: false,
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Version/17.0 Safari/605.1.15",
    }),
    {
      kind: "manual",
      instructions:
        "En Safari para Mac, abrí Archivo y elegí «Añadir al Dock» si aparece.",
    },
  );
});

test("Chrome and Edge provide a manual route when direct install is unavailable", () => {
  for (const userAgent of [
    "Mozilla/5.0 Chrome/130.0.0.0",
    "Mozilla/5.0 Edg/130.0.0.0",
  ]) {
    assert.deepEqual(
      getPwaInstallGuidance({
        canPrompt: false,
        isStandalone: false,
        userAgent,
      }),
      {
        kind: "manual",
        instructions:
          "Abrí el menú del navegador y elegí «Instalar OpenKanban» o «Crear acceso directo» si aparece.",
      },
    );
  }
});

test("an installed app does not keep showing its install prompt", () => {
  assert.deepEqual(
    getPwaInstallGuidance({
      canPrompt: true,
      isStandalone: true,
      userAgent: "Mozilla/5.0 Chrome/130.0.0.0",
    }),
    { kind: "installed", instructions: null },
  );
});
