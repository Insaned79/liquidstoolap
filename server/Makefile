FPC ?= fpc
SRC_DIR := src
BUILD_DIR := build
BIN := $(BUILD_DIR)/liquidstoolap
UNIT_DIR := $(SRC_DIR)/liquidstoolap_server

UNIT_TESTS := test_config test_auth test_errors test_requestvalidation
UNIT_TEST_BINS := $(addprefix $(BUILD_DIR)/,$(UNIT_TESTS))

.PHONY: build build-ffi-probe clean run smoke test

build: build-ffi-probe
	mkdir -p $(BUILD_DIR)
	$(FPC) -Mobjfpc -Sh -Fu$(UNIT_DIR) -FE$(BUILD_DIR) -FU$(BUILD_DIR) -o$(BIN) $(SRC_DIR)/liquidstoolap_server.lpr

build-ffi-probe:
	mkdir -p $(BUILD_DIR)
	$(FPC) -Mobjfpc -Sh -Fu$(UNIT_DIR) -FE$(BUILD_DIR) -FU$(BUILD_DIR) -o$(BUILD_DIR)/ffi_probe tests/ffi_probe.pas

run: build
	$(BIN) serve --config ../config/config.example.ini

smoke: build
	bash tests/smoke.sh

$(BUILD_DIR)/test_%: tests/test_%.pas
	mkdir -p $(BUILD_DIR)
	$(FPC) -Mobjfpc -Sh -Fu$(UNIT_DIR) -FE$(BUILD_DIR) -FU$(BUILD_DIR) -o$@ $<

test: $(UNIT_TEST_BINS)
	@for test_bin in $(UNIT_TEST_BINS); do $$test_bin; done

clean:
	rm -rf $(BUILD_DIR)
