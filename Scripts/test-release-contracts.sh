#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

CODEX_GAUGE_HEADLESS_RELEASE_CONTRACTS=1 \
    /bin/bash Tests/ReleasePackagingTests/test_release_packaging.sh
/bin/bash Tests/ReleaseAppcastTests/test_release_appcast.sh
/bin/bash Tests/ReleaseWorkflowTests/test_release_workflow.sh

echo "PASS headless release contracts"
