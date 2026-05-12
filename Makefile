.PHONY: build test test-dev test-matrix shell clean

IMAGE_NAME := supply-chain-test
NODE_VERSION ?= 22

build:
	docker build -t $(IMAGE_NAME) --build-arg NODE_VERSION=$(NODE_VERSION) -f tests/Dockerfile .

test: build
	docker run --rm $(IMAGE_NAME)

test-matrix:
	@for node in 20 22; do \
		echo "\n=== Testing with Node $$node ===" ; \
		docker build -t $(IMAGE_NAME)-node$$node --build-arg NODE_VERSION=$$node -f tests/Dockerfile . && \
		docker run --rm $(IMAGE_NAME)-node$$node || exit 1 ; \
	done
	@echo "\n=== All matrix tests passed ==="

test-dev:
	cd tests && docker compose run --rm test

shell: build
	docker run --rm -it $(IMAGE_NAME) bash

clean:
	docker rmi $(IMAGE_NAME) $(IMAGE_NAME)-node20 $(IMAGE_NAME)-node22 2>/dev/null || true
	cd tests && docker compose down --rmi local 2>/dev/null || true
