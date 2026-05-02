.PHONY: build test test-dev shell clean

IMAGE_NAME := supply-chain-test

build:
	docker build -t $(IMAGE_NAME) -f tests/Dockerfile .

test: build
	docker run --rm $(IMAGE_NAME)

test-dev:
	cd tests && docker compose run --rm test

shell: build
	docker run --rm -it $(IMAGE_NAME) bash

clean:
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
	cd tests && docker compose down --rmi local 2>/dev/null || true
