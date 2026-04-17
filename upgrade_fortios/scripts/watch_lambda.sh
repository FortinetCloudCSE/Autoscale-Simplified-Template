#!/usr/bin/env bash
# watch_lambda.sh — Tail Lambda CloudWatch logs, reconnect on disconnect

REGION="${AWS_DEFAULT_REGION:-us-west-2}"
LOG_GROUP="/aws/lambda/asg-fgt_byol_asg_fgt-asg-lambda"

echo "Watching: ${LOG_GROUP}"
echo "Press Ctrl+C to stop."
echo ""

while true; do
    aws logs tail "${LOG_GROUP}" --follow --region "${REGION}"
    echo "[$(date)] Disconnected — reconnecting in 10s..."
    sleep 10
done
