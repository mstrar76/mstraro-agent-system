import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ATHENA_MCP_URL = 'http://agent_athena_mcp:8888';
const FILESET_DIR = '/workspace/fileset';

// Logger simples
function logEvent(event, data = {}) {
  const entry = {
    timestamp: new Date().toISOString(),
    event,
    ...data
  };
  console.log(`[BOOT] ${event}:`, JSON.stringify(data));
  
  // Opcional: salvar em arquivo
  const logFile = '/tmp/agent-gateway-boot.log';
  fs.appendFileSync(logFile, JSON.stringify(entry) + '\n');
}

// Carregar fileset do gestor
function loadFilesetSnippet() {
  const wanted = [
    'SOUL.md', 
    'USER.md', 
    'BOT-RULES.md', 
    'DELEGATION.md',
    'MEMORY.md'
  ];
  
  const parts = [];
  for (const name of wanted) {
    const p = path.join(FILESET_DIR, name);
    if (!fs.existsSync(p)) continue;
    
    try {
      const content = fs.readFileSync(p, 'utf8').trim();
      if (!content) continue;
      parts.push(`\n### ${name}\n${content.substring(0, 2000)}`); // Limitar tamanho
    } catch (e) {
      console.error(`[BOOT] Error loading ${name}:`, e.message);
    }
  }
  
  if (!parts.length) {
    console.warn('[BOOT] No fileset files found');
    return '';
  }
  
  return `# FILESET (core)\n${parts.join('')}`;
}

// Verificar saúde do Athena MCP
async function checkAthenaHealth() {
  return new Promise((resolve) => {
    const req = http.get(`${ATHENA_MCP_URL}/health`, (res) => {
      resolve(res.statusCode === 200);
    });
    req.on('error', () => resolve(false));
    req.setTimeout(3000, () => {
      req.destroy();
      resolve(false);
    });
  });
}

// Recuperar contexto do Neo4j via Athena MCP
async function recallContextFromNeo4j(agentType = 'gestor', days = 7, topK = 5) {
  return new Promise((resolve) => {
    const data = JSON.stringify({ agent_type: agentType, days, top_k: topK });
    
    const req = http.request(
      `${ATHENA_MCP_URL}/recall`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data)
        },
        timeout: 5000
      },
      (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch {
            resolve(null);
          }
        });
      }
    );
    
    req.on('error', () => resolve(null));
    req.on('timeout', () => {
      req.destroy();
      resolve(null);
    });
    
    req.write(data);
    req.end();
  });
}

// Buscar no GraphRAG
async function searchGraphRAG(query, topK = 3) {
  return new Promise((resolve) => {
    const data = JSON.stringify({ query, top_k: topK });
    
    const req = http.request(
      `${ATHENA_MCP_URL}/search`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data)
        },
        timeout: 5000
      },
      (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch {
            resolve(null);
          }
        });
      }
    );
    
    req.on('error', () => resolve(null));
    req.on('timeout', () => {
      req.destroy();
      resolve(null);
    });
    
    req.write(data);
    req.end();
  });
}

// Auto-boot no startup
export async function autoBootOnStartup() {
  console.log('🚀 [BOOT] Agent Gateway Auto-Boot iniciando...');
  const t0 = Date.now();
  
  const bootStatus = {
    filesetLoaded: false,
    athenaConnected: false,
    neo4jContextLoaded: false,
    errors: []
  };
  
  try {
    // 1. Carregar fileset do gestor
    console.log('[BOOT] 1/4 Carregando fileset...');
    const fileset = loadFilesetSnippet();
    bootStatus.filesetLoaded = !!fileset;
    console.log(`[BOOT] ✅ Fileset: ${fileset ? 'OK' : 'FALHOU'}`);
    
    // 2. Verificar Athena MCP
    console.log('[BOOT] 2/4 Verificando Athena MCP...');
    bootStatus.athenaConnected = await checkAthenaHealth();
    console.log(`[BOOT] ✅ Athena MCP: ${bootStatus.athenaConnected ? 'OK' : 'OFFLINE'}`);
    
    // 3. Carregar contexto do Neo4j (se Athena disponível)
    let neo4jContext = null;
    if (bootStatus.athenaConnected) {
      console.log('[BOOT] 3/4 Recuperando contexto do Neo4j...');
      
      const recall = await recallContextFromNeo4j('gestor', 7, 5);
      if (recall && recall.results) {
        const decisions = recall.results.decisions || [];
        const entities = recall.results.entities || [];
        
        console.log(`[BOOT] 📊 Neo4j: ${decisions.length} decisões, ${entities.length} entidades`);
        
        // Formatar contexto resumido
        const contextParts = [];
        
        if (decisions.length > 0) {
          contextParts.push('\n📋 Decisões Recentes:');
          decisions.slice(0, 3).forEach(d => {
            contextParts.push(`  • ${d.name || 'Sem título'}: ${(d.description || '').substring(0, 100)}`);
          });
        }
        
        if (entities.length > 0) {
          contextParts.push('\n🔧 Entidades:');
          entities.slice(0, 3).forEach(e => {
            contextParts.push(`  • ${e.name || 'Sem nome'}`);
          });
        }
        
        neo4jContext = contextParts.join('\n');
        bootStatus.neo4jContextLoaded = true;
        console.log('[BOOT] ✅ Contexto Neo4j carregado');
      } else {
        console.log('[BOOT] ⚠️  Neo4j vazio ou indisponível');
      }
    } else {
      console.log('[BOOT] ⚠️  Pulando Neo4j (Athena offline)');
    }
    
    // 4. Log de inicialização
    const duration = Date.now() - t0;
    logEvent('gateway_startup_complete', {
      durationMs: duration,
      ...bootStatus
    });
    
    console.log('✅ [BOOT] Auto-boot completo em', duration, 'ms');
    
    // Retornar contexto combinado para uso posterior
    return {
      fileset,
      neo4jContext,
      bootStatus,
      timestamp: new Date().toISOString()
    };
    
  } catch (error) {
    console.error('❌ [BOOT] Erro no auto-boot:', error);
    logEvent('gateway_startup_error', { error: error.message });
    
    // Retornar contexto mínimo mesmo em caso de erro
    return {
      fileset: loadFilesetSnippet(),
      neo4jContext: null,
      bootStatus,
      timestamp: new Date().toISOString()
    };
  }
}

// Função para recuperar sessão existente
export async function findExistingSession(userId, topicKey) {
  // Implementação básica - pode ser expandida para consultar Neo4j
  console.log(`[BOOT] Buscando sessão existente para ${userId}/${topicKey}`);
  
  // Por enquanto, retorna null (nova sessão)
  // TODO: Implementar busca no Neo4j
  return null;
}

// Exportar funções úteis
export { loadFilesetSnippet, checkAthenaHealth, recallContextFromNeo4j, searchGraphRAG };
