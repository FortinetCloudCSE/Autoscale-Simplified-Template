#!/usr/bin/env bash
# Phase 1+2 deploy: existing_vpc_resources → autoscale_template → report
# Run teardown.sh afterward (re-auth if needed first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVR_DIR="${SCRIPT_DIR}/existing_vpc_resources"
ASG_DIR="${SCRIPT_DIR}/autoscale_template"
TS=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${SCRIPT_DIR}/deploy_report_${TS}.txt"
LOG_FILE="${SCRIPT_DIR}/deploy_log_${TS}.txt"
STATE_FILE="${SCRIPT_DIR}/.deploy_state.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${NC}" | tee -a "$LOG_FILE"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${NC}" | tee -a "$LOG_FILE"; exit 1; }

# Returns current epoch seconds
now() { date +%s; }

# Prints elapsed time between two epoch values as Xm Ys
elapsed() {
    local start=$1 end=$2 delta
    delta=$(( end - start ))
    printf "%dm %ds" $(( delta / 60 )) $(( delta % 60 ))
}

run_tf() {
    local label="$1"; shift
    log "$label: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || die "$label failed (exit $rc)"
}

extract_ip() {
    local key="$1" json="$2"
    echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('${key}', {}).get('value')
if isinstance(v, list): v = v[0] if v else None
print(v if v and str(v) not in ('None','null','') else '')
" 2>/dev/null
}

DEPLOY_START=$(now)

# ─── PRE-FLIGHT: purge stale EC2 instances from state ────────────────────────
PREFLIGHT_START=$(now)
log "━━━ PRE-FLIGHT: checking for stale instance state ━━━━━━━━━━━━━━━━━━━━━━"
cd "$EVR_DIR"
STALE_RESOURCES=$(terraform state list 2>/dev/null | grep "aws_instance\|aws_eip\|eip_association" || true)
if [[ -n "$STALE_RESOURCES" ]]; then
    while IFS= read -r res; do
        iid=$(terraform state show "$res" 2>/dev/null | grep '^\s*id\s*=' | head -1 | awk -F'"' '{print $2}')
        if [[ "$iid" == i-* ]]; then
            state=$(aws ec2 describe-instances --instance-ids "$iid" \
                --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "missing")
            if [[ "$state" == "terminated" || "$state" == "missing" ]]; then
                log "Removing stale state: $res ($iid is $state)"
                terraform state rm "$res" 2>/dev/null || true
            fi
        fi
    done <<< "$STALE_RESOURCES"
else
    log "No stale instance state found"
fi
PREFLIGHT_END=$(now)
ok "Pre-flight complete ($(elapsed $PREFLIGHT_START $PREFLIGHT_END))"

# ─── PHASE 1: existing_vpc_resources ─────────────────────────────────────────
log "━━━ PHASE 1: existing_vpc_resources ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
EVR_START=$(now)
cd "$EVR_DIR"

EVR_INIT_START=$(now)
run_tf "EVR init"  terraform init -upgrade
ok "EVR init complete ($(elapsed $EVR_INIT_START $(now)))"

EVR_PLAN_START=$(now)
run_tf "EVR plan"  terraform plan  -out=tfplan_evr
ok "EVR plan complete ($(elapsed $EVR_PLAN_START $(now)))"

EVR_APPLY_START=$(now)
run_tf "EVR apply" terraform apply -auto-approve tfplan_evr
EVR_APPLY_END=$(now)
ok "EVR apply complete ($(elapsed $EVR_APPLY_START $EVR_APPLY_END))"

EVR_END=$(now)
ok "existing_vpc_resources total: $(elapsed $EVR_START $EVR_END)"

log "Capturing existing_vpc_resources outputs…"
EVR_OUTPUTS=$(terraform output -json 2>>"$LOG_FILE")

_FMG_PUB=$(extract_ip fortimanager_public_ip  "$EVR_OUTPUTS")
_FMG_PRV=$(extract_ip fortimanager_private_ip  "$EVR_OUTPUTS")
FMG_IP="${_FMG_PUB:-${_FMG_PRV}}"
FMG_IP_LABEL=$( [[ -n "$_FMG_PUB" ]] && echo "public" || echo "private" )

_FAZ_PUB=$(extract_ip fortianalyzer_public_ip  "$EVR_OUTPUTS")
_FAZ_PRV=$(extract_ip fortianalyzer_private_ip  "$EVR_OUTPUTS")
FAZ_IP="${_FAZ_PUB:-${_FAZ_PRV}}"
FAZ_IP_LABEL=$( [[ -n "$_FAZ_PUB" ]] && echo "public" || echo "private" )

JUMP_PUBLIC_IP=$(extract_ip jump_box_public_ip "$EVR_OUTPUTS")
TGW_ID=$(echo "$EVR_OUTPUTS"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tgw_id',{}).get('value','N/A'))")
INSP_VPC_ID=$(echo "$EVR_OUTPUTS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('inspection_vpc_id',{}).get('value','N/A'))")
MGMT_VPC_ID=$(echo "$EVR_OUTPUTS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('vpc_id',{}).get('value','N/A'))")

ok "FortiManager ($FMG_IP_LABEL): $FMG_IP"
ok "FortiAnalyzer ($FAZ_IP_LABEL): $FAZ_IP"
ok "Jump box public IP: $JUMP_PUBLIC_IP"

# Write FortiManager IP into autoscale_template tfvars
log "Writing fortimanager_ip = \"${FMG_IP}\" (${FMG_IP_LABEL}) to autoscale_template/terraform.tfvars"
sed -i.bak "s|^fortimanager_ip *= *\"[^\"]*\"|fortimanager_ip = \"${FMG_IP}\"|" "${ASG_DIR}/terraform.tfvars"
ok "fortimanager_ip updated"

# ─── PHASE 2: autoscale_template ─────────────────────────────────────────────
log "━━━ PHASE 2: autoscale_template ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ASG_START=$(now)
cd "$ASG_DIR"

ASG_INIT_START=$(now)
run_tf "ASG init"  terraform init -upgrade
ok "ASG init complete ($(elapsed $ASG_INIT_START $(now)))"

ASG_PLAN_START=$(now)
run_tf "ASG plan"  terraform plan  -out=tfplan_asg
ok "ASG plan complete ($(elapsed $ASG_PLAN_START $(now)))"

ASG_APPLY_START=$(now)
run_tf "ASG apply" terraform apply -auto-approve tfplan_asg
ASG_APPLY_END=$(now)
ok "ASG apply complete ($(elapsed $ASG_APPLY_START $ASG_APPLY_END))"

ASG_END=$(now)
ok "autoscale_template total: $(elapsed $ASG_START $ASG_END)"

log "Capturing autoscale_template outputs…"
ASG_OUTPUTS=$(terraform output -json 2>>"$LOG_FILE")

# ─── REPORT ──────────────────────────────────────────────────────────────────
REPORT_START=$(now)
log "━━━ BUILDING REPORT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cat > "$REPORT_FILE" <<REPORT
================================================================================
  DEPLOY REPORT  —  $(date)
================================================================================

── existing_vpc_resources ──────────────────────────────────────────────────────
  Inspection VPC ID      : ${INSP_VPC_ID}
  Management VPC ID      : ${MGMT_VPC_ID}
  Transit Gateway ID     : ${TGW_ID}
  FortiManager (${FMG_IP_LABEL}) IP : ${FMG_IP}
    HTTPS : https://${FMG_IP}
  FortiAnalyzer (${FAZ_IP_LABEL}) IP: ${FAZ_IP}
    HTTPS : https://${FAZ_IP}
  Jump Box public IP     : ${JUMP_PUBLIC_IP}
    SSH   : ssh ubuntu@${JUMP_PUBLIC_IP}

── autoscale_template ──────────────────────────────────────────────────────────
$(cd "$ASG_DIR" && terraform output 2>/dev/null || echo "  (no outputs defined)")

── Network Diagram ─────────────────────────────────────────────────────────────
  SVG  : ${SCRIPT_DIR}/logs/network_diagram.svg
  Docs : ${SCRIPT_DIR}/logs/network_diagram.md

── Full output log ─────────────────────────────────────────────────────────────
  ${LOG_FILE}

REPORT

REPORT_END=$(now)

# ─── NETWORK DIAGRAM ─────────────────────────────────────────────────────────
DIAGRAM_START=$(now)
log "━━━ GENERATING NETWORK DIAGRAM ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DIAGRAM_SCRIPT="${EVR_DIR}/verify_scripts/generate_network_diagram.sh"
if [[ -x "$DIAGRAM_SCRIPT" ]]; then
    cd "$EVR_DIR"
    bash "$DIAGRAM_SCRIPT" 2>&1 | tee -a "$LOG_FILE" && true || log "Network diagram generation failed (non-fatal)"
else
    log "generate_network_diagram.sh not found or not executable — skipping"
fi
DIAGRAM_END=$(now)
ok "Network diagram complete ($(elapsed $DIAGRAM_START $DIAGRAM_END))"

# ─── VERIFICATION ────────────────────────────────────────────────────────────
VERIFY_START=$(now)
log "━━━ RUNNING VERIFICATION ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
VERIFY_SCRIPT="${EVR_DIR}/verify_scripts/verify_all.sh"
if [[ -x "$VERIFY_SCRIPT" ]]; then
    cd "$EVR_DIR"
    bash "$VERIFY_SCRIPT" --verify all 2>&1 | tee -a "$LOG_FILE" && ok "All verification checks passed" \
        || log "Verification completed with failures (non-fatal — see log)"
else
    log "verify_all.sh not found or not executable — skipping"
fi
VERIFY_END=$(now)
ok "Verification complete ($(elapsed $VERIFY_START $VERIFY_END))"

DEPLOY_END=$(now)

# ─── TIMING SUMMARY ──────────────────────────────────────────────────────────
cat >> "$REPORT_FILE" <<TIMING
── Timing Summary ──────────────────────────────────────────────────────────────
  Pre-flight check         : $(elapsed $PREFLIGHT_START $PREFLIGHT_END)
  existing_vpc_resources   :
    init                   : $(elapsed $EVR_INIT_START $EVR_PLAN_START)
    plan                   : $(elapsed $EVR_PLAN_START $EVR_APPLY_START)
    apply                  : $(elapsed $EVR_APPLY_START $EVR_APPLY_END)
    total                  : $(elapsed $EVR_START $EVR_END)
  autoscale_template       :
    init                   : $(elapsed $ASG_INIT_START $ASG_PLAN_START)
    plan                   : $(elapsed $ASG_PLAN_START $ASG_APPLY_START)
    apply                  : $(elapsed $ASG_APPLY_START $ASG_APPLY_END)
    total                  : $(elapsed $ASG_START $ASG_END)
  Report build             : $(elapsed $REPORT_START $REPORT_END)
  Network diagram          : $(elapsed $DIAGRAM_START $DIAGRAM_END)
  Verification             : $(elapsed $VERIFY_START $VERIFY_END)
  ─────────────────────────────────────────────────────
  TOTAL DEPLOY TIME        : $(elapsed $DEPLOY_START $DEPLOY_END)

================================================================================
  DEPLOY COMPLETE  —  $(date)
  Re-authenticate if needed, then run: bash teardown.sh
================================================================================
TIMING

cat "$REPORT_FILE" | tee -a "$LOG_FILE"

# Save state for teardown.sh
cat > "$STATE_FILE" <<STATE
REPORT_FILE="${REPORT_FILE}"
LOG_FILE="${LOG_FILE}"
STATE

ok "State saved to ${STATE_FILE}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Deploy complete. Re-authenticate if needed, then: bash teardown.sh${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
