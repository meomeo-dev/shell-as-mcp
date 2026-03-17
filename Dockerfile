# Build stage
FROM node:22-alpine AS builder

WORKDIR /app

COPY package*.json tsconfig.json ./
RUN npm ci

COPY src ./src
COPY shell_as_mcp_defs ./shell_as_mcp_defs
RUN npm run build && rm -rf dist/shell_as_mcp_defs && cp -r shell_as_mcp_defs dist/shell_as_mcp_defs

# Runtime stage
FROM node:22-alpine

# Create non-root user for security
RUN addgroup -g 1000 mcpuser && adduser -D -u 1000 -G mcpuser mcpuser

# Create workspace directory
RUN mkdir -p /tmp/mcp-workspace && \
    chown mcpuser:mcpuser /tmp/mcp-workspace

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json ./

# shell_as_mcp_defs is embedded in dist/shell_as_mcp_defs at build time;
# SHELL_AS_MCP_SPEC_DIR is intentionally unset so resolveBundledSpecDir auto-detects it.

# Switch to non-root user
USER mcpuser
WORKDIR /tmp/mcp-workspace

ENTRYPOINT ["node", "/app/dist/src/index.js"]
