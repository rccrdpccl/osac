BIN      := osac-proxy
GOOS     ?= $(shell go env GOOS)
GOARCH   ?= $(shell go env GOARCH)

.PHONY: build
build:
	go build -o $(BIN) .

.PHONY: run
run: build
	FULFILLMENT_API_URL=http://localhost:9090 ./$(BIN)

.PHONY: test
test:
	go test ./...

.PHONY: lint
lint:
	golangci-lint run ./...

.PHONY: clean
clean:
	rm -f $(BIN)
