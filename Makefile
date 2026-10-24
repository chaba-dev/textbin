.PHONY: dev
dev:
	mix phx.server

.PHONY: website-dev
website-dev:
	hugo server --source website --buildDrafts --disableFastRender

.PHONY: website-build
website-build:
	hugo --source website --minify --cleanDestinationDir

.PHONY: website-clean
website-clean:
	rm -rf website/public website/resources/_gen website/.hugo_build.lock

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

.PHONY: ex-lint
ex-lint:
	mix credo

.PHONY: rs-lint
rs-lint:
	cargo clippy --workspace --all-features -- -D warnings

.PHONY: rs-fmt
rs-fmt:
	cargo fmt --check

.PHONY: up
up:
	docker compose up -d

.PHONY: down
down:
	docker compose stop

.PHONY: migrate
migrate:
	mix ecto.migration

.PHONY: changelog
changelog:
	git cliff -o CHANGELOG.md

.PHONY: bump
bump:
	git cliff --bump -o CHANGELOG.md

.PHONY: psql
psql:
	psql -h "$(CURDIR)/tmp/postgres-socket" -U postgres -d textbin_dev
