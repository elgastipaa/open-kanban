export function ensureImportReplacementAvailable(
  existingColumnCount: number,
): void {
  if (!Number.isInteger(existingColumnCount) || existingColumnCount < 0) {
    throw new Error("No se pudo verificar el contenido actual del tablero.");
  }
  if (existingColumnCount > 0) {
    throw new Error(
      "La sustitución de un tablero con contenido todavía no está disponible. No se realizó ningún cambio.",
    );
  }
}
