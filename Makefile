.PHONY: docker-check docker-test docker-build preflight up up-no-preflight down logs kind-create kind-deploy kind-up kind-delete kind-deploy-full autoscaling-deploy

KIND_CLUSTER_NAME ?= vllm-inference-platform
KIND_CONFIG ?= k8s/kind-config.yaml
KIND_KONG_PROXY_PORT ?= 18000
KIND_KONG_ADMIN_PORT ?= 18001
KIND_GRADIO_PORT ?= 18080
TF_TFVARS_FILE ?= terraform/terraform.tfvars
INCLUSTER_TFVARS_FILE ?= terraform/incluster/terraform.tfvars
ALLOW_SCALEDOBJECT_OVERLAY ?= 0

define guard_scaledobject_overlay
	@if [ "$(ALLOW_SCALEDOBJECT_OVERLAY)" = "1" ]; then \
		echo "ALLOW_SCALEDOBJECT_OVERLAY=1 set: applying autoscaling overlay intentionally."; \
	elif { [ -f "$(INCLUSTER_TFVARS_FILE)" ] && grep -Eiq '^[[:space:]]*install_scaledobject[[:space:]]*=[[:space:]]*true[[:space:]]*$$' "$(INCLUSTER_TFVARS_FILE)"; } || \
	     { [ -f "$(TF_TFVARS_FILE)" ] && grep -Eiq '^[[:space:]]*install_scaledobject[[:space:]]*=[[:space:]]*true[[:space:]]*$$' "$(TF_TFVARS_FILE)"; }; then \
		echo "Refusing to apply autoscaling overlay: Terraform appears to manage ScaledObject (install_scaledobject=true in $(INCLUSTER_TFVARS_FILE) or $(TF_TFVARS_FILE))."; \
		echo "Use kubectl apply -k k8s/ for app-only deploys, or set ALLOW_SCALEDOBJECT_OVERLAY=1 to override intentionally."; \
		exit 1; \
	else \
		echo "Applying autoscaling overlay (no Terraform ScaledObject ownership detected in tfvars)."; \
	fi
endef

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
		-e 's/$${KIND_GRADIO_PORT}/$(KIND_GRADIO_PORT)/g' \
		$(KIND_CONFIG) > "$$tmp_config"; \
	kind create cluster --name $(KIND_CLUSTER_NAME) --config "$$tmp_config"

kind-deploy:
	kubectl apply -k k8s/

kind-deploy-full:
	$(guard_scaledobject_overlay)
	kubectl apply -k k8s/overlays/autoscaling

autoscaling-deploy:
	$(guard_scaledobject_overlay)
	kubectl apply -k k8s/overlays/autoscaling

kind-up: kind-create kind-deploy

kind-delete:
	kind delete cluster --name $(KIND_CLUSTER_NAME)
