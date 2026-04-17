#!/usr/bin/env bash
# refresh.sh — Reset upgrade state directory with latest files from both terraform modules
#
# Pulls fresh state and tfvars from:
#   terraform/autoscale_template/     → autoscale_template.tfstate / autoscale_template.tfvars
#   terraform/existing_vpc_resources/ → existing_vpc_resources.tfstate / existing_vpc_resources.tfvars

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

echo "Refreshing upgrade_fortios/state/"
echo ""

# ── Remove stale files ─────────────────────────────────────────────────────────

for f in blue_inventory.json autoscale_template.tfstate autoscale_template.tfvars \
          existing_vpc_resources.tfstate existing_vpc_resources.tfvars; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
        echo "  Removing ${f}"
        rm "${SCRIPT_DIR}/${f}"
    fi
done

# ── Pull from autoscale_template ───────────────────────────────────────────────

echo ""
echo "  autoscale_template:"
SRC="${REPO_ROOT}/terraform/autoscale_template"
for f in tfstate tfvars; do
    if [[ -f "${SRC}/terraform.${f}" ]]; then
        echo "    Copying terraform.${f} → autoscale_template.${f}"
        cp "${SRC}/terraform.${f}" "${SCRIPT_DIR}/autoscale_template.${f}"
    else
        echo "    WARNING: ${SRC}/terraform.${f} not found — skipping"
    fi
done

# ── Pull from existing_vpc_resources ──────────────────────────────────────────

echo ""
echo "  existing_vpc_resources:"
SRC="${REPO_ROOT}/terraform/existing_vpc_resources"
for f in tfstate tfvars; do
    if [[ -f "${SRC}/terraform.${f}" ]]; then
        echo "    Copying terraform.${f} → existing_vpc_resources.${f}"
        cp "${SRC}/terraform.${f}" "${SCRIPT_DIR}/existing_vpc_resources.${f}"
    else
        echo "    WARNING: ${SRC}/terraform.${f} not found — skipping"
    fi
done

echo ""
echo "Done. Run discovery next:"
echo "  python3 scripts/discover.py \\"
echo "    --state state/autoscale_template.tfstate \\"
echo "    --vpc-state state/existing_vpc_resources.tfstate \\"
echo "    --target-version <version> \\"
echo "    --output state/blue_inventory.json"
