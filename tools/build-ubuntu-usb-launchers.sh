#!/usr/bin/env bash
# Build native, statically linked Linux launchers using only the Go standard library.
set -euo pipefail
car_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$car_repo"
export GOENV=off GOPROXY=off GO111MODULE=off CGO_ENABLED=0
export GOCACHE="${GOCACHE:-${TMPDIR:-/tmp}/car-specs-go-cache}"
GOOS=linux GOARCH=amd64 GOAMD64=v1 go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o 'Ubuntu Specs.exe' ./tools/ubuntu-usb-launcher
GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o 'Ubuntu Specs ARM64.exe' ./tools/ubuntu-usb-launcher
chmod +x 'Ubuntu Specs.exe' 'Ubuntu Specs ARM64.exe'
