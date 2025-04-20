#!/bin/bash

#
# Restore environment after running SSP-Operator tier1 tests.
#

set -ex

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/../funcs.sh"

# Re-enable HCO operator
tests::hco::enable

# Wait until DataImportCrons import images
#tests::hco::wait_for_data_import_crons
