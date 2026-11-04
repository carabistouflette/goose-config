GOOSE ?= .toolchain/goose/build/goose
BENCH_ITERATIONS ?= 1000
RELEASE_CC ?= gcc
TESTS = config behavior toml overloads index ownership schema

.PHONY: setup format check test property security sanitize release bench
setup:
	./scripts/setup-goose.sh
format:
	$(GOOSE) format config.goose toml.goose vendor.goose examples tests bench
check:
	$(GOOSE) format --check config.goose toml.goose vendor.goose examples tests bench
	@set -e; for name in $(TESTS) property nested security; do $(GOOSE) check tests/$$name.goose; done
	$(GOOSE) check examples/settings.goose
	$(GOOSE) check bench/bench.goose
test:
	mkdir -p .build
	@set -e; for name in $(TESTS); do \
		$(GOOSE) run tests/$$name.goose; \
		$(GOOSE) build tests/$$name.goose -o .build/$$name; ./.build/$$name; \
		$(GOOSE) build tests/$$name.goose --debug --no-bce -o .build/$$name-debug; ./.build/$$name-debug; \
	done
	$(GOOSE) run examples/settings.goose
	python3 tests/ownership.py $(GOOSE)
property:
	mkdir -p .build
	$(GOOSE) build tests/property.goose -o .build/property
	$(GOOSE) build tests/property.goose --debug --no-bce -o .build/property-debug
	python3 tests/property.py .build/property .build/property-debug
	$(GOOSE) build tests/nested.goose -o .build/nested
	$(GOOSE) build tests/nested.goose --debug --no-bce -o .build/nested-debug
	python3 tests/nested.py .build/nested .build/nested-debug
security:
	mkdir -p .build
	$(GOOSE) build tests/security.goose -o .build/security
	$(GOOSE) build tests/security.goose --debug --no-bce -o .build/security-debug
	python3 tests/security.py .build/security .build/security-debug
sanitize:
	mkdir -p .build
	@set -e; for name in $(TESTS); do \
		$(GOOSE) build tests/$$name.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/$$name-sanitized; \
		./.build/$$name-sanitized; \
	done
	$(GOOSE) build tests/property.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/property-sanitized
	python3 tests/property.py .build/property-sanitized
	$(GOOSE) build tests/security.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/security-sanitized
	python3 tests/security.py .build/security-sanitized
	$(GOOSE) build tests/nested.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/nested-sanitized
	python3 tests/nested.py .build/nested-sanitized
release:
	mkdir -p .build/release
	@set -e; for name in $(TESTS); do \
		$(GOOSE) build tests/$$name.goose --cc $(RELEASE_CC) -O2 -o .build/release/$$name; \
		./.build/release/$$name; \
	done
	$(GOOSE) build tests/property.goose --cc $(RELEASE_CC) -O2 -o .build/release/property
	python3 tests/property.py .build/release/property
	$(GOOSE) build tests/security.goose --cc $(RELEASE_CC) -O2 -o .build/release/security
	python3 tests/security.py .build/release/security
	$(GOOSE) build tests/nested.goose --cc $(RELEASE_CC) -O2 -o .build/release/nested
	python3 tests/nested.py .build/release/nested
bench:
	mkdir -p .build
	$(GOOSE) build bench/bench.goose --cc gcc -O2 -o .build/bench
	./.build/bench $(BENCH_ITERATIONS)
