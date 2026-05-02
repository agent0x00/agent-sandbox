PREFIX ?= /home/jchen/.local
BINDIR = $(PREFIX)/bin
SANDBOX_DIR = /home/jchen/ai-playground/agent-sandbox

CFLAGS = -Wall -Wextra -Wno-format-truncation -O2

.PHONY: all build test install clean

all: build

build: landlock-wrap

landlock-wrap: landlock-wrap.c
	gcc $(CFLAGS) -o $@ $<

test:
	tests/test_project_root.sh ./landlock-wrap
	tests/test_ruleset.sh ./landlock-wrap
	tests/test_enforcement.sh ./landlock-wrap
	tests/test_github_token.sh ./landlock-wrap
	tests/test_pre_push.sh ./hooks/pre-push
	tests/test_auto_discover.sh ./landlock-wrap
	tests/test_uninstall.sh ./uninstall.sh

install: build
	install -d $(BINDIR)
	install -m 755 landlock-wrap $(BINDIR)/landlock-wrap
	install -m 755 bin/claude-sandboxed $(BINDIR)/claude-sandboxed
	@echo "Run 'make link' to replace the claude symlink with the sandboxed version"

hooks-install:
	install -d $(HOME)/.config/git/hooks
	install -m 755 hooks/pre-push $(HOME)/.config/git/hooks/pre-push
	git config --global core.hooksPath $(HOME)/.config/git/hooks

link:
	rm -f $(BINDIR)/claude
	ln -s $(BINDIR)/claude-sandboxed $(BINDIR)/claude

unlink:
	rm -f $(BINDIR)/claude
	ln -s $(HOME)/.local/share/claude/versions/$$(ls -t $(HOME)/.local/share/claude/versions/ 2>/dev/null | head -1) $(BINDIR)/claude

clean:
	rm -f landlock-wrap
