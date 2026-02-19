import fs from 'node:fs';

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) {
  console.error('Missing TELEGRAM_BOT_TOKEN');
  process.exit(1);
}

const configPath = process.env.TELEGRAM_CONFIG_PATH || '/config/telegram.json';
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

const apiBase = `https://api.telegram.org/bot${token}`;

async function api(method, payload) {
  const res = await fetch(`${apiBase}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || !data?.ok) {
    const err = data?.description || `${res.status} ${res.statusText}`;
    throw new Error(`${method} failed: ${err}`);
  }
  return data.result;
}

const topicMapPath = process.env.TELEGRAM_TOPIC_MAP_PATH || '/data/topic-map.json';

function safeReadJson(p, fallback) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch {
    return fallback;
  }
}

function resolveTopicKey(input) {
  const topics = config.topics || {};
  const keys = Object.keys(topics);
  const trimmed = String(input || '').trim();
  if (!trimmed) return null;
  for (const k of keys) {
    if (k.toLowerCase() === trimmed.toLowerCase()) return k;
  }
  return null;
}

const requestedTopic = (process.env.TELEGRAM_TEST_TOPIC || '').trim();
let threadId = Number(process.env.TELEGRAM_TEST_THREAD_ID || 0);

if (requestedTopic) {
  const topicMap = safeReadJson(topicMapPath, { topics: {} });
  const resolved = resolveTopicKey(requestedTopic) || requestedTopic;
  const mapped = topicMap?.topics?.[resolved]?.threadId;
  threadId = Number(mapped || 0);

  if (!threadId) {
    const valid = Object.keys(config.topics || {}).join(', ');
    throw new Error(`Topic "${resolved}" is unbound or unknown. Send "/bind ${resolved}" inside that Telegram topic first. Predefined: ${valid || '(none)'}`);
  }
}

await api('sendMessage', {
  chat_id: config.groupId,
  message_thread_id: threadId || undefined,
  text: `Teste: telegram-gateway online${requestedTopic ? ` (topic ${requestedTopic})` : ''} (thread ${threadId || 'main'}). Envie /status ou /topics. Para vincular: /bind <nome> dentro do tópico.`,
});

console.log('sent');
