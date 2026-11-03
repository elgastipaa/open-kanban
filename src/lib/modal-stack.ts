export class ModalStack {
  private readonly active: symbol[] = [];
  private previousOverflow: string | null = null;

  activate(
    token: symbol,
    scrollTarget?: { style: { overflow: string } },
  ): () => void {
    if (this.active.length === 0) {
      this.previousOverflow = scrollTarget?.style.overflow ?? null;
    }
    this.active.push(token);
    if (scrollTarget) scrollTarget.style.overflow = "hidden";

    let isActive = true;
    return () => {
      if (!isActive) return;
      isActive = false;
      const index = this.active.lastIndexOf(token);
      if (index !== -1) this.active.splice(index, 1);

      if (this.active.length > 0) {
        if (scrollTarget) scrollTarget.style.overflow = "hidden";
        return;
      }
      if (scrollTarget && this.previousOverflow !== null) {
        scrollTarget.style.overflow = this.previousOverflow;
      }
      this.previousOverflow = null;
    };
  }

  isTop(token: symbol): boolean {
    return this.active.at(-1) === token;
  }
}
