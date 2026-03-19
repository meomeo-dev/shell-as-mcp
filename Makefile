.PHONY: help deps build run test clean lint regress-pack-smoke docker-e2e-smoke docker-build docker-run docker-shell

IMAGE_NAME=shell-as-mcp
VERSION?=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

help: ## Show available commands
	@echo "shell-as-mcp development commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

deps: ## Install dependencies
	npm ci

build: clean ## Build TypeScript project (clean + compile TS + copy runtime assets)
	npm run build
	rm -rf dist/shell_as_mcp_defs && cp -r shell_as_mcp_defs dist/shell_as_mcp_defs

run: ## Run MCP server from built output
	npm start

test: ## Run TypeScript tests + run_safe_command contract smoke
	npm test
	bash shell_as_mcp_defs/run_safe_command/scripts/run_safe_command__smoke_test.sh

clean: ## Remove build artifacts
	rm -rf dist

lint: ## Run all static spec validators
	bash scripts/lint/lint_all.sh

regress-pack-smoke: ## Build + pack + strict streamable-http handshake smoke test
	bash scripts/regress_pack_smoke.sh

docker-e2e-smoke: ## Build Docker image + run MCP handshake + call healthz in container
	bash scripts/docker_e2e_smoke.sh

docker-build: ## Build Docker image
	docker build -t $(IMAGE_NAME):$(VERSION) -t $(IMAGE_NAME):latest .

docker-run: ## Run Docker image
	docker run -it --rm -v /tmp/mcp-workspace:/tmp/mcp-workspace $(IMAGE_NAME):$(VERSION)

docker-shell: ## Open shell in Docker image
	docker run -it --rm -v /tmp/mcp-workspace:/tmp/mcp-workspace --entrypoint /bin/sh $(IMAGE_NAME):$(VERSION)
