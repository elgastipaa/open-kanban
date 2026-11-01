import type { DailyRepetitionCreateCommand } from "./db/daily-repetition";

/** Keeps an uncertain conversion intent stable while its board stays open. */
export class DailyRepetitionOperationStore {
  private readonly commands = new Map<string, DailyRepetitionCreateCommand>();
  private readonly actorId: string;
  private readonly boardSlug: string;

  constructor(actorId: string, boardSlug: string) {
    this.actorId = actorId;
    this.boardSlug = boardSlug;
  }

  private key(taskId: string): string {
    return `${this.actorId}:${this.boardSlug}:${taskId}`;
  }

  get(taskId: string): DailyRepetitionCreateCommand | null {
    return this.commands.get(this.key(taskId)) ?? null;
  }

  set(command: DailyRepetitionCreateCommand): void {
    this.commands.set(this.key(command.task_id), command);
  }

  clear(taskId: string): DailyRepetitionCreateCommand | null {
    const key = this.key(taskId);
    const command = this.commands.get(key) ?? null;
    this.commands.delete(key);
    return command;
  }

  clearAll(): void {
    this.commands.clear();
  }
}
