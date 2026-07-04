.PHONY: dev
dev:
	mix phx.server

.PHONY: up
up:
	docker compose up -d

.PHONY: down
down:
	docker compose stop
