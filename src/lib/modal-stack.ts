export class ModalStack {
  private readonly active: symbol[] = [];

  activate(token: symbol): () => void {
    this.active.push(token);
    return () => {
      const index = this.active.lastIndexOf(token);
      if (index !== -1) this.active.splice(index, 1);
    };
  }

  isTop(token: symbol): boolean {
    return this.active.at(-1) === token;
  }
}

export function getModalFocusReturnTarget<T>(
  preferredTarget: T | null | undefined,
  opener: T | null,
): T | null {
  return preferredTarget ?? opener;
}
