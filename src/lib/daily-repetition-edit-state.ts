import type { RepetitionEditCommand } from "./db/daily-repetition";

/** Keeps an uncertain series edit stable while its board stays open. */
export class RepetitionEditOperationStore {
  private readonly commands = new Map<string, RepetitionEditCommand>();
  private readonly actorId: string;
  private readonly boardSlug: string;

  constructor(actorId: string, boardSlug: string) {
    this.actorId = actorId;
    this.boardSlug = boardSlug;
  }

  private key(taskId: string): string {
    return `${this.actorId}:${this.boardSlug}:${taskId}`;
  }

  get(taskId: string): RepetitionEditCommand | null {
    return this.commands.get(this.key(taskId)) ?? null;
  }

  set(command: RepetitionEditCommand): void {
    this.commands.set(this.key(command.task_id), command);
  }

  clear(taskId: string): RepetitionEditCommand | null {
    const key = this.key(taskId);
    const command = this.commands.get(key) ?? null;
    this.commands.delete(key);
    return command;
  }

  clearAll(): void {
    this.commands.clear();
  }
}
