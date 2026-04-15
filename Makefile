# ################################################################################
# # Configuration and Variables
# ################################################################################
ZIG_LOCAL  := $(HOME)/.local/share/zig/0.16.0/zig
ZIG        ?= $(shell test -x $(ZIG_LOCAL) && echo $(ZIG_LOCAL) || which zig)
BUILD_TYPE    ?= Debug
BUILD_OPTS      = -Doptimize=$(BUILD_TYPE)
JOBS          ?= $(shell nproc || echo 2)
SRC_DIR       := src
EXAMPLES_DIR  := examples
BUILD_DIR     := zig-out
CACHE_DIR     := .zig-cache
BINARY_NAME   := example
RELEASE_MODE := ReleaseSmall
TEST_FLAGS := --summary all #--verbose
JUNK_FILES := *.o *.obj *.dSYM *.dll *.so *.dylib *.a *.lib *.pdb

# Automatically find all example names
EXAMPLES      := $(patsubst %.zig,%,$(notdir $(wildcard examples/*.zig)))
EXAMPLE       ?= all

SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eu -o pipefail -c

################################################################################
# Targets
################################################################################

.PHONY: all help build rebuild run test release clean lint format docs serve-docs install-deps setup-hooks test-hooks
.DEFAULT_GOAL := help

help: ## Show the help messages for all targets
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*## .*$$' Makefile | \
	awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

all: build test lint docs  ## build, test, lint, and doc

build: ## Build project (Mode=$(BUILD_TYPE))
	@echo "Building project in $(BUILD_TYPE) mode with $(JOBS) concurrent jobs..."
	@$(ZIG) build $(BUILD_OPTS) -j$(JOBS)

rebuild: clean build  ## clean and build

run: ## Run an example (e.g. 'make run EXAMPLE=e1_simple_cli' or 'make run' for all)
	@if [ "$(EXAMPLE)" = "all" ]; then \
	   echo "--> Running all examples..."; \
	   for ex in $(EXAMPLES); do \
		  echo ""; \
		  echo "--> Running example: $$ex"; \
		  $(ZIG) build run-$$ex $(BUILD_OPTS); \
	   done; \
	else \
	   echo "--> Running example: $(EXAMPLE)"; \
	   $(ZIG) build run-$(EXAMPLE) $(BUILD_OPTS); \
	fi

test: ## Run tests
	@echo "Running tests..."
	@$(ZIG) build test $(BUILD_OPTS) -j$(JOBS) $(TEST_FLAGS)

release: ## Build in Release mode
	@echo "Building the project in Release mode..."
	@$(MAKE) BUILD_TYPE=$(RELEASE_MODE) build

clean: ## Remove docs, build artifacts, and cache directories
	@echo "Removing build artifacts, cache, generated docs, and junk files..."
	@rm -rf $(BUILD_DIR) $(CACHE_DIR) $(JUNK_FILES) docs/api public

lint: ## Check code style and formatting of Zig files
	@echo "Running code style checks..."
	@$(ZIG) fmt --check $(SRC_DIR) $(EXAMPLES_DIR)

format: ## Format Zig files
	@echo "Formatting Zig files..."
	@$(ZIG) fmt .

docs: ## Generate API documentation
	@echo "Generating API documentation..."
	@$(ZIG) build docs

serve-docs: docs ## Serve the generated documentation on a local server
	@echo "Serving documentation at http://localhost:8000..."
	@cd docs/api && python3 -m http.server 8000

install-deps: ## Install system dependencies (for Debian-based systems)
	@echo "Installing system dependencies..."
	@sudo apt-get update
	@sudo apt-get install -y make llvm snapd
	@sudo snap install zig --beta --classic

setup-hooks: ## Install Git hooks (pre-commit and pre-push)
	@echo "Setting up Git hooks..."
	@if ! command -v pre-commit &> /dev/null; then \
	   echo "pre-commit not found. Please install it using 'pip install pre-commit'"; \
	   exit 1; \
	fi
	@pre-commit install --hook-type pre-commit
	@pre-commit install --hook-type pre-push
	@pre-commit install-hooks

test-hooks: ## Test Git hooks on all files
	@echo "Testing Git hooks..."
	@pre-commit run --all-files --show-diff-on-failure
