GOOSE ?= .toolchain/goose/build/goose
BENCH_ITERATIONS ?= 1000
RELEASE_CC ?= gcc
SANITIZER_OPT ?= -O2
export SANITIZER_OPT
TESTS = config behavior toml overloads index ownership schema lists toml-lists json-layer bindings reload durations aliases typed-settings generated-bindings
TEST_BIN_DIR = .build/test-bin
SOURCES = config.goose toml.goose vendor.goose json_layer.goose bindings.goose reload.goose typed.goose

.PHONY: setup format check test integration property security sanitize sanitizer-config release conformance bench worker generated generated-check typed-limit
setup:
	./scripts/setup-goose.sh
format:
	$(GOOSE) format $(SOURCES) examples tests bench
generated:
	python3 tools/generate_settings.py schemas/worker.json --output bench/worker_settings.goose --goose $(GOOSE)
	python3 tools/generate_settings.py schemas/bindings-test.json --output tests/generated_bindings.goose --goose $(GOOSE)
	python3 tools/generate_settings.py schemas/worker.json --output examples/worker_settings.goose --goose $(GOOSE)
	python3 tools/generate_settings.py schemas/typed-test.json --output tests/typed_fixture.goose --goose $(GOOSE)
	python3 tools/generate_settings.py schemas/typed-test.json --output bench/typed_fixture.goose --goose $(GOOSE)
generated-check:
	python3 tools/generate_settings.py schemas/worker.json --output bench/worker_settings.goose --goose $(GOOSE) --check
	python3 tools/generate_settings.py schemas/bindings-test.json --output tests/generated_bindings.goose --goose $(GOOSE) --check
	python3 tools/generate_settings.py schemas/worker.json --output examples/worker_settings.goose --goose $(GOOSE) --check
	python3 tools/generate_settings.py schemas/typed-test.json --output tests/typed_fixture.goose --goose $(GOOSE) --check
	python3 tools/generate_settings.py schemas/typed-test.json --output bench/typed_fixture.goose --goose $(GOOSE) --check
check: generated-check
	$(GOOSE) format --check $(SOURCES) examples tests bench
	@set -e; for name in $(TESTS) property nested common-model security toml-decoder duration-model; do $(GOOSE) check tests/$$name.goose; done
	$(GOOSE) check examples/durations.goose
	$(GOOSE) check examples/settings.goose
	$(GOOSE) check examples/layered.goose
	$(GOOSE) check bench/bench.goose
	$(GOOSE) check bench/common.goose
	$(GOOSE) check bench/bindings.goose
	$(GOOSE) check bench/updates.goose
	$(GOOSE) check bench/memory.goose
	$(GOOSE) check bench/durations.goose
	$(GOOSE) check bench/aliases.goose
	$(GOOSE) check bench/typed_settings.goose
	$(GOOSE) check bench/generated_bindings.goose
test: integration
	python3 tests/generate_settings.py
	python3 -O tests/generate_settings.py
	python3 tests/typed-ownership.py $(GOOSE)
	python3 tests/typed-codegen.py $(GOOSE)
	python3 tests/typed-consumer.py $(GOOSE)
	python3 tests/benchmark_generated_bindings.py
	python3 -O tests/benchmark_generated_bindings.py
	python3 tests/benchmark_typed.py
	python3 -O tests/benchmark_typed.py
	python3 tests/benchmark_aliases.py
	python3 tests/benchmark_duration.py
	python3 tests/benchmark_measure.py
	python3 tests/benchmark_memory.py
	python3 tests/benchmark_fallback.py
	python3 tests/benchmark_startup.py
	python3 tests/provenance.py
	python3 tests/worker_harness.py
	mkdir -p $(TEST_BIN_DIR)
	@set -e; for name in $(TESTS); do \
		$(GOOSE) run tests/$$name.goose; \
		$(GOOSE) build tests/$$name.goose -o $(TEST_BIN_DIR)/$$name; ./$(TEST_BIN_DIR)/$$name; \
		$(GOOSE) build tests/$$name.goose --debug --no-bce -o $(TEST_BIN_DIR)/$$name-debug; ./$(TEST_BIN_DIR)/$$name-debug; \
	done
	python3 tests/bindings.py $(TEST_BIN_DIR)/bindings $(TEST_BIN_DIR)/bindings-debug $(TEST_BIN_DIR)/reload $(TEST_BIN_DIR)/reload-debug $(TEST_BIN_DIR)/durations $(TEST_BIN_DIR)/durations-debug $(TEST_BIN_DIR)/aliases $(TEST_BIN_DIR)/aliases-debug
	$(GOOSE) run examples/durations.goose
	$(GOOSE) run examples/settings.goose
	python3 tests/examples.py $(GOOSE)
	python3 tests/ownership.py $(GOOSE)
integration:
	python3 tests/integration.py $(GOOSE)
property:
	mkdir -p .build
	$(GOOSE) build tests/duration-model.goose --cc gcc -O2 -o .build/duration-model
	$(GOOSE) build tests/duration-model.goose --debug --no-bce -o .build/duration-model-debug
	python3 tests/duration-model.py .build/duration-model .build/duration-model-debug
	$(GOOSE) build tests/property.goose -o .build/property
	$(GOOSE) build tests/property.goose --debug --no-bce -o .build/property-debug
	python3 tests/property.py .build/property .build/property-debug
	$(GOOSE) build tests/nested.goose -o .build/nested
	$(GOOSE) build tests/nested.goose --debug --no-bce -o .build/nested-debug
	python3 tests/nested.py .build/nested .build/nested-debug
	$(GOOSE) build tests/common-model.goose --cc gcc -O2 -o .build/common-model-driver
	$(GOOSE) build tests/common-model.goose --debug --no-bce -o .build/common-model-driver-debug
	python3 tests/common-model.py .build/common-model-driver .build/common-model-driver-debug
security:
	mkdir -p .build
	$(GOOSE) build tests/security.goose -o .build/security
	$(GOOSE) build tests/security.goose --debug --no-bce -o .build/security-debug
	python3 tests/security.py .build/security .build/security-debug
sanitizer-config:
	python3 tests/sanitizer-config.py
sanitize: sanitizer-config
	mkdir -p .build
	$(GOOSE) build tests/duration-model.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/duration-model-sanitized
	python3 tests/duration-model.py .build/duration-model-sanitized
	@set -e; for name in $(TESTS); do \
		$(GOOSE) build tests/$$name.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/$$name-sanitized; \
		./.build/$$name-sanitized; \
	done
	python3 tests/bindings.py .build/bindings-sanitized .build/reload-sanitized .build/durations-sanitized .build/aliases-sanitized
	$(GOOSE) build tests/property.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/property-sanitized
	python3 tests/property.py .build/property-sanitized
	$(GOOSE) build tests/security.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/security-sanitized
	python3 tests/security.py .build/security-sanitized
	$(GOOSE) build tests/nested.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/nested-sanitized
	python3 tests/nested.py .build/nested-sanitized
	$(GOOSE) build tests/common-model.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/common-model-sanitized
	python3 tests/common-model.py .build/common-model-sanitized
release:
	mkdir -p .build/release
	$(GOOSE) build tests/duration-model.goose --cc $(RELEASE_CC) -O2 -o .build/release/duration-model
	python3 tests/duration-model.py .build/release/duration-model
	@set -e; for name in $(TESTS); do \
		$(GOOSE) build tests/$$name.goose --cc $(RELEASE_CC) -O2 -o .build/release/$$name; \
		./.build/release/$$name; \
	done
	python3 tests/bindings.py .build/release/bindings .build/release/reload .build/release/durations .build/release/aliases
	$(GOOSE) build tests/property.goose --cc $(RELEASE_CC) -O2 -o .build/release/property
	python3 tests/property.py .build/release/property
	$(GOOSE) build tests/security.goose --cc $(RELEASE_CC) -O2 -o .build/release/security
	python3 tests/security.py .build/release/security
	$(GOOSE) build tests/nested.goose --cc $(RELEASE_CC) -O2 -o .build/release/nested
	python3 tests/nested.py .build/release/nested
	$(GOOSE) build tests/common-model.goose --cc $(RELEASE_CC) -O2 -o .build/release/common-model
	python3 tests/common-model.py .build/release/common-model
conformance:
	mkdir -p .build
	$(GOOSE) build tests/toml-decoder.goose --cc gcc -O2 -o .build/toml-decoder
	./scripts/setup-toml-test.sh test -decoder=./.build/toml-decoder -toml=1.0 -color=never
bench:
	mkdir -p .build
	$(GOOSE) build bench/bench.goose --cc gcc -O2 -o .build/bench
	./.build/bench $(BENCH_ITERATIONS)

# Optional Linux application; fetches its own pinned goose-fs dependency.
worker:
	python3 tests/worker.py $(GOOSE) --cc gcc
	python3 tests/worker.py $(GOOSE) --cc clang
	python3 tests/worker.py $(GOOSE) --cc gcc --sanitize
	python3 tests/worker.py $(GOOSE) --cc clang --sanitize

typed-limit:
	python3 tests/typed-limit.py $(GOOSE) --cc gcc --bindings
	python3 tests/typed-limit.py $(GOOSE) --cc clang --bindings
