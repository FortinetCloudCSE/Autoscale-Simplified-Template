#!/bin/bash

# Stress Test Script for FortiGate AutoScale Group
# Runs from Mac at repo root, creates byobu session with monitoring and traffic generation
#
# Layout:
#   Window 0: FortiGate monitoring (6 panes)
#   Window 1: AZ1 traffic - West (client) -> East (server)
#   Window 2: AZ2 traffic - East (client) -> West (server)
#   Window 3: GWLB Target Group monitor

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD_FILE="${SCRIPT_DIR}/logs/network_diagram.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check dependencies
check_deps() {
    local missing=()
    command -v byobu >/dev/null 2>&1 || missing+=("byobu")
    command -v sshpass >/dev/null 2>&1 || missing+=("sshpass")

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}"
        exit 1
    fi
}

# Check terminal size and store for session creation
check_terminal_size() {
    TERM_COLS=$(tput cols)
    TERM_LINES=$(tput lines)
    local min_cols=150
    local min_lines=50

    echo "Terminal size: ${TERM_COLS}x${TERM_LINES} (columns x rows)"

    if [ "$TERM_COLS" -lt "$min_cols" ] || [ "$TERM_LINES" -lt "$min_lines" ]; then
        echo ""
        print_error "Terminal too small for pane layout!"
        echo ""
        echo "  Current:  ${TERM_COLS} columns × ${TERM_LINES} rows"
        echo "  Required: ${min_cols} columns × ${min_lines} rows (minimum)"
        echo ""
        echo "Please resize your terminal window and try again."
        echo "Tip: Maximize the terminal or use Cmd+Plus to check if font is too large."
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

# Parse values from network_diagram.md
parse_md_file() {
    print_info "Parsing $MD_FILE..."

    # Extract prefix from title (e.g., "dis-poc" from "# Network Diagram - dis-poc Infrastructure")
    PREFIX=$(grep "^# Network Diagram" "$MD_FILE" | sed 's/.*- \(.*\) Infrastructure/\1/')

    # Extract region from the file
    REGION=$(grep "^\*\*Region:\*\*" "$MD_FILE" | sed 's/.*\*\*Region:\*\* \([^ ]*\).*/\1/')

    # Extract Jump Box public IP (column 5: Name|ID|Private|Public)
    JUMP_BOX_PUBLIC=$(grep "jump-box-instance" "$MD_FILE" | head -1 | awk -F'|' '{print $5}' | tr -d ' ')

    # Extract FortiGate IPs (Primary and Secondary)
    FGT_PRIMARY_PUBLIC=$(grep "| Primary |" "$MD_FILE" | awk -F'|' '{print $6}' | tr -d ' ')
    FGT_SECONDARY_PUBLIC=$(grep "| Secondary |" "$MD_FILE" | awk -F'|' '{print $6}' | tr -d ' ')

    # Extract spoke instance private IPs
    EAST_AZ1_PRIVATE=$(grep "east-public-az1-instance" "$MD_FILE" | awk -F'|' '{print $3}' | tr -d ' ')
    EAST_AZ2_PRIVATE=$(grep "east-public-az2-instance" "$MD_FILE" | awk -F'|' '{print $3}' | tr -d ' ')
    WEST_AZ1_PRIVATE=$(grep "west-public-az1-instance" "$MD_FILE" | awk -F'|' '{print $3}' | tr -d ' ')
    WEST_AZ2_PRIVATE=$(grep "west-public-az2-instance" "$MD_FILE" | awk -F'|' '{print $3}' | tr -d ' ')

    # Validate
    if [ -z "$JUMP_BOX_PUBLIC" ]; then
        print_error "Could not find Jump Box public IP"
        exit 1
    fi

    print_ok "Prefix: $PREFIX"
    print_ok "Region: $REGION"
    print_ok "Jump Box: $JUMP_BOX_PUBLIC"
    print_ok "FGT Primary: $FGT_PRIMARY_PUBLIC"
    print_ok "FGT Secondary: $FGT_SECONDARY_PUBLIC"
    print_ok "East AZ1: $EAST_AZ1_PRIVATE"
    print_ok "East AZ2: $EAST_AZ2_PRIVATE"
    print_ok "West AZ1: $WEST_AZ1_PRIVATE"
    print_ok "West AZ2: $WEST_AZ2_PRIVATE"
}

# FortiGate credentials
FGT_USER="admin"
FGT_PASS="Texas4me!"

# Build remaining windows in background
build_remaining_windows() {
    local SESSION="$1"

    #==========================================================================
    # Window 0: Add remaining panes (panes 0.1 through 0.5)
    #==========================================================================
    sleep 1

    # Split right: FGT Secondary mpstat
    byobu split-window -t $SESSION:0 -h
    byobu send-keys -t $SESSION:0.1 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_SECONDARY_PUBLIC" Enter
    sleep 2
    byobu send-keys -t $SESSION:0.1 "diag sys mpstat 1" Enter

    # Split bottom left: FGT Primary sniffer
    byobu select-pane -t $SESSION:0.0
    byobu split-window -t $SESSION:0 -v
    byobu send-keys -t $SESSION:0.2 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_PRIMARY_PUBLIC" Enter
    sleep 2
    byobu send-keys -t $SESSION:0.2 "diag sniffer packet any 'tcp port 5001' 4 0 1" Enter

    # Split bottom right: FGT Secondary sniffer
    byobu select-pane -t $SESSION:0.1
    byobu split-window -t $SESSION:0 -v
    byobu send-keys -t $SESSION:0.3 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_SECONDARY_PUBLIC" Enter
    sleep 2
    byobu send-keys -t $SESSION:0.3 "diag sniffer packet any 'tcp port 5001' 4 0 1" Enter

    # Split for session stats - bottom row
    byobu select-pane -t $SESSION:0.2
    byobu split-window -t $SESSION:0 -v
    byobu send-keys -t $SESSION:0.4 "while true; do echo '=== FGT Primary Session Stats ===' ; date; sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_PRIMARY_PUBLIC 'diagnose sys session stat'; sleep 5; done" Enter

    byobu select-pane -t $SESSION:0.3
    byobu split-window -t $SESSION:0 -v
    byobu send-keys -t $SESSION:0.5 "while true; do echo '=== FGT Secondary Session Stats ===' ; date; sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_SECONDARY_PUBLIC 'diagnose sys session stat'; sleep 5; done" Enter

    #==========================================================================
    # Window 1: AZ1 Traffic - West (client) -> East (server)
    # Layout: Left=West (client), Right=East (server)
    # Server panes created FIRST to ensure iperf3 -s is running before client
    #==========================================================================
    byobu new-window -t $SESSION:1 -n 'AZ1-Traffic'

    # RIGHT SIDE FIRST (server): East AZ1
    byobu send-keys -t $SESSION:1.0 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$EAST_AZ1_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:1.0 "iperf3 -s" Enter

    # Split for East AZ1 mpstat (bottom right)
    byobu split-window -t $SESSION:1 -v
    byobu send-keys -t $SESSION:1.1 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$EAST_AZ1_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:1.1 "mpstat 1" Enter

    # LEFT SIDE (client): West AZ1 - split horizontally from pane 0
    byobu select-pane -t $SESSION:1.0
    byobu split-window -t $SESSION:1 -h -b
    byobu send-keys -t $SESSION:1.0 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$WEST_AZ1_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:1.0 "echo '# West AZ1 -> East AZ1 client'" Enter
    byobu send-keys -t $SESSION:1.0 "echo '# Run: iperf3 -c $EAST_AZ1_PRIVATE -P 20 -t 300'" Enter

    # Split for West AZ1 mpstat (bottom left)
    byobu split-window -t $SESSION:1.0 -v
    byobu send-keys -t $SESSION:1.1 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$WEST_AZ1_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:1.1 "mpstat 1" Enter

    #==========================================================================
    # Window 2: AZ2 Traffic - East (client) -> West (server)
    # Layout: Left=West (server), Right=East (client)
    # Server panes created FIRST to ensure iperf3 -s is running before client
    #==========================================================================
    byobu new-window -t $SESSION:2 -n 'AZ2-Traffic'

    # LEFT SIDE FIRST (server): West AZ2
    byobu send-keys -t $SESSION:2.0 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$WEST_AZ2_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:2.0 "iperf3 -s" Enter

    # Split for West AZ2 mpstat (bottom left)
    byobu split-window -t $SESSION:2 -v
    byobu send-keys -t $SESSION:2.1 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$WEST_AZ2_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:2.1 "mpstat 1" Enter

    # RIGHT SIDE (client): East AZ2 - split horizontally
    byobu select-pane -t $SESSION:2.0
    byobu split-window -t $SESSION:2 -h
    byobu send-keys -t $SESSION:2.2 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$EAST_AZ2_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:2.2 "echo '# East AZ2 -> West AZ2 client'" Enter
    byobu send-keys -t $SESSION:2.2 "echo '# Run: iperf3 -c $WEST_AZ2_PRIVATE -P 20 -t 300'" Enter

    # Split for East AZ2 mpstat (bottom right)
    byobu split-window -t $SESSION:2.2 -v
    byobu send-keys -t $SESSION:2.3 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J ubuntu@$JUMP_BOX_PUBLIC ubuntu@$EAST_AZ2_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:2.3 "mpstat 1" Enter

    #==========================================================================
    # Window 3: GWLB Target Group Monitor
    #==========================================================================
    byobu new-window -t $SESSION:3 -n 'GWLB-Monitor'

    byobu send-keys -t $SESSION:3.0 "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$JUMP_BOX_PUBLIC" Enter
    sleep 2
    byobu send-keys -t $SESSION:3.0 "TGP_ARN=\$(aws elbv2 describe-target-groups --region $REGION --query \"TargetGroups[?contains(TargetGroupName, 'gwlb')].TargetGroupArn\" --output text | head -1)" Enter
    sleep 1
    byobu send-keys -t $SESSION:3.0 "echo \"Target Group ARN: \$TGP_ARN\"" Enter
    byobu send-keys -t $SESSION:3.0 "while true; do echo ''; echo '==================='; date; aws elbv2 describe-target-health --region $REGION --target-group-arn \$TGP_ARN --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' --output table; sleep 3; done" Enter

    # Return to window 0
    byobu select-window -t $SESSION:0
}

# Create the byobu session
create_session() {
    local SESSION="stress"

    # Kill existing session if it exists
    byobu kill-session -t $SESSION 2>/dev/null || true

    print_info "Creating byobu session: $SESSION"

    #==========================================================================
    # Create session with Window 0 and first pane only
    #==========================================================================
    byobu new-session -d -s $SESSION -n 'FortiGates' -x "$TERM_COLS" -y "$TERM_LINES"

    # Start first pane: FGT Primary mpstat
    byobu send-keys -t $SESSION:0.0 "sshpass -p '$FGT_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $FGT_USER@$FGT_PRIMARY_PUBLIC" Enter
    sleep 1
    byobu send-keys -t $SESSION:0.0 "diag sys mpstat 1" Enter

    #==========================================================================
    # Launch background builder and attach immediately
    #==========================================================================
    print_ok "Session created - attaching now!"
    echo ""
    echo "=========================================="
    echo "Stress Test Session"
    echo "=========================================="
    echo ""
    echo "Building windows in background - watch them appear!"
    echo ""
    echo "Navigation:"
    echo "  F3/F4        - Previous/Next window"
    echo "  Shift+F3/F4  - Previous/Next pane"
    echo "  Shift+Arrows - Move between panes directionally"
    echo ""
    echo "Windows (appearing shortly):"
    echo "  0: FortiGates (mpstat, sniffer, session stats)"
    echo "  1: AZ1 Traffic (West->East)"
    echo "  2: AZ2 Traffic (East->West)"
    echo "  3: GWLB Target Monitor"
    echo ""
    echo "To start traffic generation (after windows appear):"
    echo "  Window 1, top-left pane:  iperf3 -c $EAST_AZ1_PRIVATE -P 20 -t 300"
    echo "  Window 2, top-right pane: iperf3 -c $WEST_AZ2_PRIVATE -P 20 -t 300"
    echo ""
    echo "To exit: F6 (detach) or type 'exit' in each pane"
    echo ""

    # Start background builder
    build_remaining_windows "$SESSION" &

    # Attach immediately
    byobu attach -t $SESSION
}

#==========================================================================
# Main
#==========================================================================
echo ""
echo "=========================================="
echo "FortiGate AutoScale Stress Test"
echo "=========================================="
echo ""

check_deps
check_terminal_size
check_md_file
parse_md_file

echo ""
read -p "Create byobu session? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    create_session
else
    print_info "Aborted"
fi
