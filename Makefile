.PHONY: test lint verify

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/specs/ {minimal_init = 'tests/minimal_init.lua'}"

lint:
	stylua --check lua/
	selene lua/
	if command -v shellcheck >/dev/null 2>&1; then 		shellcheck scripts/*.sh bin/lvim; 	else 		printf '%s\n' 'shellcheck not installed; falling back to shell syntax checks'; 		bash -n scripts/*.sh bin/lvim; 	fi

# `make verify` is the local pre-push gate: it runs lints and then the full
# end-to-end integration smoke (scripts/integration-smoke.sh). The integration
# smoke installs plugins and a language server, so the first run is slow and
# needs network access; subsequent CI runs are bound by the same constraints.
verify: lint
	bash scripts/integration-smoke.sh
