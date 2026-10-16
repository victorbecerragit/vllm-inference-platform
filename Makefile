.PHONY: docker-check docker-test docker-build preflight up up-no-preflight down logs kind-create kind-deploy kind-up kind-delete kind-deploy-full

KIND_CLUSTER_NAME ?= vllm-inference-platform
KIND_CONFIG ?= k8s/kind-config.yaml
KIND_KONG_PROXY_PORT ?= 18000
KIND_KONG_ADMIN_PORT ?= 18001

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

kind-create:
	@tmp_config=$$(mktemp); \
	trap 'rm -f "$$tmp_config"' EXIT; \
	sed \
		-e 's/$${KIND_KONG_PROXY_PORT}/$(KIND_KONG_PROXY_PORT)/g' \
		-e 's/$${KIND_KONG_ADMIN_PORT}/$(KIND_KONG_ADMIN_PORT)/g' \
		$(KIND_CONFIG) > "$$tmp_config"; \
	kind create cluster --name $(KIND_CLUSTER_NAME) --config "$$tmp_config"

kind-deploy:
	kubectl kustomize k8s | awk 'BEGIN { RS="---\n"; ORS="---\n" } $$0 !~ /kind: ScaledObject/ { print }' | kubectl apply -f -

kind-deploy-full:
	kubectl apply -k k8s/

kind-up: kind-create kind-deploy

kind-delete:
	kind delete cluster --name $(KIND_CLUSTER_NAME)
