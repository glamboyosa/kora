# Makefile for Kora

# Detect Host OS and Architecture for Sidecar Naming
# Rust target triples:
# macOS Apple Silicon: aarch64-apple-darwin
# macOS Intel: x86_64-apple-darwin
# Linux: x86_64-unknown-linux-gnu
# Windows: x86_64-pc-windows-msvc

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
	ifeq ($(UNAME_M),arm64)
		TARGET := aarch64-apple-darwin
		BURRITO_TARGET := macos
	else
		TARGET := x86_64-apple-darwin
		BURRITO_TARGET := macos
	endif
endif

ifeq ($(UNAME_S),Linux)
	TARGET := x86_64-unknown-linux-gnu
	BURRITO_TARGET := linux
endif

# If we couldn't detect, default to macOS arm64 for this environment (as per previous checks)
TARGET ?= aarch64-apple-darwin
BURRITO_TARGET ?= macos

.PHONY: all dev tauri-dev build build-elixir prep-sidecar build-tauri clean

all: dev

# 1. Run Phoenix Server (Dev Mode)
dev:
	mix phx.server

# 2. Run Tauri in Dev Mode (Requires Phoenix running separately or configured)
# We assume the user runs `make dev` in one terminal and `make tauri-dev` in another.
tauri-dev:
	cd src-tauri && cargo tauri dev

# 3. Full Build Pipeline
build: build-elixir prep-sidecar build-tauri

# Build Elixir Binary with Burrito
build-elixir:
	@echo "Building Elixir binary for target: $(BURRITO_TARGET)"
	mix burrito.build -t $(BURRITO_TARGET)

# Prepare Sidecar (Copy and Rename)
prep-sidecar:
	@echo "Preparing sidecar for target: $(TARGET)"
	mkdir -p src-tauri/bin
	# Burrito outputs to burrito_out/<target>/<app>
	# We need to copy it to src-tauri/bin/kora-<target>
	cp burrito_out/$(BURRITO_TARGET)/kora src-tauri/bin/kora-$(TARGET)
	chmod +x src-tauri/bin/kora-$(TARGET)

# Build Tauri App
build-tauri:
	@echo "Building Tauri app..."
	cd src-tauri && cargo tauri build

clean:
	rm -rf burrito_out
	rm -rf src-tauri/target
	rm -rf src-tauri/bin
