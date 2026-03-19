# Build stage
FROM node:22-alpine AS builder

WORKDIR /app

COPY package*.json tsconfig.json ./
RUN npm ci --ignore-scripts

COPY src ./src
COPY shell_as_mcp_defs ./shell_as_mcp_defs
RUN npm run build && rm -rf dist/shell_as_mcp_defs && cp -r shell_as_mcp_defs dist/shell_as_mcp_defs

# Runtime stage
FROM node:22-alpine

# Install bash for bundle scripts that declare bash interpreter.
RUN apk add --no-cache bash

# Create workspace directory
RUN mkdir -p /tmp/mcp-workspace && \
    chown node:node /tmp/mcp-workspace

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json ./

# shell_as_mcp_defs is embedded in dist/shell_as_mcp_defs at build time;
# SHELL_AS_MCP_SPEC_DIR is intentionally unset so resolveBundledSpecDir auto-detects it.

# Switch to non-root user (provided by official node image)
USER node
WORKDIR /tmp/mcp-workspace

ENTRYPOINT ["node", "/app/dist/src/index.js"]
