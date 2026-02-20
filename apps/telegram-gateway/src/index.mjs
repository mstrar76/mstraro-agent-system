import fs from 'node:fs';
import path from 'node:path';

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) {
  console.error('Missing TELEGRAM_BOT_TOKEN');
  process.exit(1);
}

const configPath = process.env.TELEGRAM_CONFIG_PATH || '/config/telegram.json';
const offsetPath = process.env.TELEGRAM_OFFSET_PATH || '/data/update-offset-default.json';
const sessionsDir = process.env.TELEGRAM_SESSIONS_DIR || '/data/sessions';
const topicMapPath = process.env.TELEGRAM_TOPIC_MAP_PATH || '/data/topic-map.json';
const approvalsDir = process.env.TELEGRAM_APPROVALS_DIR || '/data/approvals';
const agentGatewayUrl = process.env.AGENT_GATEWAY_URL || '';

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(filePath, value) {
  const tmpPath = `${filePath}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(value, null, 2));
  fs.renameSync(tmpPath, filePath);
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

const config = readJson(configPath, null);
if (!config?.groupId) {
  console.error(`Invalid config at ${configPath}`);
  process.exit(1);
}

ensureDir(path.dirname(offsetPath));
ensureDir(sessionsDir);
ensureDir(approvalsDir);

let offsetState = readJson(offsetPath, { offset: 0 });
if (typeof offsetState.offset !== 'number') offsetState.offset = 0;

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

async function callAgentGateway(payload) {
  if (!agentGatewayUrl) return null;
  const res = await fetch(`${agentGatewayUrl.replace(/\/$/, '')}/respond`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(`agent-gateway http ${res.status}`);
  }
  return data;
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

function isValidDynamicTopicKey(topicKey) {
  return /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(String(topicKey || ''));
}

function readTopicMap() {
  const state = readJson(topicMapPath, { topics: {} });
  if (!state || typeof state !== 'object') return { topics: {} };
  if (!state.topics || typeof state.topics !== 'object') state.topics = {};
  return state;
}

function writeTopicMap(next) {
  ensureDir(path.dirname(topicMapPath));
  writeJsonAtomic(topicMapPath, next);
}

function topicKeyFromThreadId(threadId) {
  if (!threadId) return 'General';

  const topicMap = readTopicMap();
  for (const [key, value] of Object.entries(topicMap.topics || {})) {
    if (value?.threadId === threadId) return key;
  }

  return `thread-${threadId}`;
}

function isAllowedUser(userId) {
  const allow = config.allowFrom || [];
  if (!allow.length) return true;
  return allow.includes(String(userId));
}

function sessionLogPath(threadId) {
  return path.join(sessionsDir, `topic-${threadId || 0}.jsonl`);
}

function appendSessionLog(threadId, record) {
  const line = JSON.stringify(record);
  fs.appendFileSync(sessionLogPath(threadId), `${line}\n`);
}

async function handleMessage(message) {
  const chatId = message?.chat?.id;
  if (chatId !== config.groupId) return;

  const from = message?.from;
  if (!from || from.is_bot) return;
  if (!isAllowedUser(from.id)) return;

  const threadId = message.message_thread_id || 0;
  const topicKey = topicKeyFromThreadId(threadId);

  appendSessionLog(threadId, {
    ts: new Date().toISOString(),
    updateType: 'message',
    chatId,
    threadId,
    topicKey,
    from: { id: from.id, username: from.username },
    text: message.text || null,
  });

  const text = (message.text || '').trim();
  if (!text) return;

  const [cmd, ...args] = text.split(/\s+/);

  if (cmd === '/bind') {
    if (!threadId) {
      await api('sendMessage', {
        chat_id: chatId,
        text: 'Use /bind dentro de um tópico (não no chat geral). Ex: /bind VPS',
      });
      return;
    }

    const requested = args.join(' ').trim();
    const resolved = resolveTopicKey(requested);
    const topicToBind = resolved || requested;
    if (!topicToBind) return;
    if (!resolved && !isValidDynamicTopicKey(topicToBind)) {
      const available = Object.keys(config.topics || {}).join(', ') || '(nenhum)';
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId,
        text: `Topic inválido. Use: /bind <nome>. Disponíveis (pré-cadastrados): ${available}. Para novo tópico use apenas letras/números/_/-.`,
      });
      return;
    }

    const current = readTopicMap();
    const now = new Date().toISOString();
    const next = {
      ...current,
      chatId,
      updatedAt: now,
      topics: {
        ...(current.topics || {}),
        [topicToBind]: {
          threadId,
          boundAt: now,
          boundBy: from.id,
          dynamic: !resolved,
        },
      },
    };
    writeTopicMap(next);

    await api('sendMessage', {
      chat_id: chatId,
      message_thread_id: threadId,
      text: `OK. tópico \"${topicToBind}\" vinculado ao threadId=${threadId}${!resolved ? ' (dynamic)' : ''}.`,
    });
    return;
  }

  // /approve (host ops approvals)

  if (cmd === '/approve') {
    const action = (args[0] || '').trim();
    const target = (args[1] || '').trim();
    const minutesRaw = (action === 'install' ? (args[2] || '').trim() : (args[1] || '').trim());
    const minutes = minutesRaw ? Number.parseInt(minutesRaw, 10) : 45;
    const ttlMin = Number.isFinite(minutes) && minutes > 0 && minutes <= 720 ? minutes : 45;

    if (!action) {
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId || undefined,
        text: 'Uso:\n- /approve packages [minutos] (apt upgrade)\n- /approve install <pacote> [minutos] (apt install)',
      });
      return;
    }

    const allowed = new Set(['packages', 'install']);
    if (!allowed.has(action)) {
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId || undefined,
        text: `Ação inválida: ${action}. Permitidas: packages, install`,
      });
      return;
    }

    if (action === 'install') {
      if (!target) {
        await api('sendMessage', {
          chat_id: chatId,
          message_thread_id: threadId || undefined,
          text: 'Uso: /approve install <pacote> [minutos]. Ex: /approve install htop 120',
        });
        return;
      }
      if (!/^[a-z0-9][a-z0-9+.-]{0,62}$/.test(target)) {
        await api('sendMessage', {
          chat_id: chatId,
          message_thread_id: threadId || undefined,
          text: 'Nome de pacote inválido. Use apenas a-z 0-9 + . -',
        });
        return;
      }
    }

    const expiresAtEpoch = Math.floor(Date.now() / 1000) + ttlMin * 60;
    const approvalName = action === 'install' ? `install-${target}` : action;
    const approvalPath = path.join(approvalsDir, `${approvalName}.json`);
    writeJsonAtomic(approvalPath, {
      action,
      target: action === 'install' ? target : null,
      approvedAt: new Date().toISOString(),
      expiresAtEpoch,
      chatId,
      threadId,
      by: { id: from.id, username: from.username },
    });

    await api('sendMessage', {
      chat_id: chatId,
      message_thread_id: threadId || undefined,
      text: action === 'install'
        ? `OK. Aprovado: install ${target} por ${ttlMin} min.`
        : `OK. Aprovado: ${action} por ${ttlMin} min.`,
    });
    return;
  }


  if (cmd === '/approvals') {
    let files = [];
    try {
      files = fs.readdirSync(approvalsDir).filter((f) => f.endsWith('.json'));
    } catch {}

    const lines = files
      .map((f) => {
        const data = readJson(path.join(approvalsDir, f), null);
        const exp = data?.expiresAtEpoch ? new Date(data.expiresAtEpoch * 1000).toISOString() : 'n/a';
        return `${f.replace(/\.json$/, '')}: expires=${exp}`;
      })
      .sort((a, b) => a.localeCompare(b));

    await api('sendMessage', {
      chat_id: chatId,
      message_thread_id: threadId || undefined,
      text: lines.length ? `Approvals:\n${lines.join('\n')}` : 'Nenhuma approval ativa.',
    });
    return;
  }


  if (cmd === '/meta') {
    if (!agentGatewayUrl) {
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId || undefined,
        text: 'agent-gateway não configurado neste gateway.',
      });
      return;
    }

    try {
      const res = await fetch(`${agentGatewayUrl.replace(/\/$/, '')}/meta`, { method: 'GET' });
      const data = await res.json().catch(() => null);
      const model = data?.opencode?.modelDefaultEnv || data?.opencode?.modelConfig || '(unknown)';
      const img = data?.opencode?.image || '(unknown)';
      const t = data?.opencode?.timeoutMs || '(unknown)';
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId || undefined,
        text: `META
- model: ${model}
- image: ${img}
- timeoutMs: ${t}`,
      });
    } catch (err) {
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId || undefined,
        text: `Erro /meta: ${String(err?.message || err)}`,
      });
    }
    return;
  }

  if (cmd === '/topics') {
    const topicMap = readTopicMap();
    const predefined = Object.keys(config.topics || {});
    const dynamic = Object.keys(topicMap.topics || {}).filter((k) => !predefined.includes(k)).sort((a, b) => a.localeCompare(b));
    const keys = [...predefined, ...dynamic];
    const lines = keys.map((k) => {
      const info = topicMap?.topics?.[k] || null;
      const id = info?.threadId ?? null;
      const suffix = info?.dynamic ? ' (dynamic)' : '';
      return `${k}: ${id ? `threadId=${id}` : 'unbound (envie /bind neste tópico)'}${suffix}`;
    });
    await api('sendMessage', {
      chat_id: chatId,
      message_thread_id: threadId || undefined,
      text: `Tópicos (${keys.length}):\n${lines.join('\n')}`,
    });
    return;
  }

  if (text === '/status') {
    const topicMap = readTopicMap();
    const bound = topicMap?.topics?.[topicKey]?.threadId === threadId;
    await api('sendMessage', {
      chat_id: chatId,
      message_thread_id: threadId || undefined,
      text: `OK. gateway online. topic=${topicKey} thread=${threadId} (sessão independente).${bound ? '' : ' (não vinculado: use /bind <nome>)'}`,
    });
    return;
  }

  if (text === '/ping') {
    await api('sendMessage', {
      chat_id: chatId,
      message_thread_id: threadId || undefined,
      text: 'pong',
    });
    return;
  }

  // default: forward to agent-gateway (LLM responder) if configured
  if (agentGatewayUrl) {
    try {
      const result = await callAgentGateway({
        chatId,
        threadId,
        topicKey,
        from: { id: from.id, username: from.username },
        text,
      });

      const reply = (result?.reply || '').trim();
      if (reply) {
        await api('sendMessage', {
          chat_id: chatId,
          message_thread_id: threadId || undefined,
          text: reply,
        });
      }
    } catch (err) {
      await api('sendMessage', {
        chat_id: chatId,
        message_thread_id: threadId || undefined,
        text: `Erro no agent-gateway: ${String(err?.message || err)}`,
      });
    }
  }
}

async function pollForever() {
  console.log('telegram-gateway starting');
  console.log(`groupId=${config.groupId} offset=${offsetState.offset}`);

  while (true) {
    try {
      const updates = await api('getUpdates', {
        offset: offsetState.offset,
        timeout: 30,
        allowed_updates: ['message'],
      });

      if (Array.isArray(updates) && updates.length) {
        for (const u of updates) {
          offsetState.offset = Math.max(offsetState.offset, u.update_id + 1);
          if (u.message) await handleMessage(u.message);
        }
        writeJsonAtomic(offsetPath, offsetState);
      }
    } catch (err) {
      console.error(String(err?.stack || err));
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
}

await pollForever();
