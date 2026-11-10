#!/bin/sh
# Developer helper: pack the source tree (no build products) into a tarball.
set -e
cd "$(dirname "$0")/.."
tar --exclude=.build --exclude=build --exclude=dist --exclude=node_modules --exclude=.git -czf "${1:-/tmp/samesofa-src.tgz}" .
