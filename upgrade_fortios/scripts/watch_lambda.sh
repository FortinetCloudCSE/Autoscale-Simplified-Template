#!/usr/bin/env bash
# watch_lambda.sh — Tail the autoscale Lambda's CloudWatch logs, reconnect on disconnect
#
# Usage:
#   bash scripts/watch_lambda.sh                 # function and region from state/blue_inventory.json
#   bash scripts/watch_lambda.sh <function-name> # a specific Lambda function
#   bash scripts/watch_lambda.sh /aws/lambda/x   # a specific log group
#
# The function tailed by default is the BYOL ASG's handler (the first function in the
# inventory that is not an "-internal" helper). Pass the on-demand handler's name to
# watch that ASG instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${INVENTORY:-${SCRIPT_DIR}/../state/blue_inventory.json}"

FUNCTION=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

if [[ -f "$INVENTORY" ]]; then
    # Prints "<function name> <region>"; either may be empty.
    read -r INV_FUNCTION INV_REGION < <(python3 - "$INVENTORY" <<'PY'
import json, sys
inv = json.load(open(sys.argv[1]))
names = [n for n in inv.get('lambda', {}).get('function_names', []) if n and not n.endswith('-internal')]
byol = [n for n in names if 'on_demand' not in n and 'ondemand' not in n]
print((byol or names or ['-'])[0], inv.get('discovery_metadata', {}).get('region') or '-')
PY
)
    [[ "$INV_FUNCTION" != "-" ]] && FUNCTION="$INV_FUNCTION"
    [[ "$INV_REGION" != "-" ]] && REGION="$INV_REGION"
fi

if [[ -n "${1:-}" ]]; then
    FUNCTION="$1"
fi

if [[ -z "$FUNCTION" ]]; then
    echo "Error: no Lambda function name. Run discover.py first, or pass the function name:"
    echo "  bash scripts/watch_lambda.sh <function-name>"
    exit 1
fi

if [[ "$FUNCTION" == /* ]]; then
    LOG_GROUP="$FUNCTION"
else
    LOG_GROUP="/aws/lambda/${FUNCTION}"
fi

REGION_ARGS=()
[[ -n "$REGION" ]] && REGION_ARGS=(--region "$REGION")

echo "Watching: ${LOG_GROUP}${REGION:+  (${REGION})}"
echo "Press Ctrl+C to stop."
echo ""

while true; do
    aws logs tail "${LOG_GROUP}" --follow ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
    echo "[$(date)] Disconnected — reconnecting in 10s..."
    sleep 10
done
