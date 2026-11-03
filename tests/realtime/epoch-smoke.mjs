import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const requiredEnvironment = [
  "ISSUE20_SUPABASE_URL",
  "ISSUE20_PUBLISHABLE_KEY",
  "ISSUE20_JWT_SECRET",
  "ISSUE20_SUPABASE_PROJECT_ID",
];
for (const name of requiredEnvironment) {
  if (!process.env[name]) throw new Error(`Missing local test setting ${name}`);
}

const ownerId = "72000000-0000-4000-8000-000000000001";
const memberId = "72000000-0000-4000-8000-000000000002";
const slug = process.env.ISSUE20_BOARD_SLUG;
if (!slug) throw new Error("Missing local test setting ISSUE20_BOARD_SLUG");

function base64Url(value) {
  return Buffer.from(value).toString("base64url");
}

function tokenFor(userId) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64Url(
    JSON.stringify({
      aud: "authenticated",
      exp: now + 600,
      iat: now,
      iss: "supabase-demo",
      role: "authenticated",
      sub: userId,
    }),
  );
  const input = `${header}.${payload}`;
  const signature = awaitableSignature(input);
  return `${input}.${signature}`;
}

function awaitableSignature(input) {
  return createHmac("sha256", process.env.ISSUE20_JWT_SECRET)
    .update(input)
    .digest("base64url");
}

function clientFor(userId) {
  const accessToken = tokenFor(userId);
  const client = createClient(
    process.env.ISSUE20_SUPABASE_URL,
    process.env.ISSUE20_PUBLISHABLE_KEY,
    {
      auth: {
        autoRefreshToken: false,
        detectSessionInUrl: false,
        persistSession: false,
      },
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    },
  );
  client.realtime.setAuth(accessToken);
  return client;
}

async function subscribed(client, topic, isPrivate = true, configure) {
  const channel = client.channel(topic, { config: { private: isPrivate } });
  configure?.(channel);
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("channel join timeout")), 5000);
    channel.subscribe((status, error) => {
      if (status === "SUBSCRIBED") {
        clearTimeout(timeout);
        resolve(channel);
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        clearTimeout(timeout);
        reject(new Error(`channel join failed: ${status} ${error?.message ?? ""}`));
      }
    });
  });
}

const owner = clientFor(ownerId);
const member = clientFor(memberId);
const anonymous = createClient(
  process.env.ISSUE20_SUPABASE_URL,
  process.env.ISSUE20_PUBLISHABLE_KEY,
  { auth: { autoRefreshToken: false, persistSession: false } },
);
let memberChannel;
let openChannel;
let ownerChannel;

try {
  const ownerContextResult = await owner
    .rpc("get_board_p", { p_slug: slug })
    .maybeSingle();
  assert.equal(ownerContextResult.error, null);
  const oldContext = ownerContextResult.data;
  assert.ok(oldContext?.auth_epoch);
  assert.ok(oldContext?.sync_topic);

  const memberContextResult = await member
    .rpc("get_board_p", { p_slug: slug })
    .maybeSingle();
  assert.equal(memberContextResult.error, null);
  assert.equal(memberContextResult.data.sync_topic, oldContext.sync_topic);

  const events = [];
  const ownerEvents = [];
  const openEvents = [];
  let revocationTransactionCommitted = false;
  let resolveInvalidation;
  const invalidation = new Promise((resolve) => {
    resolveInvalidation = resolve;
  });
  let resolveLateSignal;
  const lateSignal = new Promise((resolve) => {
    resolveLateSignal = resolve;
  });
  memberChannel = await subscribed(
    member,
    oldContext.sync_topic,
    true,
    (channel) => {
      channel.on("broadcast", { event: "revalidate" }, (message) => {
        events.push({ event: "revalidate", payload: message.payload ?? message });
        resolveInvalidation();
      });
      channel.on("broadcast", { event: "sync" }, (message) => {
        events.push({
          event: "sync",
          payload: message.payload ?? message,
          afterRevocationCommit: revocationTransactionCommitted,
        });
        resolveLateSignal();
      });
    },
  );
  ownerChannel = await subscribed(owner, oldContext.sync_topic, true, (channel) => {
    channel.on("broadcast", { event: "sync" }, (message) => {
      ownerEvents.push({ event: "sync", payload: message.payload ?? message });
    });
    channel.on("broadcast", { event: "revalidate" }, (message) => {
      ownerEvents.push({ event: "revalidate", payload: message.payload ?? message });
    });
  });

  openChannel = anonymous.channel(oldContext.sync_topic, {
    config: { private: false },
  });
  openChannel.on("broadcast", { event: "sync" }, (message) => {
    openEvents.push({ event: "sync", payload: message.payload ?? message });
  });
  openChannel.on("broadcast", { event: "revalidate" }, (message) => {
    openEvents.push({ event: "revalidate", payload: message.payload ?? message });
  });
  const openJoinStatus = await new Promise((resolve) => {
    const timeout = setTimeout(() => resolve("timeout"), 2000);
    openChannel.subscribe((status) => {
      if (status === "SUBSCRIBED") {
        clearTimeout(timeout);
        resolve(status);
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        clearTimeout(timeout);
        resolve(status);
      }
    });
  });
  assert.equal(openJoinStatus, "SUBSCRIBED", "the open channel did not join");

  const directSend = await memberChannel.send({
    type: "broadcast",
    event: "sync",
    payload: { task_title: "no debe publicarse" },
  });
  await new Promise((resolve) => setTimeout(resolve, 1000));
  assert.deepEqual(
    ownerEvents,
    [],
    `a signed client published a broadcast (transport result: ${directSend})`,
  );

  // This local-only SQL transaction publishes a data signal, then performs
  // the normal authorized removal RPC before committing. The sync row is
  // therefore committed and delivered only after the revocation transaction
  // has completed; the event loop remains blocked until that commit returns.
  const lateRevocationSql = readFileSync(
    new URL("./late-revocation.sql", import.meta.url),
    "utf8",
  );
  execFileSync(
    "docker",
    [
      "exec",
      "-i",
      `supabase_db_${process.env.ISSUE20_SUPABASE_PROJECT_ID}`,
      "psql",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
    ],
    { encoding: "utf8", input: lateRevocationSql },
  );
  revocationTransactionCommitted = true;

  await Promise.race([
    lateSignal,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("the pre-revocation sync signal did not arrive late")), 5000),
    ),
  ]);
  await Promise.race([
    invalidation,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("the pre-rotation signal did not arrive")), 5000),
    ),
  ]);
  const deniedRefetch = await member
    .rpc("get_board_p", { p_slug: slug })
    .maybeSingle();
  assert.equal(deniedRefetch.error, null);
  assert.equal(deniedRefetch.data, null, "a revoked member refetched private board context");

  const nextContextResult = await owner
    .rpc("get_board_p", { p_slug: slug })
    .maybeSingle();
  assert.equal(nextContextResult.error, null);
  const nextContext = nextContextResult.data;
  assert.notEqual(nextContext.auth_epoch, oldContext.auth_epoch);
  assert.notEqual(nextContext.sync_topic, oldContext.sync_topic);
  const newColumn = await owner.rpc("create_column_p", {
    p_slug: slug,
    p_board_id: oldContext.id,
    p_title: "Publicación posterior en tema nuevo",
    p_position: 1,
  });
  assert.equal(newColumn.error, null);
  await new Promise((resolve) => setTimeout(resolve, 1500));
  assert.deepEqual(
    events.map((entry) => entry.event),
    ["sync", "revalidate"],
    "the pre-revocation data signal and the revocation signal must remain distinguishable",
  );
  assert.ok(
    events.find((entry) => entry.event === "sync")?.afterRevocationCommit,
    "the pre-revocation sync callback was not processed after the revocation committed",
  );
  assert.deepEqual(
    ownerEvents.map((entry) => entry.event),
    ["sync", "revalidate"],
    "the old topic must receive only the pre-revocation sync and its invalidation",
  );
  assert.equal(openEvents.length, 0, "an open channel received a private signal");
  for (const entry of events) {
    const keys = Object.keys(entry.payload ?? {});
    assert.ok(keys.every((key) => key === "id"), "a signal carried board content");
  }

  const revokedDirectSend = await memberChannel.send({
    type: "broadcast",
    event: "sync",
    payload: { task_title: "tampoco debe publicarse" },
  });
  await new Promise((resolve) => setTimeout(resolve, 1000));
  assert.deepEqual(
    ownerEvents.map((entry) => entry.event),
    ["sync", "revalidate"],
    `a revoked signed client published a broadcast (transport result: ${revokedDirectSend})`,
  );
  console.log(
    "PASS: local Realtime delivered a pre-revocation sync after commit; its refetch was denied, open/client broadcasts were blocked, and later writes used the rotated topic.",
  );
} finally {
  if (memberChannel) await member.removeChannel(memberChannel);
  if (ownerChannel) await owner.removeChannel(ownerChannel);
  if (openChannel) await anonymous.removeChannel(openChannel);
  await owner.removeAllChannels();
}
