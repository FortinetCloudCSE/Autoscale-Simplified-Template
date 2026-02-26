#!/bin/bash

# Stress Test - FortiGate Monitoring
# Creates byobu session with FortiGate mpstat monitoring
# Monitors ASG for healthy instances and connects automatically

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD_FILE="${SCRIPT_DIR}/logs/network_diagram.md"
AUTOSCALE_TFVARS="${SCRIPT_DIR}/terraform/autoscale_template/terraform.tfvars"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_waiting() { echo -e "${CYAN}[WAIT]${NC} $1"; }

# Check dependencies
check_deps() {
    local missing=()
    command -v byobu >/dev/null 2>&1 || missing+=("byobu")
    command -v sshpass >/dev/null 2>&1 || missing+=("sshpass")
    command -v aws >/dev/null 2>&1 || missing+=("awscli")

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}"
        exit 1
    fi
}

# Clean byobu cache to avoid errors
clean_byobu_cache() {
    rm -rf ~/.cache/byobu/.last.tmux 2>/dev/null || true
    rm -rf ~/.cache/byobu/* 2>/dev/null || true
    rm -rf ~/.byobu/.last.tmux 2>/dev/null || true
}

# Check terminal size
check_terminal_size() {
    TERM_COLS=$(tput cols)
    TERM_LINES=$(tput lines)
    local min_cols=80
    local min_lines=20

    echo "Terminal size: ${TERM_COLS}x${TERM_LINES} (columns x rows)"

    if [ "$TERM_COLS" -lt "$min_cols" ] || [ "$TERM_LINES" -lt "$min_lines" ]; then
        print_error "Terminal too small!"
        echo "  Current:  ${TERM_COLS} columns x ${TERM_LINES} rows"
        echo "  Required: ${min_cols} columns x ${min_lines} rows (minimum)"
        exit 1
    fi
    print_ok "Terminal size OK"
}

# Check if network_diagram.md exists
check_md_file() {
    if [ ! -f "$MD_FILE" ]; then
        print_error "network_diagram.md not found at: $MD_FILE"
        echo "Run ./verify_scripts/generate_network_diagram.sh first"
        exit 1
    fi
}

# Get ASG module prefix from terraform.tfvars
get_asg_prefix() {
    if [ -f "$AUTOSCALE_TFVARS" ]; then
        ASG_PREFIX=$(grep "^asg_module_prefix" "$AUTOSCALE_TFVARS" 2>/dev/null | sed 's/.*=.*"\([^"]*\)".*/\1/' | tr -d ' ')
    fi

    # If not found in tfvars, try to discover from AWS
    if [ -z "$ASG_PREFIX" ]; then
        # Try to find ASG with fortigate/fgt pattern
        ASG_PREFIX=$(aws autoscaling describe-auto-scaling-groups \
            --region "$REGION" \
            --query "AutoScalingGroups[?contains(AutoScalingGroupName,'fgt') || contains(AutoScalingGroupName,'fortigate')].AutoScalingGroupName" \
            --output text 2>/dev/null | head -1 | sed 's/-fgt.*//')
    fi
}

# Discover ASG name by prefix
discover_asg() {
    print_info "Discovering FortiGate ASG..."

    get_asg_prefix

    if [ -n "$ASG_PREFIX" ]; then
        ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
            --region "$REGION" \
            --query "AutoScalingGroups[?contains(AutoScalingGroupName,'${ASG_PREFIX}')].AutoScalingGroupName" \
            --output text 2>/dev/null | head -1)
    fi

    # Fallback: search for any FortiGate ASG
    if [ -z "$ASG_NAME" ]; then
        ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
            --region "$REGION" \
            --query "AutoScalingGroups[?contains(AutoScalingGroupName,'fgt') || contains(AutoScalingGroupName,'fortigate')].AutoScalingGroupName" \
            --output text 2>/dev/null | head -1)
    fi

    if [ -z "$ASG_NAME" ]; then
        print_error "Could not find any FortiGate ASG in region $REGION"
        exit 1
    fi

    print_ok "Found ASG: $ASG_NAME"
}

# Get healthy instance public IPs from ASG
get_healthy_instances() {
    # Get instance IDs from ASG that are InService
    local instance_ids=$(aws autoscaling describe-auto-scaling-groups \
        --region "$REGION" \
        --auto-scaling-group-names "$ASG_NAME" \
        --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
        --output text 2>/dev/null)

    if [ -z "$instance_ids" ] || [ "$instance_ids" == "None" ]; then
        echo ""
        return
    fi

    # Get public IPs from the management interface (DeviceIndex 2 for dedicated mgmt, or 0 for default)
    # Try DeviceIndex 2 first (dedicated management ENI), then 0 (public interface)
    local public_ips=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids $instance_ids \
        --query "Reservations[].Instances[].NetworkInterfaces[?Attachment.DeviceIndex==\`2\`].Association.PublicIp" \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v "^$" | head -2)

    # Fallback to DeviceIndex 0 if no IPs found
    if [ -z "$public_ips" ]; then
        public_ips=$(aws ec2 describe-instances \
            --region "$REGION" \
            --instance-ids $instance_ids \
            --query "Reservations[].Instances[].NetworkInterfaces[?Attachment.DeviceIndex==\`0\`].Association.PublicIp" \
            --output text 2>/dev/null | tr '\t' '\n' | grep -v "^$" | head -2)
    fi

    echo "$public_ips"
}

# Parse values from network_diagram.md
parse_md_file() {
    print_info "Parsing $MD_FILE..."

    REGION=$(grep "^\*\*Region:\*\*" "$MD_FILE" | sed 's/.*\*\*Region:\*\* \([^ ]*\).*/\1/')
    # Column 5 is Public IP (Name|ID|Private|Public)
    JUMP_BOX_PUBLIC=$(grep "jump-box-instance" "$MD_FILE" | head -1 | awk -F'|' '{print $5}' | tr -d ' ')

    # Try to get FortiGate IPs from network_diagram.md first
    FGT_PRIMARY_PUBLIC=$(grep "| Primary |" "$MD_FILE" | awk -F'|' '{print $6}' | tr -d ' ')
    FGT_SECONDARY_PUBLIC=$(grep "| Secondary |" "$MD_FILE" | awk -F'|' '{print $6}' | tr -d ' ')

    print_ok "Region: $REGION"
    print_ok "Jump Box: $JUMP_BOX_PUBLIC"

    # If no FortiGate IPs in network_diagram.md, we'll discover via ASG
    if [ -n "$FGT_PRIMARY_PUBLIC" ]; then
        print_ok "FGT Primary (from diagram): $FGT_PRIMARY_PUBLIC"
        if [ -n "$FGT_SECONDARY_PUBLIC" ]; then
            print_ok "FGT Secondary (from diagram): $FGT_SECONDARY_PUBLIC"
        fi
        ASG_MONITOR_MODE=false
    else
        print_info "No FortiGate instances in diagram - will monitor ASG for healthy instances"
        ASG_MONITOR_MODE=true
    fi
}

# FortiGate credentials
FGT_USER="admin"
FGT_PASS="Texas4me!"

# Create a temporary monitor script file
# This avoids issues with send-keys garbling multi-line scripts
create_monitor_script() {
    local script_file="$1"
    local asg_name="$2"
    local region="$3"
    local known_ips="$4"
    local fgt_user="$5"
    local fgt_pass="$6"
    local pane_id="${7:-0.1}"

    # Use heredoc with variable expansion (no 'EOF' quoting)
    cat > "$script_file" << EOF
#!/bin/bash
ASG_NAME="${asg_name}"
REGION="${region}"
KNOWN_IPS="${known_ips}"
FGT_USER="${fgt_user}"
FGT_PASS="${fgt_pass}"
PANE_ID="${pane_id}"

echo "=========================================="
echo "Monitoring ASG for healthy instances..."
echo "ASG: \$ASG_NAME"
echo "Region: \$REGION"
if [ -n "\$KNOWN_IPS" ]; then
    echo "Excluding IPs: \$KNOWN_IPS"
fi
echo "=========================================="
echo ""

while true; do
    INSTANCE_IDS=\$(aws autoscaling describe-auto-scaling-groups \\
        --region "\$REGION" \\
        --auto-scaling-group-names "\$ASG_NAME" \\
        --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \\
        --output text 2>/dev/null)

    if [ -n "\$INSTANCE_IDS" ] && [ "\$INSTANCE_IDS" != "None" ]; then
        # Try DeviceIndex 2 (dedicated management) first
        PUBLIC_IP=\$(aws ec2 describe-instances \\
            --region "\$REGION" \\
            --instance-ids \$INSTANCE_IDS \\
            --query "Reservations[].Instances[].NetworkInterfaces[?Attachment.DeviceIndex==\\\`2\\\`].Association.PublicIp" \\
            --output text 2>/dev/null | tr '\t' '\n' | grep -v "^\$" | head -5)

        # Fallback to DeviceIndex 0 if empty
        if [ -z "\$PUBLIC_IP" ]; then
            PUBLIC_IP=\$(aws ec2 describe-instances \\
                --region "\$REGION" \\
                --instance-ids \$INSTANCE_IDS \\
                --query "Reservations[].Instances[].NetworkInterfaces[?Attachment.DeviceIndex==\\\`0\\\`].Association.PublicIp" \\
                --output text 2>/dev/null | tr '\t' '\n' | grep -v "^\$" | head -5)
        fi

        # Find an IP that's not in KNOWN_IPS
        for IP in \$PUBLIC_IP; do
            if [ -n "\$IP" ] && ! echo ",\$KNOWN_IPS," | grep -q ",\$IP,"; then
                echo ""
                echo "=========================================="
                echo "Found healthy FortiGate: \$IP"
                echo "Waiting 30s for instance to fully initialize..."
                echo "=========================================="
                sleep 30
                echo "Connecting to \$IP and running mpstat..."
                echo ""
                # Loop to auto-reconnect if SSH drops
                while true; do
                    # Pipe command to stdin after delay, keep stdin open with cat
                    # This allows the interactive mpstat command to run properly
                    (sleep 2; echo "diag sys mpstat 3"; cat) | sshpass -p "\$FGT_PASS" ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30 \${FGT_USER}@\${IP}
                    echo ""
                    echo "Connection lost. Reconnecting in 5s..."
                    sleep 5
                done
            fi
        done
    fi

    echo -n "."
    sleep 5
done
EOF

    chmod +x "$script_file"
}

# Temp directory for monitor scripts
MONITOR_SCRIPT_DIR="/tmp/fgt-monitor-$$"

# Cleanup function
cleanup_monitor_scripts() {
    rm -rf "$MONITOR_SCRIPT_DIR" 2>/dev/null || true
}

# Build remaining panes in background
# Layout:
#   +----------------------------------+
#   | FGT Instance 1 mpstat            |
#   +----------------------------------+
#   | FGT Instance 2 mpstat            |
#   | (or waiting for new instance)    |
#   +----------------------------------+
# Note: GWLB/ASG monitoring moved to monitor_asg.sh
build_remaining_panes() {
    local SESSION="$1"
    sleep 2

    # Use ASG monitor mode function if no FortiGate IPs were found in diagram
    if [ "$ASG_MONITOR_MODE" = true ]; then
        build_remaining_panes_asg_mode "$SESSION"
        return
    fi

    # Normal mode: We have at least Primary IP
    # Create the bottom pane for FGT Secondary
    byobu split-window -t $SESSION:0.0 -v || { echo "Failed to split window"; return 1; }
    # Now: pane 0 = FGT Primary (top), pane 1 = FGT Secondary (bottom)

    if [ -n "$FGT_SECONDARY_PUBLIC" ]; then
        # Secondary already exists - connect directly
        byobu send-keys -t $SESSION:0.1 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_SECONDARY_PUBLIC" Enter
        sleep 2
        byobu send-keys -t $SESSION:0.1 "diag sys mpstat 1" Enter
    else
        # No secondary - create monitor script and run it
        local script_file="${MONITOR_SCRIPT_DIR}/monitor_pane1.sh"
        create_monitor_script "$script_file" "$ASG_NAME" "$REGION" "$FGT_PRIMARY_PUBLIC" "$FGT_USER" "$FGT_PASS" "0.1"
        byobu send-keys -t $SESSION:0.1 "$script_file" Enter
    fi
}

# Create the byobu session
create_session() {
    local SESSION="fgt-monitor"

    # Kill existing session if it exists
    byobu kill-session -t $SESSION 2>/dev/null || true

    # Create temp directory for monitor scripts
    mkdir -p "$MONITOR_SCRIPT_DIR"

    print_info "Creating byobu session: $SESSION"

    # Create session with first pane
    byobu new-session -d -s $SESSION -n 'FortiGates' -x "$TERM_COLS" -y "$TERM_LINES"

    # Create second pane immediately (split vertically)
    byobu split-window -t $SESSION:0.0 -v

    # Setup first pane (top - pane 0)
    if [ "$ASG_MONITOR_MODE" = true ]; then
        # ASG Monitor Mode: monitor for first instance
        local script_file0="${MONITOR_SCRIPT_DIR}/monitor_pane0.sh"
        create_monitor_script "$script_file0" "$ASG_NAME" "$REGION" "" "$FGT_USER" "$FGT_PASS" "0.0"
        byobu send-keys -t $SESSION:0.0 "$script_file0" Enter
    else
        # Normal mode: Connect directly to known Primary IP
        byobu send-keys -t $SESSION:0.0 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_PRIMARY_PUBLIC" Enter
        sleep 1
        byobu send-keys -t $SESSION:0.0 "diag sys mpstat 1" Enter
    fi

    # Setup second pane (bottom - pane 1)
    if [ "$ASG_MONITOR_MODE" = true ]; then
        # ASG Monitor Mode: monitor for second instance
        # Get current healthy IPs so pane 1 can exclude them (pane 0 will grab one of these)
        local current_ips=$(get_healthy_instances | tr '\n' ',' | sed 's/,$//')
        local script_file1="${MONITOR_SCRIPT_DIR}/monitor_pane1.sh"
        # Pass current IPs to exclude - pane 1 will wait for a NEW instance
        create_monitor_script "$script_file1" "$ASG_NAME" "$REGION" "$current_ips" "$FGT_USER" "$FGT_PASS" "0.1"
        byobu send-keys -t $SESSION:0.1 "$script_file1" Enter
    elif [ -n "$FGT_SECONDARY_PUBLIC" ]; then
        # Secondary already exists - connect directly
        byobu send-keys -t $SESSION:0.1 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_SECONDARY_PUBLIC" Enter
        sleep 1
        byobu send-keys -t $SESSION:0.1 "diag sys mpstat 1" Enter
    else
        # No secondary yet - create monitor script
        local script_file1="${MONITOR_SCRIPT_DIR}/monitor_pane1.sh"
        create_monitor_script "$script_file1" "$ASG_NAME" "$REGION" "$FGT_PRIMARY_PUBLIC" "$FGT_USER" "$FGT_PASS" "0.1"
        byobu send-keys -t $SESSION:0.1 "$script_file1" Enter
    fi

    print_ok "Session created - attaching now!"
    echo ""
    echo "=========================================="
    echo "FortiGate Monitoring"
    echo "=========================================="
    echo ""
    echo "ASG: $ASG_NAME"
    echo ""
    echo "Layout:"
    echo "  +----------------------------------+"
    echo "  | FGT Instance 1 mpstat            |"
    echo "  +----------------------------------+"
    echo "  | FGT Instance 2 mpstat            |"
    echo "  +----------------------------------+"
    if [ "$ASG_MONITOR_MODE" = true ]; then
        echo ""
        echo "Both panes are monitoring ASG for healthy instances..."
        echo "Will auto-connect when FortiGate becomes InService"
    elif [ -z "$FGT_SECONDARY_PUBLIC" ]; then
        echo ""
        echo "Bottom pane will auto-connect when new FortiGate is detected"
    fi
    echo ""
    echo "Note: Use monitor_asg.sh for GWLB/ASG monitoring"
    echo ""
    echo "Navigation:"
    echo "  Shift+Arrows - Move between panes"
    echo "  F6 - Detach"
    echo ""

    # Attach to session
    byobu attach -t $SESSION
}

# Build remaining panes for ASG monitor mode
# In this mode, we want second pane to wait for a second instance
build_remaining_panes_asg_mode() {
    local SESSION="$1"
    sleep 2

    # Create the bottom pane
    byobu split-window -t $SESSION:0.0 -v || { echo "Failed to split window"; return 1; }

    # Wait a bit for first pane to potentially find an instance
    sleep 10

    # Get current healthy IPs to exclude (first pane may have connected to one)
    local current_ips=$(get_healthy_instances | tr '\n' ',' | sed 's/,$//')

    # Create monitor script for second pane (excludes any IPs first pane connected to)
    local script_file="${MONITOR_SCRIPT_DIR}/monitor_pane1.sh"
    create_monitor_script "$script_file" "$ASG_NAME" "$REGION" "$current_ips" "$FGT_USER" "$FGT_PASS" "0.1"
    byobu send-keys -t $SESSION:0.1 "$script_file" Enter
}

#==========================================================================
# Main
#==========================================================================
echo ""
echo "=========================================="
echo "FortiGate CPU Monitoring (mpstat)"
echo "=========================================="
echo ""

check_deps
clean_byobu_cache
check_terminal_size
check_md_file
parse_md_file

# Always discover the ASG (needed for monitoring new instances)
discover_asg

echo ""
read -p "Create session? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    create_session
else
    print_info "Aborted"
fi
