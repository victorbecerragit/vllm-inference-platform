.PHONY: docker-check docker-test docker-build preflight up up-no-preflight down logs

docker-check:
	./scripts/docker-preflight.sh check

docker-test:
	./scripts/docker-preflight.sh test

docker-build:
	./scripts/docker-preflight.sh build

preflight:
	./scripts/docker-preflight.sh all

up: preflight
	docker compose up -d

up-no-preflight:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f
