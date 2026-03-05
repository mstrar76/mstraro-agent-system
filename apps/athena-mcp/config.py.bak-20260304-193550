"""
Athena MCP Server Configuration
"""
import os
from dotenv import load_dotenv

load_dotenv()

# Neo4j Configuration
NEO4J_URI = os.getenv("NEO4J_URI", "bolt://localhost:7687")
NEO4J_USERNAME = os.getenv("NEO4J_USERNAME", "neo4j")
NEO4J_PASSWORD = os.getenv("NEO4J_PASSWORD")
NEO4J_DATABASE = os.getenv("NEO4J_DATABASE", "neo4j")

# OpenAI Configuration
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "text-embedding-ada-002")

# Server Configuration
MCP_HOST = os.getenv("MCP_HOST", "0.0.0.0")
MCP_PORT = int(os.getenv("MCP_PORT", "8888"))

# Search Configuration
DEFAULT_TOP_K = int(os.getenv("DEFAULT_TOP_K", "5"))
VECTOR_TOP_K = int(os.getenv("VECTOR_TOP_K", "10"))
FULLTEXT_TOP_K = int(os.getenv("FULLTEXT_TOP_K", "10"))

# RRF Configuration
RRF_K = int(os.getenv("RRF_K", "60"))  # RRF constant k
