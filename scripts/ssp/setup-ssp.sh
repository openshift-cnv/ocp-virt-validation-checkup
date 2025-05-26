#!/bin/bash

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

source "${SCRIPT_DIR}/../funcs.sh"
tests::hco::disable

