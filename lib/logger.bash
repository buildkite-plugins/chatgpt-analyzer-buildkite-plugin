#!/bin/bash
set -euo pipefail

# Functions
log_section() {
  echo -e "\n--- $1"
}

log_info() {
  echo -e "\033[36mℹ️ \033[0m $1"
}

log_success() {
  echo -e "\033[32m✅ \033[0m $1"
}

log_warning() {
  echo -e "\033[33m⚠️ \033[0m $1"
}

log_error() {
  echo -e "\033[31m❌ ERROR:\033[0m $1" >&2
}