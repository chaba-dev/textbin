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
	cargo test

.PHONY: lint
lint: ex-lint rs-lint

.PHONY: ex-lint
ex-lint:
	mix credo

.PHONY: rs-lint
rs-lint:
	cargo clippy --all-features -- -D warnings

.PHONY: up
up:
	docker compose up -d

.PHONY: down
down:
	docker compose stop

.PHONY: migrate
migrate:
	mix ecto.migration

.PHONY: db
db:
	psql -h 127.0.0.1 -U postgres -d textbin_dev -W
