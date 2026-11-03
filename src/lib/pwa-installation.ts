export type PwaInstallGuidance =
  | { kind: "installed" | "direct"; instructions: null }
  | { kind: "manual" | "web"; instructions: string };

export function getPwaInstallGuidance({
  canPrompt,
  isAppleTouchDevice = false,
  isStandalone,
  userAgent,
}: {
  canPrompt: boolean;
  isAppleTouchDevice?: boolean;
  isStandalone: boolean;
  userAgent: string;
}): PwaInstallGuidance {
  if (isStandalone) return { kind: "installed", instructions: null };
  if (canPrompt) return { kind: "direct", instructions: null };

  const isAppleMobile =
    /iPad|iPhone|iPod/i.test(userAgent) ||
    (/Macintosh/i.test(userAgent) && isAppleTouchDevice);
  if (isAppleMobile) {
    return {
      kind: "manual",
      instructions:
        "En Safari, tocá Compartir y elegí «Añadir a pantalla de inicio».",
    };
  }

  const isSafari =
    /Safari/i.test(userAgent) &&
    !/(Chrome|Chromium|CriOS|Edg|OPR|FxiOS)/i.test(userAgent);
  if (isSafari && /Macintosh|Mac OS X/i.test(userAgent)) {
    return {
      kind: "manual",
      instructions:
        "En Safari para Mac, abrí Archivo y elegí «Añadir al Dock» si aparece.",
    };
  }

  if (/(Chrome|Chromium|Edg)/i.test(userAgent)) {
    return {
      kind: "manual",
      instructions:
        "Abrí el menú del navegador y elegí «Instalar OpenKanban» o «Crear acceso directo» si aparece.",
    };
  }

  return {
    kind: "web",
    instructions:
      "Este navegador no ofrece instalación como app. Podés seguir usando OpenKanban desde la web.",
  };
}
