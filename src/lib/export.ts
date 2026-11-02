// Version 1 remains readable by the import path. New board exports use the
// server-created, streaming v2 snapshot endpoint.
interface ExportData {
  version: 1;
  exportedAt: string;
  board: {
    slug: string;
    columns: {
      title: string;
      position: number;
      tasks: {
        title: string;
        description: string | null;
        priority: string;
        position: number;
      }[];
    }[];
  };
}

export type { ExportData };
