BINARY     := heartbeat-api
BUILD_DIR  := dist
GOOS       := linux
GOARCH     := arm64
CGO_ENABLED := 0

.PHONY: build test clean

build:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) \
		go build -ldflags="-s -w" -o $(BUILD_DIR)/$(BINARY) ./...
	@echo "Built: $(BUILD_DIR)/$(BINARY) ($(GOARCH))"

test:
	go test ./... -v

clean:
	rm -rf $(BUILD_DIR)
