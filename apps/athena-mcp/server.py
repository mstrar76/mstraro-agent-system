#!/usr/bin/env python3
"""
Athena MCP Server — Model Context Protocol Server for GraphRAG

Provides smart_search, recall, and schema discovery via SSE transport.

Usage:
    python server.py

Endpoints:
    GET  /sse              - SSE transport
    POST /search           - Smart search (keyword + semantic + RRF)
    POST /recall           - Recall context from sessions
    GET  /schema           - Get Neo4j schema and indexes
    GET  /health           - Health check
"""

import asyncio
import json
import logging
from typing import List, Dict, Any, Optional
from datetime import datetime
from decimal import Decimal

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sse_starlette.sse import EventSourceResponse
from neo4j import GraphDatabase
from neo4j.time import DateTime as Neo4jDateTime
from sentence_transformers import SentenceTransformer

from config import (
    NEO4J_URI, NEO4J_USERNAME, NEO4J_PASSWORD, NEO4J_DATABASE,
    OPENAI_API_KEY, EMBEDDING_MODEL,
    MCP_HOST, MCP_PORT, DEFAULT_TOP_K, VECTOR_TOP_K, FULLTEXT_TOP_K, RRF_K
)

# ─────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Athena MCP Server", version="1.0.0")


def serialize_for_json(obj: Any) -> Any:
    """Convert Neo4j types and other non-JSON types to JSON-serializable types"""
    if isinstance(obj, (datetime, Neo4jDateTime)):
        return obj.isoformat()
    elif isinstance(obj, Decimal):
        return float(obj)
    elif isinstance(obj, dict):
        return {k: serialize_for_json(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [serialize_for_json(item) for item in obj]
    elif hasattr(obj, 'isoformat'):  # Any datetime-like object
        return obj.isoformat()
    else:
        return obj

# Neo4j driver
driver = None
embedding_model = None

# ─────────────────────────────────────────────────────────────
# Neo4j Connection
# ─────────────────────────────────────────────────────────────

def get_driver():
    """Get Neo4j driver"""
    global driver
    if driver is None:
        driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USERNAME, NEO4J_PASSWORD))
    return driver

def verify_neo4j():
    """Verify Neo4j connectivity"""
    try:
        d = get_driver()
        d.verify_connectivity()
        logger.info("✅ Neo4j connected")
        return True
    except Exception as e:
        logger.error(f"❌ Neo4j connection failed: {e}")
        return False

# ─────────────────────────────────────────────────────────────
# Embedding Model
# ─────────────────────────────────────────────────────────────

def get_embedding_model():
    """Get sentence transformer for embeddings"""
    global embedding_model
    if embedding_model is None:
        # Use local model (no API key needed)
        embedding_model = SentenceTransformer('all-MiniLM-L6-v2')
    return embedding_model

def embed_query(query: str) -> List[float]:
    """Embed query using sentence transformer"""
    model = get_embedding_model()
    embedding = model.encode(query, convert_to_numpy=True)
    return embedding.tolist()

# ─────────────────────────────────────────────────────────────
# Search Functions
# ─────────────────────────────────────────────────────────────

def get_neo4j_schema() -> Dict[str, Any]:
    """Get Neo4j schema and indexes"""
    query = """
    CALL db.schema.visualization()
    YIELD nodes, relationships
    RETURN nodes, relationships
    """
    
    indexes_query = """
    SHOW INDEXES
    YIELD name, type, state, entityType, labelsOrTypes, properties
    RETURN name, type, state, entityType, labelsOrTypes, properties
    """
    
    with get_driver().session(database=NEO4J_DATABASE) as session:
        try:
            schema_result = session.run(query)
            schema = schema_result.single()
            
            indexes_result = session.run(indexes_query)
            indexes = [record.data() for record in indexes_result]
            
            return {
                "nodes": schema["nodes"] if schema else 0,
                "relationships": schema["relationships"] if schema else 0,
                "indexes": indexes
            }
        except Exception as e:
            logger.error(f"Schema error: {e}")
            return {"error": str(e)}

def vector_search(query: str, top_k: int = VECTOR_TOP_K) -> List[Dict]:
    """Vector similarity search"""
    query_embedding = embed_query(query)
    
    cypher = """
    MATCH (n)
    WHERE n.embedding IS NOT NULL
    WITH n, vector.similarity.cosine(n.embedding, $query_embedding) AS score
    ORDER BY score DESC
    LIMIT $top_k
    RETURN 
        elementId(n) as id,
        labels(n) as labels,
        n.name as name,
        n.description as description,
        n.created_at as created_at,
        score
    """
    
    with get_driver().session(database=NEO4J_DATABASE) as session:
        result = session.run(cypher, query_embedding=query_embedding, top_k=top_k)
        return [record.data() for record in result]

def fulltext_search(query: str, top_k: int = FULLTEXT_TOP_K) -> List[Dict]:
    """Fulltext keyword search with Lucene syntax"""
    # Try memory_fulltext index first
    cypher = """
    CALL db.index.fulltext.queryNodes(
        'memory_fulltext', 
        $query, 
        {limit: $top_k}
    )
    YIELD node, score
    RETURN 
        elementId(node) as id,
        labels(node) as labels,
        node.name as name,
        node.description as description,
        node.created_at as created_at,
        score
    """
    
    with get_driver().session(database=NEO4J_DATABASE) as session:
        try:
            result = session.run(cypher, query=query, top_k=top_k)
            return [record.data() for record in result]
        except Exception as e:
            logger.warning(f"Fulltext search failed: {e}")
            # Fallback to simple text search
            return simple_text_search(query, top_k)

def simple_text_search(query: str, top_k: int = FULLTEXT_TOP_K) -> List[Dict]:
    """Fallback simple text search"""
    cypher = """
    MATCH (n)
    WHERE n.name CONTAINS $search_query OR n.description CONTAINS $search_query
    RETURN 
        elementId(n) as id,
        labels(n) as labels,
        n.name as name,
        n.description as description,
        n.created_at as created_at,
        1.0 as score
    LIMIT $top_k
    """
    
    with get_driver().session(database=NEO4J_DATABASE) as session:
        result = session.run(cypher, search_query=query, top_k=top_k)
        return [record.data() for record in result]

def reciprocal_rank_fusion(
    vector_results: List[Dict],
    fulltext_results: List[Dict],
    k: int = RRF_K
) -> List[Dict]:
    """
    Reciprocal Rank Fusion (RRF) for hybrid search.
    
    RRF score = 1 / (k + rank)
    """
    score_map = {}
    
    # Score from vector results
    for rank, result in enumerate(vector_results):
        result_id = result.get("id")
        if result_id:
            if result_id not in score_map:
                score_map[result_id] = {**result, "rrf_score": 0}
            score_map[result_id]["rrf_score"] += 1 / (k + rank + 1)
    
    # Score from fulltext results
    for rank, result in enumerate(fulltext_results):
        result_id = result.get("id")
        if result_id:
            if result_id not in score_map:
                score_map[result_id] = {**result, "rrf_score": 0}
            score_map[result_id]["rrf_score"] += 1 / (k + rank + 1)
    
    # Sort by RRF score
    fused_results = sorted(
        score_map.values(),
        key=lambda x: x["rrf_score"],
        reverse=True
    )
    
    return fused_results[:top_k] if (top_k := DEFAULT_TOP_K) else fused_results

def smart_search(query: str, top_k: int = DEFAULT_TOP_K) -> Dict[str, Any]:
    """
    Smart search: hybrid search with RRF fusion.
    
    Combines:
    1. Vector similarity search (semantic)
    2. Fulltext search (keyword)
    3. RRF fusion
    """
    start_time = datetime.now()
    
    # Parallel search
    vector_results = vector_search(query, top_k=top_k)
    fulltext_results = fulltext_search(query, top_k=top_k)
    
    # RRF fusion
    fused_results = reciprocal_rank_fusion(vector_results, fulltext_results)
    
    elapsed = (datetime.now() - start_time).total_seconds()
    
    return {
        "query": query,
        "results": serialize_for_json(fused_results),
        "stats": {
            "vector_results": len(vector_results),
            "fulltext_results": len(fulltext_results),
            "fused_results": len(fused_results),
            "elapsed_ms": elapsed * 1000
        }
    }

def recall_context(
    agent_type: Optional[str] = None,
    days: int = 30,
    top_k: int = DEFAULT_TOP_K
) -> Dict[str, Any]:
    """
    Recall context from recent sessions.
    
    Retrieves:
    - Recent decisions
    - Recent entities
    - Recent sessions
    - Checkpoints
    """
    start_time = datetime.now()
    
    with get_driver().session(database=NEO4J_DATABASE) as session:
        results = {}
        
        # Recent decisions
        if agent_type:
            query = """
            MATCH (d:Decision)
            WHERE d.agent_type = $agent_type
            RETURN d.name as name, d.description as description, d.created_at as created_at
            ORDER BY d.created_at DESC
            LIMIT $top_k
            """
            result = session.run(query, agent_type=agent_type, top_k=top_k)
            results["decisions"] = [serialize_for_json(record.data()) for record in result]
        else:
            query = """
            MATCH (d:Decision)
            RETURN d.name as name, d.description as description, d.created_at as created_at
            ORDER BY d.created_at DESC
            LIMIT $top_k
            """
            result = session.run(query, top_k=top_k)
            results["decisions"] = [serialize_for_json(record.data()) for record in result]
        
        # Recent entities
        query = """
        MATCH (e:Entity)
        RETURN e.name as name, e.description as description, e.created_at as created_at
        ORDER BY e.created_at DESC
        LIMIT $top_k
        """
        result = session.run(query, top_k=top_k)
        results["entities"] = [serialize_for_json(record.data()) for record in result]
        
        # Recent sessions
        query = """
        MATCH (s:Session)
        RETURN s.id as id, s.title as title, s.start_time as start_time
        ORDER BY s.start_time DESC
        LIMIT $top_k
        """
        result = session.run(query, top_k=top_k)
        results["sessions"] = [serialize_for_json(record.data()) for record in result]
        
        # Checkpoints
        query = """
        MATCH (c:Checkpoint)
        RETURN c.name as name, c.description as description, c.created_at as created_at
        ORDER BY c.created_at DESC
        LIMIT $top_k
        """
        result = session.run(query, top_k=top_k)
        results["checkpoints"] = [serialize_for_json(record.data()) for record in result]
    
    elapsed = (datetime.now() - start_time).total_seconds()
    
    return {
        "agent_type": agent_type,
        "days": days,
        "results": serialize_for_json(results),
        "stats": {
            "elapsed_ms": elapsed * 1000
        }
    }

# ─────────────────────────────────────────────────────────────
# API Endpoints
# ─────────────────────────────────────────────────────────────

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    neo4j_ok = verify_neo4j()
    return {
        "status": "healthy" if neo4j_ok else "degraded",
        "neo4j": "connected" if neo4j_ok else "disconnected",
        "timestamp": datetime.now().isoformat()
    }

@app.get("/schema")
async def get_schema():
    """Get Neo4j schema and indexes"""
    return get_neo4j_schema()

@app.post("/search")
async def search(request: Request):
    """
    Smart search endpoint.
    
    Request:
    {
        "query": "minhas decisões sobre arquitetura",
        "top_k": 5
    }
    
    Response:
    {
        "query": "...",
        "results": [...],
        "stats": {...}
    }
    """
    body = await request.json()
    query = body.get("query", "")
    top_k = body.get("top_k", DEFAULT_TOP_K)
    
    if not query:
        return JSONResponse(
            status_code=400,
            content={"error": "query is required"}
        )
    
    results = smart_search(query, top_k=top_k)
    return JSONResponse(content=results)

@app.post("/recall")
async def recall(request: Request):
    """
    Recall context endpoint.
    
    Request:
    {
        "agent_type": "claude-code",
        "days": 30,
        "top_k": 5
    }
    
    Response:
    {
        "agent_type": "...",
        "results": {...},
        "stats": {...}
    }
    """
    body = await request.json()
    agent_type = body.get("agent_type")
    days = body.get("days", 30)
    top_k = body.get("top_k", DEFAULT_TOP_K)
    
    results = recall_context(agent_type=agent_type, days=days, top_k=top_k)
    return JSONResponse(content=serialize_for_json(results))

@app.get("/sse")
async def sse_endpoint():
    """SSE transport for MCP"""
    
    async def event_generator():
        """Generate SSE events"""
        while True:
            yield {
                "event": "message",
                "data": json.dumps({
                    "type": "ping",
                    "timestamp": datetime.now().isoformat()
                })
            }
            await asyncio.sleep(30)
    
    return EventSourceResponse(event_generator())

# ─────────────────────────────────────────────────────────────
# Startup/Shutdown
# ─────────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup_event():
    """Startup event"""
    logger.info("🚀 Athena MCP Server starting...")
    verify_neo4j()
    get_embedding_model()
    logger.info(f"✅ Server ready on http://{MCP_HOST}:{MCP_PORT}")

@app.on_event("shutdown")
async def shutdown_event():
    """Shutdown event"""
    logger.info("👋 Athena MCP Server shutting down...")
    if driver:
        driver.close()

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "server:app",
        host=MCP_HOST,
        port=MCP_PORT,
        reload=False
    )
