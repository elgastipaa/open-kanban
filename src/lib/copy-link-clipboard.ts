export type ClipboardWriteText = (text: string) => Promise<void>;

export async function copyLinkToClipboard(
  text: string,
  writeText: ClipboardWriteText,
): Promise<boolean> {
  try {
    await writeText(text);
    return true;
  } catch {
    return false;
  }
}
