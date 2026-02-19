import fs from "node:fs";

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) {
  console.error("Missing TELEGRAM_BOT_TOKEN");
  process.exit(1);
}

const configPath = process.env.TELEGRAM_CONFIG_PATH || "/config/telegram.json";
const topicMapPath = process.env.TELEGRAM_TOPIC_MAP_PATH || "/data/topic-map.json";

const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const topicMap = (() => {
  try {
    return JSON.parse(fs.readFileSync(topicMapPath, "utf8"));
  } catch {
    return { topics: {} };
  }
})();

const apiBase = `https://api.telegram.org/bot${token}`;

async function api(method, payload) {
  const res = await fetch(`${apiBase}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || !data?.ok) {
    const err = data?.description || `${res.status} ${res.statusText}`;
    throw new Error(`${method} failed: ${err}`);
  }
  return data.result;
}

function readStdin() {
  return new Promise((resolve) => {
    let buf = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (buf += c));
    process.stdin.on("end", () => resolve(buf));
    process.stdin.resume();
  });
}

function resolveTopicKey(input) {
  const topics = config.topics || {};
  const keys = Object.keys(topics);
  const trimmed = String(input || "").trim();
  if (!trimmed) return null;
  for (const k of keys) {
    if (k.toLowerCase() === trimmed.toLowerCase()) return k;
  }
  return trimmed; // allow dynamic topic keys
}

function getThreadId(topicKey) {
  const mapped = Number(topicMap?.topics?.[topicKey]?.threadId || 0);
  if (mapped) return mapped;

  const fallback = Number(config?.topics?.[topicKey]?.id || 0);
  if (fallback) return fallback;

  return 0;
}

const topic = resolveTopicKey(process.env.TELEGRAM_SEND_TOPIC || "");
if (!topic) {
  console.error("Missing TELEGRAM_SEND_TOPIC");
  process.exit(1);
}

const threadId = getThreadId(topic);
if (!threadId) {
  console.error(`Topic \"${topic}\" is unbound/unknown. Use /bind ${topic} inside that topic first.`);
  process.exit(1);
}

let text = (process.env.TELEGRAM_SEND_TEXT || "").trim();
if (!text) text = (await readStdin()).trim();
if (!text) {
  console.error("Missing message text (TELEGRAM_SEND_TEXT or stdin)");
  process.exit(1);
}

await api("sendMessage", {
  chat_id: config.groupId,
  message_thread_id: threadId,
  text,
});

console.log("sent");
