export CI_PIPELINE_ID ?= $(shell date +"%Y-%m-%d-%s")
export SERVER_DOCKER_IMAGE ?=matterlabs/server:$(IMAGE_TAG)
export PROVER_DOCKER_IMAGE ?=matterlabs/prover:$(IMAGE_TAG)
export NGINX_DOCKER_IMAGE ?= matterlabs/nginx:$(IMAGE_TAG)
export GETH_DOCKER_IMAGE ?= matterlabs/geth:latest
export CI_DOCKER_IMAGE ?= matterlabs/ci

# Getting started

# Check and change environment (listed here for autocomplete and documentation only)
env:	

# Get everything up and running for the first time
init:
	@bin/init

yarn:
	@cd js/client && yarn
	@cd js/explorer && yarn
	@cd contracts && yarn
	@cd js/tests && yarn


# Helpers

# This will prompt user to confirm an action on production environment
confirm_action:
	@bin/.confirm_action


# Database tools

sql = psql "$(DATABASE_URL)" -c 

db-test:
	@bin/db-test.sh reset

db-test-no-reset:
	@bin/db-test.sh no-reset

db-setup:
	@bin/db-setup

db-insert-contract:
	@bin/db-insert-contract.sh

db-reset: confirm_action db-wait db-drop db-setup db-insert-contract
	@echo database is ready

db-migrate: confirm_action
	@cd core/storage && diesel migration run

db-drop: confirm_action
	@# this is used to clear the produciton db; cannot do `diesel database reset` because we don't own the db
	@echo DATABASE_URL=$(DATABASE_URL)
	@$(sql) 'DROP OWNED BY CURRENT_USER CASCADE' || \
		{ $(sql) 'DROP SCHEMA IF EXISTS public CASCADE' && $(sql)'CREATE SCHEMA public'; }

db-wait:
	@bin/db-wait

genesis: confirm_action
	@bin/genesis.sh

# Frontend clients

client:
	@cd js/client && yarn serve

explorer:
	@cd js/explorer && yarn serve

dist-client:
	@cd js/client && yarn build

dist-explorer:
	@cd js/explorer && yarn build

image-nginx: dist-client dist-explorer
	@docker build -t "${NGINX_DOCKER_IMAGE}" -f ./docker/nginx/Dockerfile .

push-image-nginx: image-nginx
	docker push "${NGINX_DOCKER_IMAGE}"

image-ci:
	@docker build -t "${CI_DOCKER_IMAGE}" -f ./docker/ci/Dockerfile .

push-image-ci:
	docker push "${CI_DOCKER_IMAGE}"

# Using RUST+Linux docker image (ekidd/rust-musl-builder) to build for Linux. More at https://github.com/emk/rust-musl-builder
docker-options = --rm -v $(shell pwd):/home/rust/src -v cargo-git:/home/rust/.cargo/git -v cargo-registry:/home/rust/.cargo/registry --env-file $(ZKSYNC_HOME)/etc/env/$(ZKSYNC_ENV).env
rust-musl-builder = @docker run $(docker-options) ekidd/rust-musl-builder


# Rust: main stuff


dummy-prover:
	cargo run --bin dummy_prover

prover:
	@cargo run --release --bin prover

server:
	@cargo run --bin server --release

sandbox:
	@cargo run --bin sandbox

# See more more at https://github.com/emk/rust-musl-builder#caching-builds
build-target:
	$(rust-musl-builder) sudo chown -R rust:rust /home/rust/.cargo/git /home/rust/.cargo/registry
	$(rust-musl-builder) cargo build --release

clean-target:
	$(rust-musl-builder) cargo clean

image-server: build-target
	@docker build -t "${SERVER_DOCKER_IMAGE}" -f ./docker/server/Dockerfile .

image-prover: build-target
	@docker build -t "${PROVER_DOCKER_IMAGE}" -f ./docker/prover/Dockerfile .

image-rust: image-server image-prover

push-image-rust: image-rust
	docker push "${SERVER_DOCKER_IMAGE}"
	docker push "${PROVER_DOCKER_IMAGE}"

# Contracts

deploy-contracts: confirm_action build-contracts
	@bin/deploy-contracts.sh

test-contracts: confirm_action build-contracts
	@bin/contracts-test.sh

build-contracts: confirm_action flatten
	@bin/prepare-test-contracts.sh
	@cd contracts && yarn build

define flatten_file
	@cd contracts && scripts/solidityFlattener.pl --mainsol $(1) --outputsol flat/$(1);
endef

# Flatten contract source
flatten: prepare-contracts
	@mkdir -p contracts/flat
	$(call flatten_file,Franklin.sol)
	$(call flatten_file,Governance.sol)
	$(call flatten_file,PriorityQueue.sol)
	$(call flatten_file,Verifier.sol)

gen-keys-if-not-present:
	test -f keys/${BLOCK_SIZE_CHUNKS}/${ACCOUNT_TREE_DEPTH}/zksync_pk.key || gen-keys

prepare-contracts:
	@cp keys/${BLOCK_SIZE_CHUNKS}/${ACCOUNT_TREE_DEPTH}/VerificationKey.sol contracts/contracts/VerificationKey.sol || (echo "please run gen-keys" && exit 1)

# testing

loadtest: confirm_action
	@bin/loadtest.sh

integration-testkit: build-contracts
	cargo run --bin testkit --release

integration-simple:
	@cd js/tests && yarn && yarn simple

integration-full-exit:
	@cd js/tests && yarn && yarn full-exit

price:
	@node contracts/scripts/check-price.js

circuit-tests:
	cargo test --no-fail-fast --release -p circuit -- --ignored --test-threads=1

prover-tests:
	f cargo test -p prover --release -- --ignored

# Loadtest

run-loadtest: confirm_action
	@cd js/franklin_lib && yarn loadtest

prepare-loadtest: confirm_action
	@node js/loadtest/loadtest.js prepare

rescue: confirm_action
	@node js/loadtest/rescue.js

deposit: confirm_action
	@node contracts/scripts/deposit.js

# Devops: main

# (Re)deploy contracts and database
redeploy: confirm_action stop deploy-contracts db-insert-contract

init-deploy: confirm_action deploy-contracts db-insert-contract

dockerhub-push: image-nginx image-rust
	docker push "${NGINX_DOCKER_IMAGE}"

apply-kubeconfig:
	@bin/k8s-apply

update-rust: push-image-rust apply-kubeconfig
	@kubectl patch deployment $(ZKSYNC_ENV)-server -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"date\":\"$(shell date +%s)\"}}}}}"
	@kubectl patch deployment $(ZKSYNC_ENV)-prover -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"date\":\"$(shell date +%s)\"}}}}}"

update-nginx: push-image-nginx apply-kubeconfig
	@kubectl patch deployment $(ZKSYNC_ENV)-nginx -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"date\":\"$(shell date +%s)\"}}}}}"

update-all: update-rust update-nginx apply-kubeconfig

start-kube: apply-kubeconfig

ifeq (dev,$(ZKSYNC_ENV))
start: image-nginx image-rust start-local
else
start: apply-kubeconfig start-prover start-server start-nginx
endif

ifeq (dev,$(ZKSYNC_ENV))
stop:
else ifeq (ci,$(ZKSYNC_ENV))
stop:
else
stop: confirm_action stop-prover stop-server stop-nginx
endif

restart: stop start

start-prover:
	@bin/kube scale deployments/$(ZKSYNC_ENV)-prover --replicas=1

start-nginx:
	@bin/kube scale deployments/$(ZKSYNC_ENV)-nginx --replicas=1

start-server:
	@bin/kube scale deployments/$(ZKSYNC_ENV)-server --replicas=1

stop-prover:
	@bin/kube scale deployments/$(ZKSYNC_ENV)-prover --replicas=0

stop-server:
	@bin/kube scale deployments/$(ZKSYNC_ENV)-server --replicas=0

stop-nginx:
	@bin/kube scale deployments/$(ZKSYNC_ENV)-nginx --replicas=0

# Monitoring

status:
	@curl $(API_SERVER)/api/v0.1/status; echo

log-server:
	kubectl logs -f deployments/$(ZKSYNC_ENV)-server

log-prover:
	kubectl logs --tail 300 -f deployments/$(ZKSYNC_ENV)-prover

# Kubernetes: monitoring shortcuts

pods:
	kubectl get pods -o wide | grep -v Pending

nodes:
	kubectl get nodes -o wide


# Dev environment

dev-up:
	@docker-compose up -d postgres geth
	@docker-compose up -d tesseracts


dev-down:
	@docker-compose stop tesseracts
	@docker-compose stop postgres geth

geth-up: geth
	@docker-compose up geth


# Auxillary docker containers for dev environment (usually no need to build, just use images from dockerhub)

dev-build-geth:
	@docker build -t "${GETH_DOCKER_IMAGE}" ./docker/geth

dev-push-geth:
	@docker push "${GETH_DOCKER_IMAGE}"

# Key generator 

make-keys:
	@cargo run -p key_generator --release --bin key_generator

 # Data Restore

data-restore-setup-and-run: data-restore-build data-restore-restart

data-restore-db-prepare: confirm_action db-reset

data-restore-build:
	@cargo build -p data_restore --release --bin data_restore

data-restore-restart: confirm_action data-restore-db-prepare
	@cargo run --bin data_restore --release -- --genesis

data-restore-continue:
	@cargo run --bin data_restore --release -- --continue
