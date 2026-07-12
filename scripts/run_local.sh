#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export GOCACHE="$PWD/.gocache"

go test ./...
go run ./cmd/sim -hero "As Ah" -board "" -opponents 1 -n 100000 -seed 42
go run ./cmd/sim -hero "As Ks" -board "Qs Js 2d" -opponents 1 -n 100000 -seed 42
