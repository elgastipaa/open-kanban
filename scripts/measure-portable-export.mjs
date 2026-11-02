import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";
import { createPortableZipStream } from "../src/lib/portable-export-zip.ts";

const taskCount = 5_000;
const attachmentCount = 500;
const attachmentSize = 24_000;
const encoder = new TextEncoder();
const metadata = {
  exportedAt: "2026-11-02T12:00:00.000Z",
  schemaVersion: 68,
  timeZone: "America/Argentina/Buenos_Aires",
  normalizationVersion: 1,
};

async function* sources() {
  const board = encoder.encode('{"name":"Fixture sintético"}\n');
  yield {
    name: "data/board.json",
    contentType: "application/json",
    recordCount: 1,
    chunks: (async function* () {
      yield board;
    })(),
  };
  yield {
    name: "data/tasks.ndjson",
    contentType: "application/x-ndjson",
    recordCount: taskCount,
    chunks: (async function* () {
      for (let index = 0; index < taskCount; index += 1) {
        yield encoder.encode(
          `${JSON.stringify({
            id: `task-${index}`,
            title: `Tarea sintética ${index}`,
            description: "x".repeat(80),
            position: index,
          })}\n`,
        );
      }
    })(),
  };
  yield {
    name: "data/attachments.ndjson",
    contentType: "application/x-ndjson",
    recordCount: attachmentCount,
    chunks: (async function* () {
      for (let index = 0; index < attachmentCount; index += 1) {
        yield encoder.encode(
          `${JSON.stringify({
            id: `attachment-${index}`,
            file_name: `fixture-${index}.txt`,
            size_bytes: attachmentSize,
          })}\n`,
        );
      }
    })(),
  };
  for (let index = 0; index < attachmentCount; index += 1) {
    const content = Buffer.alloc(attachmentSize, index % 251);
    const sha256 = createHash("sha256").update(content).digest("hex");
    yield {
      name: `objects/attachment-${index}`,
      contentType: "text/plain; charset=utf-8",
      expectedSize: attachmentSize,
      expectedSha256: sha256,
      chunks: (async function* () {
        yield content;
      })(),
    };
  }
}

const started = performance.now();
let archiveBytes = 0;
let chunkCount = 0;
const rssBefore = process.memoryUsage.rss();
for await (const chunk of createPortableZipStream(sources(), metadata)) {
  archiveBytes += chunk.byteLength;
  chunkCount += 1;
}
const elapsedMs = performance.now() - started;
const rssAfter = process.memoryUsage.rss();
process.stdout.write(
  `${JSON.stringify({
    fixture: {
      tasks: taskCount,
      attachments: attachmentCount,
      attachment_bytes_each: attachmentSize,
    },
    archive_bytes: archiveBytes,
    stream_chunks: chunkCount,
    elapsed_ms: Number(elapsedMs.toFixed(2)),
    rss_delta_bytes: rssAfter - rssBefore,
  })}\n`,
);
