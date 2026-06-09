#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"

TARGET_SHA="${1:-$(git -C "$REPO_DIR" rev-parse HEAD)}"

README_FILE="$PROJECT_DIR/README.md"
TEMPLATE_FILE="$PROJECT_DIR/deploy/azuredeploy.json"

python3 - "$README_FILE" "$TEMPLATE_FILE" "$TARGET_SHA" <<'PY'
import re
import sys
from pathlib import Path

readme_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
sha = sys.argv[3]

readme = readme_path.read_text(encoding="utf-8")
template = template_path.read_text(encoding="utf-8")

readme_updated = re.sub(
    r"https%3A%2F%2Fraw\.githubusercontent\.com%2Ftvanroo%2Fpublic-anf-toolbox%2F[^%]+%2FANF%2520QoS%2520Self%2520Leveling%2Fdeploy%2Fazuredeploy\.json",
    f"https%3A%2F%2Fraw.githubusercontent.com%2Ftvanroo%2Fpublic-anf-toolbox%2F{sha}%2FANF%2520QoS%2520Self%2520Leveling%2Fdeploy%2Fazuredeploy.json",
    readme,
)

template_updated = re.sub(
    r"https://raw\.githubusercontent\.com/tvanroo/public-anf-toolbox/[^/]+/ANF%20QoS%20Self%20Leveling/ANF-QoS-Autoscale-SelfLeveling-FSL\.ps1",
    f"https://raw.githubusercontent.com/tvanroo/public-anf-toolbox/{sha}/ANF%20QoS%20Self%20Leveling/ANF-QoS-Autoscale-SelfLeveling-FSL.ps1",
    template,
)

readme_path.write_text(readme_updated, encoding="utf-8")
template_path.write_text(template_updated, encoding="utf-8")
PY

echo "Updated deploy URLs to commit: $TARGET_SHA"
