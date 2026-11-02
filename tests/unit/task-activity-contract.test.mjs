import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const activitySource = await readFile(
  new URL("../../src/components/board/task-activity.tsx", import.meta.url),
  "utf8",
);
const taskModalSource = await readFile(
  new URL("../../src/components/board/task-modal.tsx", import.meta.url),
  "utf8",
);

test("the task detail loads authorized activity and discards stale page responses", () => {
  assert.match(
    taskModalSource,
    /<TaskActivity[\s\S]*?taskId=\{baseTask\.id\}[\s\S]*?actorId=\{actorId\}[\s\S]*?timeZone=\{boardTimeZone\}/,
  );
  assert.match(
    activitySource,
    /listTaskActivity\(createClient\(\), slug, taskId/,
  );
  assert.match(activitySource, /requestGenerationRef\.current !== generation/);
  assert.match(activitySource, /requestContextRef\.current !== requestContext/);
});

test("activity is Spanish, dated, progressively loaded, and read-only", () => {
  assert.match(activitySource, /Se muestran los últimos 180 días/);
  assert.match(activitySource, /Cargar más actividad/);
  assert.match(activitySource, /No hay actividad en los últimos 180 días/);
  assert.match(activitySource, /dateTime=\{event\.occurred_at\}/);
  assert.match(
    activitySource,
    /taskActivityActorLabel\(event\.actor_type, event\.actor_name\)/,
  );
  assert.doesNotMatch(activitySource, /onEdit|onDelete|onRestore/);
});

test("confirmed E05 changes refresh the activity panel", () => {
  assert.match(
    taskModalSource,
    /setActivityRefreshSignal\(\(current\) => current \+ 1\)/,
  );
  assert.match(
    taskModalSource,
    /Object\.hasOwn\(operation\.updates, "due_on"\)/,
  );
  assert.match(taskModalSource, /refreshSignal=\{activityRefreshSignal\}/);
});
