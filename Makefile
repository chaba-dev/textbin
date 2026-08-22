.PHONY: dev
dev:
	mix phx.server

.PHONY: test
test: ex-test rs-test

.PHONY: ex-test
ex-test:
	mix test

.PHONY: rs-test
rs-test:
	cargo test --workspace

.PHONY: lint
lint: ex-lint rs-lint

.PHONY: check-rfds
check-rfds:
	./scripts/check-rfd-status.sh
	./scripts/check-rfd-status-test.sh

.PHONY: ex-lint
ex-lint:
	mix credo

.PHONY: rs-lint
rs-lint:
	cargo clippy --workspace --all-features -- -D warnings

.PHONY: rs-fmt
rs-fmt:
	cargo fmt --check

.PHONY: migrate
migrate:
	mix ecto.migration

.PHONY: changelog
changelog:
	git cliff -o CHANGELOG.md

.PHONY: bump
bump:
	git cliff --bump -o CHANGELOG.md

.PHONY: db
db:
	psql -h 127.0.0.1 -U postgres -d textbin_dev -W
