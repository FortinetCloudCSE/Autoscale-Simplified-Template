#!/usr/bin/env bash
# Teardown: destroy autoscale_template then existing_vpc_resources (reverse order)
# Run after deploy.sh completes. Re-authenticate with AWS SSO first if needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVR_DIR="${SCRIPT_DIR}/existing_vpc_resources"
ASG_DIR="${SCRIPT_DIR}/autoscale_template"
STATE_FILE="${SCRIPT_DIR}/.deploy_state.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Load report/log paths from deploy run (fallback to new files if state missing)
if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    echo -e "${BLUE}Using report from deploy run: ${REPORT_FILE}${NC}"
else
    TS=$(date +%Y%m%d_%H%M%S)
    REPORT_FILE="${SCRIPT_DIR}/deploy_report_${TS}.txt"
    LOG_FILE="${SCRIPT_DIR}/deploy_log_${TS}.txt"
    echo -e "${YELLOW}No deploy state found — creating new report/log files${NC}"
fi

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${NC}" | tee -a "$LOG_FILE"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${NC}" | tee -a "$LOG_FILE"; exit 1; }

run_tf() {
    local label="$1"; shift
    log "$label: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || die "$label failed (exit $rc)"
}

# Verify credentials before starting
log "Verifying AWS credentials…"
aws sts get-caller-identity > /dev/null 2>&1 || die "AWS credentials invalid — run: aws sso login"
ok "Credentials valid"

# ─── TEARDOWN: autoscale_template ────────────────────────────────────────────
log "━━━ TEARDOWN: autoscale_template ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cd "$ASG_DIR"
run_tf "ASG destroy" terraform destroy -auto-approve
ok "autoscale_template destroyed"

# ─── TEARDOWN: existing_vpc_resources ────────────────────────────────────────
log "━━━ TEARDOWN: existing_vpc_resources ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cd "$EVR_DIR"
run_tf "EVR destroy" terraform destroy -auto-approve
ok "existing_vpc_resources destroyed"

# ─── FINAL SUMMARY ───────────────────────────────────────────────────────────
cat >> "$REPORT_FILE" <<SUMMARY

================================================================================
  TEARDOWN COMPLETE  —  $(date)
================================================================================
SUMMARY

# ─── FILE CLEANUP ────────────────────────────────────────────────────────────
log "━━━ CLEANING UP FILES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Terraform plan files
rm -f "${EVR_DIR}/tfplan_evr"
rm -f "${ASG_DIR}/tfplan_asg"
ok "Terraform plan files removed"

# tfvars backup created by sed when writing fortimanager_ip
rm -f "${ASG_DIR}/terraform.tfvars.bak"
ok "terraform.tfvars.bak removed"

# Verification data cache
rm -f "${EVR_DIR}/verify_scripts/terraform_verification_data.sh"
ok "Verification data cache removed"

# Network diagram files
rm -f "${SCRIPT_DIR}/logs/network_diagram.svg"
rm -f "${SCRIPT_DIR}/logs/network_diagram.md"
rmdir "${SCRIPT_DIR}/logs" 2>/dev/null || true
ok "Network diagram files removed"

# Deploy report and log (keep until last so we can write to them above)
rm -f "$STATE_FILE"
rm -f "$REPORT_FILE"
rm -f "$LOG_FILE"
ok "Deploy report and log removed"

# Clean up any leftover deploy reports/logs from prior runs
rm -f "${SCRIPT_DIR}"/deploy_report_*.txt
rm -f "${SCRIPT_DIR}"/deploy_log_*.txt
ok "Prior deploy reports and logs removed"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  All done. Infrastructure destroyed and files cleaned up.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
