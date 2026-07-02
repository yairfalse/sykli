#!/usr/bin/env sh
set -eu

cd core
mix run ../scripts/check-guardrails-gate.exs
