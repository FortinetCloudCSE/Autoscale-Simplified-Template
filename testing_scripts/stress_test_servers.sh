#!/bin/bash

# Stress Test - iperf Servers
# Creates byobu session with iperf3 servers on East AZ1 and West AZ2
# RUN THIS BEFORE stress_test_clients.sh

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
    command -v byobu >/dev/null 2>&1 || { print_error "Missing byobu. Install with: brew install byobu"; exit 1; }
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
    local min_cols=100
    local min_lines=30

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

# Parse values from network_diagram.md
parse_md_file() {
    print_info "Parsing $MD_FILE..."

    # Column 5 is Public IP (Name|ID|Private|Public)
    JUMP_BOX_PUBLIC=$(grep "jump-box-instance" "$MD_FILE" | head -1 | awk -F'|' '{print $5}' | tr -d ' ')
    EAST_AZ1_PRIVATE=$(grep "east-public-az1-instance" "$MD_FILE" | awk -F'|' '{print $3}' | tr -d ' ')
    WEST_AZ2_PRIVATE=$(grep "west-public-az2-instance" "$MD_FILE" | awk -F'|' '{print $3}' | tr -d ' ')

    if [ -z "$JUMP_BOX_PUBLIC" ]; then
        print_error "Could not find Jump Box public IP"
        exit 1
    fi

    print_ok "Jump Box: $JUMP_BOX_PUBLIC"
    print_ok "East AZ1 (server): $EAST_AZ1_PRIVATE"
    print_ok "West AZ2 (server): $WEST_AZ2_PRIVATE"
}

# Build remaining panes in background
# Final layout (like a map - West on left, East on right):
#   +------------------+------------------+
#   | West AZ2 iperf   | East AZ1 iperf   |
#   +------------------+------------------+
build_remaining_panes() {
    local SESSION="$1"
    sleep 2

    # Split horizontally to create left/right columns
    byobu split-window -t $SESSION:0.0 -h
    # Now: pane 0 = West iperf (left), pane 1 = East iperf (right)
    byobu send-keys -t $SESSION:0.1 "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o 'ProxyCommand=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ubuntu@$JUMP_BOX_PUBLIC' ubuntu@$EAST_AZ1_PRIVATE" Enter
    sleep 3
    byobu send-keys -t $SESSION:0.1 "echo '=== East AZ1 iperf3 Server ==='" Enter
    byobu send-keys -t $SESSION:0.1 "iperf3 -s" Enter
}

# Create the byobu session
create_session() {
    local SESSION="iperf-servers"

    # Kill existing session if it exists
    byobu kill-session -t $SESSION 2>/dev/null || true

    print_info "Creating byobu session: $SESSION"

    # Create session with first pane - West AZ2 server (left side, like a map)
    byobu new-session -d -s $SESSION -n 'Servers' -x "$TERM_COLS" -y "$TERM_LINES"

    byobu send-keys -t $SESSION:0.0 "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o 'ProxyCommand=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ubuntu@$JUMP_BOX_PUBLIC' ubuntu@$WEST_AZ2_PRIVATE" Enter
    sleep 2
    byobu send-keys -t $SESSION:0.0 "echo '=== West AZ2 iperf3 Server ==='" Enter
    byobu send-keys -t $SESSION:0.0 "iperf3 -s" Enter

    print_ok "Session created - attaching now!"
    echo ""
    echo "=========================================="
    echo "iperf3 Servers Session"
    echo "=========================================="
    echo ""
    echo "Layout (like a map):"
    echo "  Left:  West AZ2 server (iperf3 -s)"
    echo "  Right: East AZ1 server (iperf3 -s)"
    echo ""
    echo "Servers listening on port 5201"
    echo ""
    echo "NEXT: Run ./stress_test_clients.sh in another terminal"
    echo ""
    echo "Navigation:"
    echo "  Shift+Arrows - Move between panes"
    echo "  F6 - Detach"
    echo ""

    # Start background builder
    build_remaining_panes "$SESSION" &

    # Attach immediately
    byobu attach -t $SESSION
}

#==========================================================================
# Main
#==========================================================================
echo ""
echo "=========================================="
echo "iperf3 Servers (Start First)"
echo "=========================================="
echo ""

check_deps
clean_byobu_cache
check_terminal_size
check_md_file
parse_md_file

echo ""
read -p "Create session? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    create_session
else
    print_info "Aborted"
fi
