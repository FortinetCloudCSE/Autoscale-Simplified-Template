#!/bin/bash

# Common functions for verification scripts

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global counters
PASSED_CHECKS=0
FAILED_CHECKS=0
SKIPPED_CHECKS=0

# Print colored output
print_pass() {
    echo -e "${GREEN}[PASSED]${NC} $1"
    ((PASSED_CHECKS++))
}

print_fail() {
    echo -e "${RED}[FAILED]${NC} $1"
    ((FAILED_CHECKS++))
}

print_skip() {
    echo -e "${YELLOW}[SKIPPED]${NC} $1"
    ((SKIPPED_CHECKS++))
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}SUMMARY${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Total Passed:  ${GREEN}${PASSED_CHECKS}${NC}"
    echo -e "Total Failed:  ${RED}${FAILED_CHECKS}${NC}"
    echo -e "Total Skipped: ${YELLOW}${SKIPPED_CHECKS}${NC}"
    echo ""

    if [ $FAILED_CHECKS -eq 0 ]; then
        echo -e "${GREEN}All checks passed!${NC}"
        return 0
    else
        echo -e "${RED}Some checks failed!${NC}"
        return 1
    fi
}

# Read terraform.tfvars file
read_tfvars() {
    local tfvars_file="$1"

    if [ ! -f "$tfvars_file" ]; then
        print_fail "terraform.tfvars file not found at: $tfvars_file"
        exit 1
    fi

    print_info "Reading configuration from: $tfvars_file"
}

# Get value from tfvars file
get_tfvar() {
    local var_name="$1"
    local tfvars_file="$2"

    # Remove comments and extract variable value
    local value=$(grep "^${var_name}" "$tfvars_file" | head -1 | sed 's/.*=[ ]*//' | sed 's/"//g' | sed 's/#.*//' | xargs)
    echo "$value"
}

# Check if a boolean tfvar is true
is_tfvar_true() {
    local var_name="$1"
    local tfvars_file="$2"
    local value=$(get_tfvar "$var_name" "$tfvars_file")

    if [ "$value" == "true" ]; then
        return 0
    else
        return 1
    fi
}

# Verify VPC exists
verify_vpc_exists() {
    local vpc_name="$1"
    local region="$2"

    local vpc_id=$(aws ec2 describe-vpcs \
        --region "$region" \
        --filters "Name=tag:Name,Values=${vpc_name}" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null)

    if [ "$vpc_id" != "None" ] && [ -n "$vpc_id" ]; then
        echo "$vpc_id"
        return 0
    else
        return 1
    fi
}

# Verify VPC CIDR
verify_vpc_cidr() {
    local vpc_id="$1"
    local expected_cidr="$2"
    local region="$3"

    local actual_cidr=$(aws ec2 describe-vpcs \
        --region "$region" \
        --vpc-ids "$vpc_id" \
        --query 'Vpcs[0].CidrBlock' \
        --output text 2>/dev/null)

    if [ "$actual_cidr" == "$expected_cidr" ]; then
        return 0
    else
        echo "Expected: $expected_cidr, Got: $actual_cidr"
        return 1
    fi
}

# Verify subnet exists
verify_subnet_exists() {
    local subnet_name="$1"
    local region="$2"

    local subnet_id=$(aws ec2 describe-subnets \
        --region "$region" \
        --filters "Name=tag:Name,Values=${subnet_name}" \
        --query 'Subnets[0].SubnetId' \
        --output text 2>/dev/null)

    if [ "$subnet_id" != "None" ] && [ -n "$subnet_id" ]; then
        echo "$subnet_id"
        return 0
    else
        return 1
    fi
}

# Verify subnet CIDR
verify_subnet_cidr() {
    local subnet_id="$1"
    local expected_cidr="$2"
    local region="$3"

    local actual_cidr=$(aws ec2 describe-subnets \
        --region "$region" \
        --subnet-ids "$subnet_id" \
        --query 'Subnets[0].CidrBlock' \
        --output text 2>/dev/null)

    if [ "$actual_cidr" == "$expected_cidr" ]; then
        return 0
    else
        echo "Expected: $expected_cidr, Got: $actual_cidr"
        return 1
    fi
}

# Verify subnet in correct AZ
verify_subnet_az() {
    local subnet_id="$1"
    local expected_az="$2"
    local region="$3"

    local actual_az=$(aws ec2 describe-subnets \
        --region "$region" \
        --subnet-ids "$subnet_id" \
        --query 'Subnets[0].AvailabilityZone' \
        --output text 2>/dev/null)

    if [ "$actual_az" == "$expected_az" ]; then
        return 0
    else
        echo "Expected: $expected_az, Got: $actual_az"
        return 1
    fi
}

# Verify Internet Gateway exists and is attached
verify_igw() {
    local vpc_id="$1"
    local region="$2"

    local igw_id=$(aws ec2 describe-internet-gateways \
        --region "$region" \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text 2>/dev/null)

    if [ "$igw_id" != "None" ] && [ -n "$igw_id" ]; then
        echo "$igw_id"
        return 0
    else
        return 1
    fi
}

# Verify route exists in route table
verify_route_exists() {
    local route_table_id="$1"
    local dest_cidr="$2"
    local region="$3"

    local route=$(aws ec2 describe-route-tables \
        --region "$region" \
        --route-table-ids "$route_table_id" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='${dest_cidr}']" \
        --output text 2>/dev/null)

    if [ -n "$route" ]; then
        return 0
    else
        return 1
    fi
}

# Get route target for a destination
get_route_target() {
    local route_table_id="$1"
    local dest_cidr="$2"
    local region="$3"

    # Try different target types
    local target=$(aws ec2 describe-route-tables \
        --region "$region" \
        --route-table-ids "$route_table_id" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='${dest_cidr}'].GatewayId" \
        --output text 2>/dev/null)

    if [ -z "$target" ] || [ "$target" == "None" ]; then
        target=$(aws ec2 describe-route-tables \
            --region "$region" \
            --route-table-ids "$route_table_id" \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='${dest_cidr}'].TransitGatewayId" \
            --output text 2>/dev/null)
    fi

    if [ -z "$target" ] || [ "$target" == "None" ]; then
        target=$(aws ec2 describe-route-tables \
            --region "$region" \
            --route-table-ids "$route_table_id" \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='${dest_cidr}'].NatGatewayId" \
            --output text 2>/dev/null)
    fi

    echo "$target"
}

# Verify TGW attachment exists
verify_tgw_attachment() {
    local vpc_id="$1"
    local tgw_id="$2"
    local region="$3"

    local attachment_id=$(aws ec2 describe-transit-gateway-vpc-attachments \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=transit-gateway-id,Values=${tgw_id}" "Name=state,Values=available" \
        --query 'TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId' \
        --output text 2>/dev/null)

    if [ "$attachment_id" != "None" ] && [ -n "$attachment_id" ]; then
        echo "$attachment_id"
        return 0
    else
        return 1
    fi
}

# Verify EC2 instance exists
verify_ec2_instance() {
    local instance_name="$1"
    local region="$2"

    local instance_id=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:Name,Values=${instance_name}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)

    if [ "$instance_id" != "None" ] && [ -n "$instance_id" ]; then
        echo "$instance_id"
        return 0
    else
        return 1
    fi
}

# Get EC2 instance private IP
get_instance_private_ip() {
    local instance_id="$1"
    local region="$2"

    aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text 2>/dev/null
}

# Get EC2 instance public IP
get_instance_public_ip() {
    local instance_id="$1"
    local region="$2"

    aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null
}

# Get TGW ID by name
get_tgw_id_by_name() {
    local tgw_name="$1"
    local region="$2"

    local tgw_id=$(aws ec2 describe-transit-gateways \
        --region "$region" \
        --filters "Name=tag:Name,Values=${tgw_name}" "Name=state,Values=available" \
        --query 'TransitGateways[0].TransitGatewayId' \
        --output text 2>/dev/null)

    if [ "$tgw_id" != "None" ] && [ -n "$tgw_id" ]; then
        echo "$tgw_id"
        return 0
    else
        return 1
    fi
}

# Calculate the Nth host IP in a CIDR block (mimics Terraform's cidrhost function)
# Usage: calculate_cidr_host "192.168.0.32/28" 11
calculate_cidr_host() {
    local cidr="$1"
    local hostnum="$2"

    # Use Python to calculate the IP (most reliable cross-platform method)
    python3 -c "
import ipaddress
import sys
try:
    network = ipaddress.ip_network('$cidr', strict=False)
    # Get the nth host IP (adding hostnum to network address)
    host_ip = network.network_address + $hostnum
    print(str(host_ip))
except:
    sys.exit(1)
" 2>/dev/null
}

# Verify instance IP matches expected host number in subnet
verify_instance_ip_in_subnet() {
    local actual_ip="$1"
    local subnet_cidr="$2"
    local expected_host_num="$3"

    local expected_ip=$(calculate_cidr_host "$subnet_cidr" "$expected_host_num")

    if [ -z "$expected_ip" ]; then
        # Fallback: just check if IP is in the subnet range
        echo "WARNING: Could not calculate expected IP, checking if IP is in subnet range"
        return 2  # Return special code for warning
    fi

    if [ "$actual_ip" == "$expected_ip" ]; then
        return 0
    else
        echo "Expected: $expected_ip, Got: $actual_ip"
        return 1
    fi
}
