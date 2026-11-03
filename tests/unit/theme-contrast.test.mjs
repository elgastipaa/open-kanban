import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const stylesheet = await readFile(
  new URL("../../src/app/globals.css", import.meta.url),
  "utf8",
);

function colorFromToken(scope, name) {
  const match = scope.match(
    new RegExp(`--color-${name}:\\s*(#[0-9a-f]{6})`, "i"),
  );
  assert.ok(match, `Expected a hex value for --color-${name}`);
  return match[1];
}

function relativeLuminance(hex) {
  const channels = hex
    .slice(1)
    .match(/.{2}/g)
    .map((channel) => Number.parseInt(channel, 16) / 255)
    .map((channel) =>
      channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
    );
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}

function contrastRatio(foreground, background) {
  const values = [
    relativeLuminance(foreground),
    relativeLuminance(background),
  ].sort((left, right) => right - left);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test("semantic accent text has readable contrast across light and dark surfaces", () => {
  const theme = stylesheet.match(/@theme inline \{([\s\S]*?)\n\}/)?.[1];
  const lightTheme = stylesheet.match(
    /html\[data-theme="light"\] \{([\s\S]*?)\n\}/,
  )?.[1];

  assert.ok(theme, "Expected the shared theme token block");
  assert.ok(lightTheme, "Expected the light theme token block");

  const darkAccentText = colorFromToken(theme, "accent-text");
  const lightAccentText = colorFromToken(lightTheme, "accent-text");
  const surfaceTokens = [
    "surface-base",
    "surface-raised",
    "surface-overlay",
    "surface-column",
    "surface-column-collapsed",
    "surface-hover",
  ];

  for (const token of surfaceTokens) {
    assert.ok(
      contrastRatio(darkAccentText, colorFromToken(theme, token)) >= 4.5,
      `Dark accent text should contrast with --color-${token}`,
    );
    assert.ok(
      contrastRatio(lightAccentText, colorFromToken(lightTheme, token)) >= 4.5,
      `Light accent text should contrast with --color-${token}`,
    );
  }
});
