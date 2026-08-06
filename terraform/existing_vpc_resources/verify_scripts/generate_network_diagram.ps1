#requires -Version 5.1
<#
.SYNOPSIS
    Generate Network Diagram Script (PowerShell port of generate_network_diagram.sh)

.DESCRIPTION
    Creates an SVG network diagram and markdown documentation based on deployed
    infrastructure, using the AWS CLI. Faithful port of the bash original --
    same AWS CLI filters/queries, same SVG layout/coordinates, same markdown
    structure, same --fortigates-only fast path.

.EXAMPLE
    .\generate_network_diagram.ps1                  # Full regeneration of SVG and MD
.EXAMPLE
    .\generate_network_diagram.ps1 -FortiGatesOnly  # Only update FortiGate IPs in existing MD
#>

param(
    [switch]$FortiGatesOnly,
    [Alias('h')]
    [switch]$Help,
    # Catches any stray positional arguments so we can emulate bash's
    # "Unknown option: $1" + exit 1 behavior instead of letting PowerShell's
    # own parameter binder throw an uncontrolled error.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$UnknownArgs
)

# bash: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
$SCRIPT_DIR = $PSScriptRoot

# bash: source "${SCRIPT_DIR}/common_functions.sh"
. (Join-Path $SCRIPT_DIR 'common_functions.ps1')

# ---------------------------------------------------------------------------
# Argument parsing (bash: while [[ $# -gt 0 ]]; do case $1 in ... esac; done)
# ---------------------------------------------------------------------------
if ($UnknownArgs -and $UnknownArgs.Count -gt 0) {
    Write-Host "Unknown option: $($UnknownArgs[0])"
    exit 1
}

if ($Help) {
    Write-Host "Usage: $($MyInvocation.MyCommand.Name) [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -FortiGatesOnly     Only update FortiGate instance IPs in existing network_diagram.md"
    Write-Host "  -Help, -h           Show this help message"
    exit 0
}

# ===========================================================================
# Small local AWS CLI wrapper helpers (not part of common_functions.ps1 --
# these are specific to how this script shapes its AWS CLI calls).
# ===========================================================================

function Invoke-AwsText {
    # Runs `aws <Arguments> --output text`, trims the result, and maps the
    # literal string "None" to "" -- mirrors the many `[ "$X" == "None" ] &&
    # X=""` guards scattered through the bash original. We apply this
    # mapping universally (bash only applied it to some variables) as a
    # deliberate, minor robustness improvement -- see PORTING NOTES at the
    # bottom of this file.
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $raw = & aws @Arguments --output text 2>$null
    if ($null -eq $raw) { return "" }
    $joined = ($raw -join "`n").Trim()
    if ($joined -ceq 'None') { return "" }
    return $joined
}

function Invoke-AwsJsonArray {
    # Runs `aws <Arguments> --output json` and parses the result with
    # ConvertFrom-Json (no jq dependency). Always returns a PowerShell array
    # (possibly empty) so callers can safely use .Count without null checks.
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $rawLines = & aws @Arguments --output json 2>$null
    if ($null -eq $rawLines) { return @() }
    $raw = ($rawLines -join "`n")
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return @()
    }
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function Get-ColumnValue {
    # bash: `echo "$TEXT" | awk '$1==<Match> {print $2}'` equivalent.
    # Scans whitespace-separated rows of $Text and returns column $ColumnIndex
    # (0-based) of the first row whose column 0 equals $MatchFirstColumn.
    param(
        [string]$Text,
        [string]$MatchFirstColumn,
        [int]$ColumnIndex
    )
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    foreach ($line in ($Text -split "`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        $cols = @($trimmed -split '\s+')
        if ($cols.Length -gt $ColumnIndex -and $cols[0] -ceq $MatchFirstColumn) {
            return $cols[$ColumnIndex]
        }
    }
    return ""
}

function Get-FortiGateAsgData {
    # Ports the three FortiGate-instance discovery queries and their
    # dedup-by-first-nonempty-result semantics, shared by both the
    # -FortiGatesOnly fast path and the full generation path (bash duplicates
    # this logic literally in both places; we factor it out once here).
    param(
        [Parameter(Mandatory = $true)][string]$Region,
        [string]$InspectionVpcId
    )

    $queryExpr = "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId,PrivateIpAddress,NetworkInterfaces[*].Association.PublicIp|[?@]|[0],Tags[?Key=='Autoscale Role'].Value|[0]]"

    $json1 = Invoke-AwsJsonArray -Arguments @(
        'ec2', 'describe-instances', '--region', $Region,
        '--filters', 'Name=instance-state-name,Values=running', 'Name=tag:Name,Values=*fortigate*',
        '--query', $queryExpr
    )
    $json2 = Invoke-AwsJsonArray -Arguments @(
        'ec2', 'describe-instances', '--region', $Region,
        '--filters', 'Name=instance-state-name,Values=running', 'Name=tag:Name,Values=*fgt*asg*',
        '--query', $queryExpr
    )

    if (-not [string]::IsNullOrEmpty($InspectionVpcId)) {
        $json3 = Invoke-AwsJsonArray -Arguments @(
            'ec2', 'describe-instances', '--region', $Region,
            '--filters', 'Name=instance-state-name,Values=running', "Name=vpc-id,Values=$InspectionVpcId", 'Name=tag:Name,Values=*fgt*',
            '--query', $queryExpr
        )
    } else {
        $json3 = @()
    }

    $count = 0
    $rows = New-Object System.Collections.Generic.List[string]

    foreach ($jsonSet in @($json1, $json2, $json3)) {
        if ($count -eq 0 -and $jsonSet.Count -gt 0) {
            foreach ($item in $jsonSet) {
                $fgtName = $item[0]
                $fgtId = $item[1]
                $fgtPrivate = $item[2]
                $fgtPublic = $item[3]
                $fgtRole = $item[4]

                if (-not [string]::IsNullOrEmpty($fgtName) -and $fgtName -cne 'null') {
                    if ([string]::IsNullOrEmpty($fgtPublic) -or $fgtPublic -ceq 'null') { $fgtPublic = 'N/A' }
                    if ([string]::IsNullOrEmpty($fgtRole) -or $fgtRole -ceq 'null') { $fgtRole = '-' }
                    $rows.Add("| $fgtName | $fgtId | $fgtRole | $fgtPrivate | $fgtPublic |")
                    $count++
                }
            }
        }
    }

    return [pscustomobject]@{ Count = $count; Rows = $rows }
}

# ---------------------------------------------------------------------------
# Paths (bash: TERRAFORM_DIR / TFVARS_FILE / REPO_ROOT / OUTPUT_DIR)
# Resolved from $PSScriptRoot, NOT the current working directory.
# Repo root = three levels up from verify_scripts.
# ---------------------------------------------------------------------------
$TERRAFORM_DIR = Split-Path -Path $SCRIPT_DIR -Parent
$TFVARS_FILE = Join-Path $TERRAFORM_DIR 'terraform.tfvars'

$REPO_ROOT = Split-Path -Path (Split-Path -Path $TERRAFORM_DIR -Parent) -Parent
$OUTPUT_DIR = Join-Path $REPO_ROOT 'logs'

New-Item -ItemType Directory -Force -Path $OUTPUT_DIR | Out-Null

$SVG_FILE = Join-Path $OUTPUT_DIR 'network_diagram.svg'
$MD_FILE = Join-Path $OUTPUT_DIR 'network_diagram.md'

$TIMESTAMP = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$DATE_ONLY = Get-Date -Format 'yyyy-MM-dd'   # unused downstream, kept for parity with bash

Write-Section "GENERATING NETWORK DIAGRAM"

if (-not (Test-Path -LiteralPath $TFVARS_FILE -PathType Leaf)) {
    Write-Fail "terraform.tfvars not found: $TFVARS_FILE"
    exit 1
}

# ---------------------------------------------------------------------------
# Read configuration
# ---------------------------------------------------------------------------
$AWS_REGION = Get-TfVar -VarName 'aws_region' -TfvarsFile $TFVARS_FILE
$AZ1 = Get-TfVar -VarName 'availability_zone_1' -TfvarsFile $TFVARS_FILE
$AZ2 = Get-TfVar -VarName 'availability_zone_2' -TfvarsFile $TFVARS_FILE
$AZ3 = Get-TfVar -VarName 'availability_zone_3' -TfvarsFile $TFVARS_FILE
$CP = Get-TfVar -VarName 'cp' -TfvarsFile $TFVARS_FILE
$ENV = Get-TfVar -VarName 'env' -TfvarsFile $TFVARS_FILE
$PREFIX = "$CP-$ENV"

if (-not [string]::IsNullOrEmpty($AZ3)) {
    $AZ_LABEL = "$AZ1, $AZ2 + AZ3 ($AZ3) ACTIVE"
} else {
    $AZ_LABEL = "$AZ1, $AZ2"
}

# VPC CIDRs
$VPC_CIDR_MANAGEMENT = Get-TfVar -VarName 'vpc_cidr_management' -TfvarsFile $TFVARS_FILE
$VPC_CIDR_INSPECTION = Get-TfVar -VarName 'vpc_cidr_inspection' -TfvarsFile $TFVARS_FILE
$VPC_CIDR_EAST = Get-TfVar -VarName 'vpc_cidr_east' -TfvarsFile $TFVARS_FILE
$VPC_CIDR_WEST = Get-TfVar -VarName 'vpc_cidr_west' -TfvarsFile $TFVARS_FILE

# Deployment mode
$ENABLE_AUTOSCALE = Get-TfVar -VarName 'enable_autoscale_deployment' -TfvarsFile $TFVARS_FILE
$ENABLE_HA_PAIR = Get-TfVar -VarName 'enable_ha_pair_deployment' -TfvarsFile $TFVARS_FILE
$ENABLE_BUILD_MGMT = Get-TfVar -VarName 'enable_build_management_vpc' -TfvarsFile $TFVARS_FILE
$ENABLE_BUILD_SPOKES = Get-TfVar -VarName 'enable_build_existing_subnets' -TfvarsFile $TFVARS_FILE

# Distributed VPCs
$ENABLE_DISTRIBUTED = Get-TfVar -VarName 'enable_distributed_egress_vpcs' -TfvarsFile $TFVARS_FILE
$DISTRIBUTED_COUNT = Get-TfVar -VarName 'distributed_egress_vpc_count' -TfvarsFile $TFVARS_FILE
$DISTRIBUTED_VPC_1_CIDR = Get-TfVar -VarName 'distributed_egress_vpc_1_cidr' -TfvarsFile $TFVARS_FILE

# FortiTester settings
$ENABLE_FORTITESTER_1 = Get-TfVar -VarName 'enable_fortitester_1' -TfvarsFile $TFVARS_FILE
$ENABLE_FORTITESTER_2 = Get-TfVar -VarName 'enable_fortitester_2' -TfvarsFile $TFVARS_FILE

# Read FortiManager settings from autoscale_template tfvars (if it exists)
$AUTOSCALE_TFVARS_FILE = Join-Path $TERRAFORM_DIR '..\autoscale_template\terraform.tfvars'
if (Test-Path -LiteralPath $AUTOSCALE_TFVARS_FILE -PathType Leaf) {
    $ENABLE_FMG_INTEGRATION = Get-TfVar -VarName 'enable_fortimanager_integration' -TfvarsFile $AUTOSCALE_TFVARS_FILE
    $FORTIMANAGER_IP = Get-TfVar -VarName 'fortimanager_ip' -TfvarsFile $AUTOSCALE_TFVARS_FILE
    $FORTIMANAGER_SN = Get-TfVar -VarName 'fortimanager_sn' -TfvarsFile $AUTOSCALE_TFVARS_FILE
    $FGT_PASSWORD = Get-TfVar -VarName 'fortigate_asg_password' -TfvarsFile $AUTOSCALE_TFVARS_FILE
} else {
    $ENABLE_FMG_INTEGRATION = 'false'
    $FORTIMANAGER_IP = ''
    $FORTIMANAGER_SN = ''
    $FGT_PASSWORD = ''
}

Write-Info "Region: $AWS_REGION"
Write-Info "Resource Prefix: $PREFIX"
Write-Info "Output Directory: $OUTPUT_DIR"

# ===========================================================================
# FORTIGATES-ONLY MODE: Quick update of just FortiGate IPs in existing MD file
# ===========================================================================
if ($FortiGatesOnly) {
    Write-Section "UPDATING FORTIGATE IPS ONLY"

    if (-not (Test-Path -LiteralPath $MD_FILE -PathType Leaf)) {
        Write-Fail "network_diagram.md not found: $MD_FILE"
        Write-Info "Run without -FortiGatesOnly first to generate the full diagram"
        exit 1
    }

    # Get inspection VPC ID for the third query
    $INSPECTION_VPC_ID_FAST = Invoke-AwsText -Arguments @(
        'ec2', 'describe-vpcs', '--region', $AWS_REGION,
        '--filters', "Name=tag:Name,Values=$PREFIX-inspection-vpc",
        '--query', 'Vpcs[0].VpcId'
    )

    Write-Info "Querying FortiGate ASG instances..."

    $fgtData = Get-FortiGateAsgData -Region $AWS_REGION -InspectionVpcId $INSPECTION_VPC_ID_FAST

    if ($fgtData.Count -gt 0) {
        Write-Pass "Found $($fgtData.Count) FortiGate instance(s)"

        # Build the table text the way bash does via `echo -e "$TABLE"` fed
        # into a command substitution: rows joined by real newlines, then all
        # TRAILING newlines stripped (command substitution semantics) before
        # the literal "> **Note:**..." text is appended directly after -- this
        # reproduces the bash fast-path's exact concatenation behavior.
        $tableText = ($fgtData.Rows -join "`n")
        # each row conceptually ends with its own newline in bash; TrimEnd
        # below removes exactly that trailing run, same as $(...) would.
        $tableTextNoTrailingNl = $tableText.TrimEnd("`n")

        $NEW_FGT_SECTION = "### FortiGate AutoScale Group Instances`n`n| Instance Name | Instance ID | Role | Private IP | Public IP (Management) |`n|--------------|-------------|------|------------|------------------------|`n" + $tableTextNoTrailingNl + "> **Note:** FortiGate management interfaces are accessible via their public IPs. Use ``admin`` as username with the configured password. The **Primary** instance holds the configuration that is synced to Secondary instances."

        # awk-equivalent section replace: find "### FortiGate AutoScale Group
        # Instances", replace through (not including) the next /^(###|---)/ or EOF.
        $mdLines = @(Get-Content -LiteralPath $MD_FILE)
        $outLines = New-Object System.Collections.Generic.List[string]
        $inFgtSection = $false
        $sectionInserted = $false

        foreach ($line in $mdLines) {
            if (-not $sectionInserted -and $line -match '^### FortiGate AutoScale Group Instances') {
                $outLines.Add($NEW_FGT_SECTION)
                $inFgtSection = $true
                $sectionInserted = $true
                continue
            }
            if ($inFgtSection -and ($line -match '^(###|---)')) {
                $inFgtSection = $false
            }
            if (-not $inFgtSection) {
                $outLines.Add($line)
            }
        }

        $finalText = ($outLines -join "`n") + "`n"
        [System.IO.File]::WriteAllText($MD_FILE, $finalText, (New-Object System.Text.UTF8Encoding($false)))

        Write-Pass "Updated FortiGate section in: $MD_FILE"
    } else {
        Write-Info "No FortiGate ASG instances found"
    }

    Write-Host ""
    exit 0
}

# ===========================================================================
# FULL GENERATION PATH
# ===========================================================================

# ---------------------------------------------------------------------------
# Collect VPC IDs
# ---------------------------------------------------------------------------
$MGMT_VPC_ID = Invoke-AwsText -Arguments @('ec2', 'describe-vpcs', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-vpc", '--query', 'Vpcs[0].VpcId')
$INSPECTION_VPC_ID = Invoke-AwsText -Arguments @('ec2', 'describe-vpcs', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-vpc", '--query', 'Vpcs[0].VpcId')
$EAST_VPC_ID = Invoke-AwsText -Arguments @('ec2', 'describe-vpcs', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-east-vpc", '--query', 'Vpcs[0].VpcId')
$WEST_VPC_ID = Invoke-AwsText -Arguments @('ec2', 'describe-vpcs', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-west-vpc", '--query', 'Vpcs[0].VpcId')

# Get TGW ID
$TGW_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateways', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-tgw", 'Name=state,Values=available', '--query', 'TransitGateways[0].TransitGatewayId')

# Get TGW attachment IDs (requires VPC IDs and TGW ID to be set first)
$MGMT_TGW_ATTACH_ID = ''
$INSP_TGW_ATTACH_ID = ''
$EAST_TGW_ATTACH_ID = ''
$WEST_TGW_ATTACH_ID = ''
if (-not [string]::IsNullOrEmpty($TGW_ID)) {
    if (-not [string]::IsNullOrEmpty($MGMT_VPC_ID)) {
        $MGMT_TGW_ATTACH_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateway-attachments', '--region', $AWS_REGION, '--filters', "Name=transit-gateway-id,Values=$TGW_ID", "Name=resource-id,Values=$MGMT_VPC_ID", '--query', 'TransitGatewayAttachments[0].TransitGatewayAttachmentId')
    }
    if (-not [string]::IsNullOrEmpty($INSPECTION_VPC_ID)) {
        $INSP_TGW_ATTACH_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateway-attachments', '--region', $AWS_REGION, '--filters', "Name=transit-gateway-id,Values=$TGW_ID", "Name=resource-id,Values=$INSPECTION_VPC_ID", '--query', 'TransitGatewayAttachments[0].TransitGatewayAttachmentId')
    }
    if (-not [string]::IsNullOrEmpty($EAST_VPC_ID)) {
        $EAST_TGW_ATTACH_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateway-attachments', '--region', $AWS_REGION, '--filters', "Name=transit-gateway-id,Values=$TGW_ID", "Name=resource-id,Values=$EAST_VPC_ID", '--query', 'TransitGatewayAttachments[0].TransitGatewayAttachmentId')
    }
    if (-not [string]::IsNullOrEmpty($WEST_VPC_ID)) {
        $WEST_TGW_ATTACH_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateway-attachments', '--region', $AWS_REGION, '--filters', "Name=transit-gateway-id,Values=$TGW_ID", "Name=resource-id,Values=$WEST_VPC_ID", '--query', 'TransitGatewayAttachments[0].TransitGatewayAttachmentId')
    }
}

# bash: get_subnet_info() -- defined in the original script but never
# actually called anywhere in it. Ported for 1:1 completeness; still unused.
function Get-SubnetInfo {
    param([string]$VpcId, [string]$SubnetNamePattern)
    return Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=vpc-id,Values=$VpcId", "Name=tag:Name,Values=*$SubnetNamePattern*", '--query', 'Subnets[0].[SubnetId,CidrBlock]')
}

Write-Info "Collecting instance information..."

# bash: get_instance_private_ip / get_instance_public_ip / get_instance_id
# These are LOCAL overrides defined by generate_network_diagram.sh itself,
# which intentionally shadow the differently-shaped versions of the first two
# already defined by common_functions.sh (those take instance ID + region;
# these take an instance NAME and use the script's own $AWS_REGION). We
# reproduce that same shadowing here by redefining the same function names
# after dot-sourcing common_functions.ps1.
function Get-InstancePrivateIp {
    param([string]$InstanceName)
    return Invoke-AwsText -Arguments @('ec2', 'describe-instances', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$InstanceName", 'Name=instance-state-name,Values=running', '--query', 'Reservations[0].Instances[0].PrivateIpAddress')
}

function Get-InstancePublicIp {
    param([string]$InstanceName)
    return Invoke-AwsText -Arguments @('ec2', 'describe-instances', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$InstanceName", 'Name=instance-state-name,Values=running', '--query', 'Reservations[0].Instances[0].PublicIpAddress')
}

function Get-InstanceId {
    param([string]$InstanceName)
    return Invoke-AwsText -Arguments @('ec2', 'describe-instances', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$InstanceName", 'Name=instance-state-name,Values=running', '--query', 'Reservations[0].Instances[0].InstanceId')
}

# ---------------------------------------------------------------------------
# Get subnet CIDRs for each VPC
# ---------------------------------------------------------------------------
# Management VPC
$MGMT_PUBLIC_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-public-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$MGMT_PUBLIC_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-public-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$MGMT_PRIVATE_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-private-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$MGMT_PRIVATE_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-private-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$MGMT_PUBLIC_AZ3_CIDR = ''
$MGMT_PRIVATE_AZ3_CIDR = ''
if (-not [string]::IsNullOrEmpty($AZ3)) {
    $MGMT_PUBLIC_AZ3_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-public-az3-subnet", '--query', 'Subnets[0].CidrBlock')
    $MGMT_PRIVATE_AZ3_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-management-private-az3-subnet", '--query', 'Subnets[0].CidrBlock')
}

# Inspection VPC
$INSP_PUBLIC_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-public-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_PUBLIC_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-public-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_GWLBE_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-gwlbe-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_GWLBE_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-gwlbe-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_PRIVATE_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-private-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_PRIVATE_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-private-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_NATGW_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-natgw-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_NATGW_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-natgw-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_TGW_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-tgw-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$INSP_TGW_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-tgw-az2-subnet", '--query', 'Subnets[0].CidrBlock')

# Inspection VPC Management subnets (dedicated management ENI, conditional)
$CREATE_MGMT_INSP = Get-TfVar -VarName 'create_management_subnet_in_inspection_vpc' -TfvarsFile $TFVARS_FILE
$INSP_MGMT_AZ1_CIDR = ''
$INSP_MGMT_AZ2_CIDR = ''
$INSP_MGMT_AZ3_CIDR = ''
if (Test-TfVarTrue -VarName 'create_management_subnet_in_inspection_vpc' -TfvarsFile $TFVARS_FILE) {
    $INSP_MGMT_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-management-az1-subnet", '--query', 'Subnets[0].CidrBlock')
    $INSP_MGMT_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-management-az2-subnet", '--query', 'Subnets[0].CidrBlock')
    if (-not [string]::IsNullOrEmpty($AZ3)) {
        $INSP_MGMT_AZ3_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-inspection-management-az3-subnet", '--query', 'Subnets[0].CidrBlock')
    }
}

# GWLB Endpoints (created by autoscale_template)
# Note: These use truncated prefix like "dis-p-asg" instead of full "dis-poc"
$GWLBE_AZ1_ID = Invoke-AwsText -Arguments @('ec2', 'describe-vpc-endpoints', '--region', $AWS_REGION, '--filters', 'Name=vpc-endpoint-type,Values=GatewayLoadBalancer', 'Name=tag:Name,Values=*gwlbe_az1*', '--query', 'VpcEndpoints[0].VpcEndpointId')
$GWLBE_AZ2_ID = Invoke-AwsText -Arguments @('ec2', 'describe-vpc-endpoints', '--region', $AWS_REGION, '--filters', 'Name=vpc-endpoint-type,Values=GatewayLoadBalancer', 'Name=tag:Name,Values=*gwlbe_az2*', '--query', 'VpcEndpoints[0].VpcEndpointId')

# East VPC
$EAST_PUBLIC_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-east-public-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$EAST_PUBLIC_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-east-public-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$EAST_TGW_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-east-tgw-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$EAST_TGW_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-east-tgw-az2-subnet", '--query', 'Subnets[0].CidrBlock')

# West VPC
$WEST_PUBLIC_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-west-public-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$WEST_PUBLIC_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-west-public-az2-subnet", '--query', 'Subnets[0].CidrBlock')
$WEST_TGW_AZ1_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-west-tgw-az1-subnet", '--query', 'Subnets[0].CidrBlock')
$WEST_TGW_AZ2_CIDR = Invoke-AwsText -Arguments @('ec2', 'describe-subnets', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-west-tgw-az2-subnet", '--query', 'Subnets[0].CidrBlock')

# ---------------------------------------------------------------------------
# Instance IPs
# ---------------------------------------------------------------------------
$JUMP_BOX_NAME = "$PREFIX-jump-box"
$JUMP_BOX_PRIVATE = Get-InstancePrivateIp -InstanceName $JUMP_BOX_NAME
$JUMP_BOX_PUBLIC = Get-InstancePublicIp -InstanceName $JUMP_BOX_NAME
$JUMP_BOX_ID = Get-InstanceId -InstanceName $JUMP_BOX_NAME

$EAST_AZ1_NAME = "$PREFIX-east-public-az1-instance"
$EAST_AZ1_PRIVATE = Get-InstancePrivateIp -InstanceName $EAST_AZ1_NAME

$EAST_AZ2_NAME = "$PREFIX-east-public-az2-instance"
$EAST_AZ2_PRIVATE = Get-InstancePrivateIp -InstanceName $EAST_AZ2_NAME

$WEST_AZ1_NAME = "$PREFIX-west-public-az1-instance"
$WEST_AZ1_PRIVATE = Get-InstancePrivateIp -InstanceName $WEST_AZ1_NAME

$WEST_AZ2_NAME = "$PREFIX-west-public-az2-instance"
$WEST_AZ2_PRIVATE = Get-InstancePrivateIp -InstanceName $WEST_AZ2_NAME

# Distributed VPC instances
$DIST1_AZ1_NAME = "$PREFIX-distributed-1-instance-az1"
$DIST1_AZ1_PRIVATE = Get-InstancePrivateIp -InstanceName $DIST1_AZ1_NAME
$DIST1_AZ1_PUBLIC = Get-InstancePublicIp -InstanceName $DIST1_AZ1_NAME
$DIST1_AZ1_ID = Get-InstanceId -InstanceName $DIST1_AZ1_NAME

$DIST1_AZ2_NAME = "$PREFIX-distributed-1-instance-az2"
$DIST1_AZ2_PRIVATE = Get-InstancePrivateIp -InstanceName $DIST1_AZ2_NAME
$DIST1_AZ2_PUBLIC = Get-InstancePublicIp -InstanceName $DIST1_AZ2_NAME
$DIST1_AZ2_ID = Get-InstanceId -InstanceName $DIST1_AZ2_NAME

# FortiTester instances
$FORTITESTER_1_NAME = "$PREFIX-fortitester-1"
$FORTITESTER_1_PRIVATE = Get-InstancePrivateIp -InstanceName $FORTITESTER_1_NAME
$FORTITESTER_1_PUBLIC = Get-InstancePublicIp -InstanceName $FORTITESTER_1_NAME
$FORTITESTER_1_ID = Get-InstanceId -InstanceName $FORTITESTER_1_NAME

$FORTITESTER_2_NAME = "$PREFIX-fortitester-2"
$FORTITESTER_2_PRIVATE = Get-InstancePrivateIp -InstanceName $FORTITESTER_2_NAME
$FORTITESTER_2_PUBLIC = Get-InstancePublicIp -InstanceName $FORTITESTER_2_NAME
$FORTITESTER_2_ID = Get-InstanceId -InstanceName $FORTITESTER_2_NAME

# Get FortiTester ENI IPs for port2 and port3
# FortiTester 1: Port1 in Mgmt AZ1, Port2 in East AZ1, Port3 in West AZ1
# FortiTester 2: Port1 in Mgmt AZ2, Port2 in West AZ2, Port3 in East AZ2
$FORTITESTER_1_PORT2_IP = ''
$FORTITESTER_1_PORT3_IP = ''
if (-not [string]::IsNullOrEmpty($FORTITESTER_1_PRIVATE)) {
    $FT1_INSTANCE_ID = Invoke-AwsText -Arguments @('ec2', 'describe-instances', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$FORTITESTER_1_NAME", 'Name=instance-state-name,Values=running', '--query', 'Reservations[0].Instances[0].InstanceId')
    if (-not [string]::IsNullOrEmpty($FT1_INSTANCE_ID)) {
        $FT1_ENIS = Invoke-AwsText -Arguments @('ec2', 'describe-network-interfaces', '--region', $AWS_REGION, '--filters', "Name=attachment.instance-id,Values=$FT1_INSTANCE_ID", '--query', 'NetworkInterfaces[*].[Attachment.DeviceIndex,PrivateIpAddress]')
        $FORTITESTER_1_PORT2_IP = Get-ColumnValue -Text $FT1_ENIS -MatchFirstColumn '1' -ColumnIndex 1
        $FORTITESTER_1_PORT3_IP = Get-ColumnValue -Text $FT1_ENIS -MatchFirstColumn '2' -ColumnIndex 1
    }
}

$FORTITESTER_2_PORT2_IP = ''
$FORTITESTER_2_PORT3_IP = ''
if (-not [string]::IsNullOrEmpty($FORTITESTER_2_PRIVATE)) {
    $FT2_INSTANCE_ID = Invoke-AwsText -Arguments @('ec2', 'describe-instances', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$FORTITESTER_2_NAME", 'Name=instance-state-name,Values=running', '--query', 'Reservations[0].Instances[0].InstanceId')
    if (-not [string]::IsNullOrEmpty($FT2_INSTANCE_ID)) {
        $FT2_ENIS = Invoke-AwsText -Arguments @('ec2', 'describe-network-interfaces', '--region', $AWS_REGION, '--filters', "Name=attachment.instance-id,Values=$FT2_INSTANCE_ID", '--query', 'NetworkInterfaces[*].[Attachment.DeviceIndex,PrivateIpAddress]')
        $FORTITESTER_2_PORT2_IP = Get-ColumnValue -Text $FT2_ENIS -MatchFirstColumn '1' -ColumnIndex 1
        $FORTITESTER_2_PORT3_IP = Get-ColumnValue -Text $FT2_ENIS -MatchFirstColumn '2' -ColumnIndex 1
    }
}

# ---------------------------------------------------------------------------
# Query FortiGate ASG instances (if deployed)
# ---------------------------------------------------------------------------
Write-Info "Checking for FortiGate ASG instances..."
$fgtData = Get-FortiGateAsgData -Region $AWS_REGION -InspectionVpcId $INSPECTION_VPC_ID
$FORTIGATE_COUNT = $fgtData.Count
$FORTIGATE_MD_TABLE = ''
if ($fgtData.Rows.Count -gt 0) {
    $FORTIGATE_MD_TABLE = ($fgtData.Rows -join "`n") + "`n"
}

if ($FORTIGATE_COUNT -gt 0) {
    Write-Pass "Found $FORTIGATE_COUNT FortiGate instance(s)"
    $FGT_SVG_STATUS = "($FORTIGATE_COUNT instance(s))"
    $FGT_SVG_STATUS_COLOR = '#007700'
    $FGT_LEGEND_TEXT = 'FortiGate ASG (deployed)'
    $FGT_DEPLOY_STATUS = "ASG deployed: $FORTIGATE_COUNT instance(s)"
    $FGT_DEPLOY_STATUS_COLOR = '#007700'
} else {
    Write-Info "No FortiGate ASG instances found (autoscale template not yet deployed)"
    $FGT_SVG_STATUS = '(Not Deployed)'
    $FGT_SVG_STATUS_COLOR = '#888'
    $FGT_LEGEND_TEXT = 'FortiGate ASG (not deployed)'
    $FGT_DEPLOY_STATUS = 'ASG not deployed yet'
    $FGT_DEPLOY_STATUS_COLOR = '#888'
}

# ---------------------------------------------------------------------------
# Check TGW route table status for East/West
# ---------------------------------------------------------------------------
$EAST_TGW_RT_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateway-route-tables', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-east-tgw-rtb", '--query', 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId')

$EAST_TGW_DEFAULT_ROUTE = 'No default route'
if (-not [string]::IsNullOrEmpty($EAST_TGW_RT_ID)) {
    $EAST_TGW_TARGET = Invoke-AwsText -Arguments @('ec2', 'search-transit-gateway-routes', '--region', $AWS_REGION, '--transit-gateway-route-table-id', $EAST_TGW_RT_ID, '--filters', 'Name=type,Values=static', '--query', "Routes[?DestinationCidrBlock=='0.0.0.0/0'].TransitGatewayAttachments[0].TransitGatewayAttachmentId")
    if (-not [string]::IsNullOrEmpty($EAST_TGW_TARGET)) { $EAST_TGW_DEFAULT_ROUTE = $EAST_TGW_TARGET }
}

$WEST_TGW_RT_ID = Invoke-AwsText -Arguments @('ec2', 'describe-transit-gateway-route-tables', '--region', $AWS_REGION, '--filters', "Name=tag:Name,Values=$PREFIX-west-tgw-rtb", '--query', 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId')

$WEST_TGW_DEFAULT_ROUTE = 'No default route'
if (-not [string]::IsNullOrEmpty($WEST_TGW_RT_ID)) {
    $WEST_TGW_TARGET = Invoke-AwsText -Arguments @('ec2', 'search-transit-gateway-routes', '--region', $AWS_REGION, '--transit-gateway-route-table-id', $WEST_TGW_RT_ID, '--filters', 'Name=type,Values=static', '--query', "Routes[?DestinationCidrBlock=='0.0.0.0/0'].TransitGatewayAttachments[0].TransitGatewayAttachmentId")
    if (-not [string]::IsNullOrEmpty($WEST_TGW_TARGET)) { $WEST_TGW_DEFAULT_ROUTE = $WEST_TGW_TARGET }
}

# Determine deployment mode text
$DEPLOY_MODE = 'Autoscale'
if ($ENABLE_HA_PAIR -ceq 'true') { $DEPLOY_MODE = 'HA Pair' }

# Determine route status color/text
$ROUTE_STATUS_COLOR = '#FF4444'
$ROUTE_STATUS_TEXT = 'Pending ASG'
if ($EAST_TGW_DEFAULT_ROUTE -cne 'No default route') {
    $ROUTE_STATUS_COLOR = '#00FF00'
    $ROUTE_STATUS_TEXT = 'Active'
}

Write-Info "Generating SVG diagram..."

# ---------------------------------------------------------------------------
# Layout variables — adjust VPC heights and TGW positions based on optional subnets
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($AZ3)) {
    $MGMT_VPC_HEIGHT = 540
    $MGMT_TGW_Y = 630
} else {
    $MGMT_VPC_HEIGHT = 450
    $MGMT_TGW_Y = 570
}
$MGMT_TGW_CONNECT_Y = $MGMT_TGW_Y + 42

if ($CREATE_MGMT_INSP -ceq 'true') {
    $INSP_VPC_HEIGHT = 620
    $INSP_TGW_Y = 735
} else {
    $INSP_VPC_HEIGHT = 600
    $INSP_TGW_Y = 650
}
$INSP_TGW_CONNECT_Y = $INSP_TGW_Y + 42

# ---------------------------------------------------------------------------
# Precomputed "display" values for bash ${VAR:-default} substitutions
# (bash's :- applies the default when the var is unset OR empty)
# ---------------------------------------------------------------------------
function Get-Displayed {
    param([string]$Value, [string]$Default)
    if ([string]::IsNullOrEmpty($Value)) { return $Default }
    return $Value
}

$GWLBE_AZ1_ID_DISP = Get-Displayed -Value $GWLBE_AZ1_ID -Default 'not deployed'
$GWLBE_AZ2_ID_DISP = Get-Displayed -Value $GWLBE_AZ2_ID -Default 'not deployed'
$FORTITESTER_1_PUBLIC_DISP = Get-Displayed -Value $FORTITESTER_1_PUBLIC -Default 'N/A'
$FORTITESTER_1_PORT2_DISP = Get-Displayed -Value $FORTITESTER_1_PORT2_IP -Default 'N/A'
$FORTITESTER_1_PORT3_DISP = Get-Displayed -Value $FORTITESTER_1_PORT3_IP -Default 'N/A'
$FORTITESTER_2_PUBLIC_DISP = Get-Displayed -Value $FORTITESTER_2_PUBLIC -Default 'N/A'
$FORTITESTER_2_PORT2_DISP = Get-Displayed -Value $FORTITESTER_2_PORT2_IP -Default 'N/A'
$FORTITESTER_2_PORT3_DISP = Get-Displayed -Value $FORTITESTER_2_PORT3_IP -Default 'N/A'
$FORTIMANAGER_SN_DISP = Get-Displayed -Value $FORTIMANAGER_SN -Default 'N/A'
$FORTITESTER_1_ID_DISP = Get-Displayed -Value $FORTITESTER_1_ID -Default 'N/A'
$FORTITESTER_2_ID_DISP = Get-Displayed -Value $FORTITESTER_2_ID -Default 'N/A'

# ===========================================================================
# Generate SVG
# ===========================================================================
$svg = New-Object System.Text.StringBuilder

# ---- Block A: header/defs/gradients/background/title (always) ----
[void]$svg.Append(@"
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2200 1400" font-family="Arial, sans-serif">
  <defs>
    <!-- Gradients -->
    <linearGradient id="greenGradient" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#C8E6C9;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#A5D6A7;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="blueGradient" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#BBDEFB;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#90CAF9;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="purpleGradient" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#E1BEE7;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#CE93D8;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="orangeGradient" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#FFE0B2;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#FFCC80;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="redGradient" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#FFCDD2;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#EF9A9A;stop-opacity:1" />
    </linearGradient>
  </defs>

  <!-- Background -->
  <rect width="2200" height="1400" fill="white"/>

  <!-- Title -->
  <text x="1100" y="55" text-anchor="middle" fill="#111111" font-size="32" font-weight="bold">${PREFIX} Infrastructure - ${AWS_REGION} (AZ: ${AZ_LABEL})</text>
  <text x="1100" y="90" text-anchor="middle" fill="#444444" font-size="18">Generated: ${TIMESTAMP} | Template: existing_vpc_resources</text>

  <!-- Internet Gateway Icons -->

"@) | Out-Null

# ---- Block B: Management VPC IGW (only if ENABLE_BUILD_MGMT) ----
if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$svg.Append(@"
  <!-- Management VPC IGW -->
  <rect x="280" y="115" width="120" height="48" rx="5" fill="#232F3E" stroke="#FF9900" stroke-width="2"/>
  <text x="340" y="146" text-anchor="middle" fill="#FF9900" font-size="18" font-weight="bold">IGW</text>
  <line x1="340" y1="163" x2="340" y2="190" stroke="#FF9900" stroke-width="2" stroke-dasharray="4,2"/>

"@)
}

# ---- Block C: Inspection VPC IGW (always) ----
[void]$svg.Append(@"
  <!-- Inspection VPC IGW -->
  <rect x="1680" y="115" width="120" height="48" rx="5" fill="#232F3E" stroke="#FF9900" stroke-width="2"/>
  <text x="1740" y="146" text-anchor="middle" fill="#FF9900" font-size="18" font-weight="bold">IGW</text>
  <line x1="1740" y1="163" x2="1740" y2="190" stroke="#FF9900" stroke-width="2" stroke-dasharray="4,2"/>


"@)

# ---- Block D: Management VPC box (only if ENABLE_BUILD_MGMT) ----
if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$svg.Append(@"
  <!-- ==================== MANAGEMENT VPC ==================== -->
  <rect x="60" y="190" width="600" height="$MGMT_VPC_HEIGHT" rx="10" fill="none" stroke="#3B48CC" stroke-width="3"/>
  <text x="85" y="230" fill="#111111" font-size="24" font-weight="bold">Management VPC</text>
  <text x="85" y="260" fill="#444444" font-size="17">${MGMT_VPC_ID} | ${VPC_CIDR_MANAGEMENT}</text>

  <!-- Management Public Subnets -->
  <rect x="90" y="290" width="250" height="145" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="215" y="325" text-anchor="middle" fill="#111111" font-size="18" font-weight="bold">Public AZ1</text>
  <text x="215" y="352" text-anchor="middle" fill="#111111" font-size="16">${MGMT_PUBLIC_AZ1_CIDR}</text>
  <!-- Jump Box -->
  <rect x="115" y="368" width="200" height="62" rx="3" fill="#232F3E" stroke="#FF9900" stroke-width="1"/>
  <text x="215" y="392" text-anchor="middle" fill="#FF9900" font-size="16">Jump Box</text>
  <text x="215" y="412" text-anchor="middle" fill="white" font-size="15">${JUMP_BOX_PRIVATE}</text>
  <text x="215" y="428" text-anchor="middle" fill="#90EE90" font-size="14">${JUMP_BOX_PUBLIC}</text>

  <rect x="370" y="290" width="250" height="145" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="495" y="325" text-anchor="middle" fill="#111111" font-size="18" font-weight="bold">Public AZ2</text>
  <text x="495" y="352" text-anchor="middle" fill="#111111" font-size="16">${MGMT_PUBLIC_AZ2_CIDR}</text>

  <!-- Management Private Subnets -->
  <rect x="90" y="460" width="250" height="85" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="215" y="500" text-anchor="middle" fill="#111111" font-size="18" font-weight="bold">Private AZ1</text>
  <text x="215" y="528" text-anchor="middle" fill="#111111" font-size="16">${MGMT_PRIVATE_AZ1_CIDR}</text>

  <rect x="370" y="460" width="250" height="85" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="495" y="500" text-anchor="middle" fill="#111111" font-size="18" font-weight="bold">Private AZ2</text>
  <text x="495" y="528" text-anchor="middle" fill="#111111" font-size="16">${MGMT_PRIVATE_AZ2_CIDR}</text>

"@)

    if (-not [string]::IsNullOrEmpty($AZ3)) {
        [void]$svg.Append(@"
  <!-- Management AZ3 Subnets -->
  <rect x="90" y="555" width="250" height="65" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="215" y="580" text-anchor="middle" fill="#111111" font-size="15" font-weight="bold">Public AZ3</text>
  <text x="215" y="610" text-anchor="middle" fill="#111111" font-size="14">${MGMT_PUBLIC_AZ3_CIDR}</text>

  <rect x="370" y="555" width="250" height="65" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="495" y="580" text-anchor="middle" fill="#111111" font-size="15" font-weight="bold">Private AZ3</text>
  <text x="495" y="610" text-anchor="middle" fill="#111111" font-size="14">${MGMT_PRIVATE_AZ3_CIDR}</text>

"@)
    }

    [void]$svg.Append(@"
  <!-- Management TGW Connection indicator -->
  <rect x="240" y="$MGMT_TGW_Y" width="140" height="42" rx="3" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="310" y="$($MGMT_TGW_Y + 28)" text-anchor="middle" fill="#111111" font-size="16">TGW Attach</text>

"@)
}

# ---- Precompute conditional sub-blocks used inside Block E (Inspection VPC) ----
$AZ3_BANNER_BLOCK = ''
if (-not [string]::IsNullOrEmpty($AZ3)) {
    $AZ3_BANNER_BLOCK = @"
  <rect x="1020" y="210" width="260" height="28" rx="5" fill="#2E7D32"/>
  <text x="1150" y="229" text-anchor="middle" fill="#111111" font-size="14" font-weight="bold">⚡ 3-AZ ACTIVE: ${AWS_REGION}${AZ3}</text>
"@
}

$MGMT_ENI_BLOCK = ''
if ($CREATE_MGMT_INSP -ceq 'true') {
    $MGMT_ENI_BLOCK = @"
  <!-- Inspection Management Subnets - Row 4 (dedicated management ENI) -->
  <rect x="1050" y="638" width="160" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1130" y="665" text-anchor="middle" fill="#111111" font-size="14" font-weight="bold">Mgmt ENI AZ1</text>
  <text x="1130" y="690" text-anchor="middle" fill="#111111" font-size="13">${INSP_MGMT_AZ1_CIDR}</text>
  <text x="1130" y="710" text-anchor="middle" fill="#664400" font-size="12">port3 → IGW</text>

  <rect x="1225" y="638" width="160" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1305" y="665" text-anchor="middle" fill="#111111" font-size="14" font-weight="bold">Mgmt ENI AZ2</text>
  <text x="1305" y="690" text-anchor="middle" fill="#111111" font-size="13">${INSP_MGMT_AZ2_CIDR}</text>
  <text x="1305" y="710" text-anchor="middle" fill="#664400" font-size="12">port3 → IGW</text>
"@
}

$MGMT_ENI_AZ3_BLOCK = ''
if ($CREATE_MGMT_INSP -ceq 'true' -and -not [string]::IsNullOrEmpty($AZ3)) {
    $MGMT_ENI_AZ3_BLOCK = @"

  <rect x="1400" y="638" width="160" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1480" y="655" text-anchor="middle" fill="#111111" font-size="14" font-weight="bold">Mgmt ENI AZ3</text>
  <text x="1480" y="675" text-anchor="middle" fill="#111111" font-size="13">${INSP_MGMT_AZ3_CIDR}</text>
  <text x="1480" y="695" text-anchor="middle" fill="#664400" font-size="12">port3 → IGW</text>
  <text x="1480" y="712" text-anchor="middle" fill="#007700" font-size="11">⚡ AZ3</text>
"@
}

# ---- Block E: Inspection VPC box, FortiGate ASG box, subnets, ENI lines (always) ----
[void]$svg.Append(@"
  <!-- ==================== INSPECTION VPC ==================== -->
  <!-- Layout: FortiGate ASG (left) | Public, GWLBE, Private (middle) | NAT GW (right) | TGW Attach (bottom) -->
  <rect x="720" y="190" width="1420" height="$INSP_VPC_HEIGHT" rx="10" fill="none" stroke="#3B48CC" stroke-width="3"/>
  <text x="750" y="230" fill="#111111" font-size="24" font-weight="bold">Inspection VPC</text>
  <text x="750" y="260" fill="#444444" font-size="17">${INSPECTION_VPC_ID} | ${VPC_CIDR_INSPECTION}</text>
$AZ3_BANNER_BLOCK
  <!-- FortiGate ASG Box - LEFT SIDE -->
  <rect x="760" y="290" width="250" height="330" rx="5" fill="none" stroke="#EE3124" stroke-width="2" stroke-dasharray="5,5"/>
  <text x="885" y="330" text-anchor="middle" fill="#EE3124" font-size="22" font-weight="bold">FortiGate ASG</text>
  <text x="885" y="362" text-anchor="middle" fill="$FGT_SVG_STATUS_COLOR" font-size="17">${FGT_SVG_STATUS}</text>
  <text x="885" y="394" text-anchor="middle" fill="#444444" font-size="16">Mode: ${DEPLOY_MODE}</text>
  <!-- Port labels -->
  <text x="885" y="438" text-anchor="middle" fill="#2E8B2E" font-size="16">port1: Public</text>
  <text x="885" y="465" text-anchor="middle" fill="#ED7100" font-size="16">port2: GWLBE</text>
  <text x="885" y="492" text-anchor="middle" fill="#147EBA" font-size="16">port3: Mgmt VPC</text>
  <!-- GWLB indicator -->
  <rect x="800" y="520" width="170" height="42" rx="3" fill="#ED7100" opacity="0.8"/>
  <text x="885" y="548" text-anchor="middle" fill="#111111" font-size="16">GWLB</text>

  <!-- Public Subnets - Middle Column Row 1 -->
  <rect x="1050" y="290" width="210" height="100" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="1155" y="325" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Public AZ1</text>
  <text x="1155" y="352" text-anchor="middle" fill="#111111" font-size="15">${INSP_PUBLIC_AZ1_CIDR}</text>
  <text x="1155" y="378" text-anchor="middle" fill="#FF9900" font-size="14">0.0.0.0/0 -> NAT GW</text>

  <rect x="1280" y="290" width="210" height="100" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="1385" y="325" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Public AZ2</text>
  <text x="1385" y="352" text-anchor="middle" fill="#111111" font-size="15">${INSP_PUBLIC_AZ2_CIDR}</text>
  <text x="1385" y="378" text-anchor="middle" fill="#FF9900" font-size="14">0.0.0.0/0 -> NAT GW</text>

  <!-- GWLBE Subnets - Middle Column Row 2 -->
  <rect x="1050" y="408" width="210" height="100" rx="5" fill="url(#orangeGradient)" opacity="0.8"/>
  <text x="1155" y="438" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">GWLBE AZ1</text>
  <text x="1155" y="465" text-anchor="middle" fill="#111111" font-size="15">${INSP_GWLBE_AZ1_CIDR}</text>
  <text x="1155" y="492" text-anchor="middle" fill="#555555" font-size="13">${GWLBE_AZ1_ID_DISP}</text>

  <rect x="1280" y="408" width="210" height="100" rx="5" fill="url(#orangeGradient)" opacity="0.8"/>
  <text x="1385" y="438" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">GWLBE AZ2</text>
  <text x="1385" y="465" text-anchor="middle" fill="#111111" font-size="15">${INSP_GWLBE_AZ2_CIDR}</text>
  <text x="1385" y="492" text-anchor="middle" fill="#555555" font-size="13">${GWLBE_AZ2_ID_DISP}</text>

  <!-- Private Subnets - Middle Column Row 3 -->
  <rect x="1050" y="526" width="210" height="100" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="1155" y="558" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Private AZ1</text>
  <text x="1155" y="585" text-anchor="middle" fill="#111111" font-size="15">${INSP_PRIVATE_AZ1_CIDR}</text>
  <text x="1155" y="612" text-anchor="middle" fill="#FF9900" font-size="14">0.0.0.0/0 -> GWLBE</text>

  <rect x="1280" y="526" width="210" height="100" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="1385" y="558" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Private AZ2</text>
  <text x="1385" y="585" text-anchor="middle" fill="#111111" font-size="15">${INSP_PRIVATE_AZ2_CIDR}</text>
  <text x="1385" y="612" text-anchor="middle" fill="#FF9900" font-size="14">0.0.0.0/0 -> GWLBE</text>

  <!-- NAT GW Subnets - RIGHT SIDE -->
  <rect x="1540" y="290" width="210" height="100" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="1645" y="325" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">NAT GW AZ1</text>
  <text x="1645" y="352" text-anchor="middle" fill="#111111" font-size="15">${INSP_NATGW_AZ1_CIDR}</text>
  <text x="1645" y="378" text-anchor="middle" fill="#FF9900" font-size="14">0.0.0.0/0 -> IGW</text>

  <rect x="1770" y="290" width="210" height="100" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="1875" y="325" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">NAT GW AZ2</text>
  <text x="1875" y="352" text-anchor="middle" fill="#111111" font-size="15">${INSP_NATGW_AZ2_CIDR}</text>
  <text x="1875" y="378" text-anchor="middle" fill="#FF9900" font-size="14">0.0.0.0/0 -> IGW</text>

$MGMT_ENI_BLOCK
$MGMT_ENI_AZ3_BLOCK

  <!-- Inspection VPC TGW Attach indicator -->
  <rect x="1200" y="$INSP_TGW_Y" width="140" height="42" rx="3" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1270" y="$($INSP_TGW_Y + 28)" text-anchor="middle" fill="#111111" font-size="16">TGW Attach</text>

  <!-- ENI Connection Lines from FortiGate ASG (dotted) -->
  <!-- port1 to Public subnets (green) -->
  <line x1="1010" y1="438" x2="1050" y2="340" stroke="#2E8B2E" stroke-width="2" stroke-dasharray="4,3"/>
  <!-- port2 to GWLBE subnets (orange) -->
  <line x1="1010" y1="465" x2="1050" y2="458" stroke="#ED7100" stroke-width="2" stroke-dasharray="4,3"/>

"@)

# ---- Block F: port3 -> Management VPC connector (only if ENABLE_BUILD_MGMT) ----
if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$svg.Append(@"
  <!-- port3 to Management VPC (blue) - goes left -->
  <path d="M 760 492 L 700 492 L 700 400 L 660 400" stroke="#147EBA" stroke-width="2" stroke-dasharray="4,3" fill="none"/>

"@)
}

# ---- Block G: Transit Gateway box (always) ----
[void]$svg.Append(@"
  <!-- ==================== TRANSIT GATEWAY ==================== -->
  <rect x="60" y="840" width="2080" height="100" rx="10" fill="url(#purpleGradient)" opacity="0.9"/>
  <text x="1100" y="885" text-anchor="middle" fill="#111111" font-size="26" font-weight="bold">Transit Gateway: ${PREFIX}-tgw</text>
  <text x="1100" y="918" text-anchor="middle" fill="#111111" font-size="18">${TGW_ID}</text>

  <!-- TGW Connection Lines -->

"@)

# ---- Block H: Mgmt TGW connection line (only if ENABLE_BUILD_MGMT) ----
if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$svg.Append(@"
  <line x1="310" y1="$MGMT_TGW_CONNECT_Y" x2="310" y2="840" stroke="#8C4FFF" stroke-width="2"/>

"@)
}

# ---- Block I: Insp TGW connection line (always) ----
[void]$svg.Append(@"
  <line x1="1270" y1="$INSP_TGW_CONNECT_Y" x2="1270" y2="840" stroke="#8C4FFF" stroke-width="2"/>

"@)

# ---- Block J: East + West spoke VPCs (only if ENABLE_BUILD_SPOKES) ----
if ($ENABLE_BUILD_SPOKES -ceq 'true') {
    [void]$svg.Append(@"
  <!-- ==================== EAST SPOKE VPC ==================== -->
  <rect x="620" y="990" width="500" height="370" rx="10" fill="none" stroke="#3B48CC" stroke-width="3"/>
  <text x="645" y="1030" fill="#111111" font-size="22" font-weight="bold">East Spoke VPC</text>
  <text x="645" y="1060" fill="#444444" font-size="16">${EAST_VPC_ID} | ${VPC_CIDR_EAST}</text>

  <!-- East Public Subnets -->
  <rect x="650" y="1085" width="220" height="120" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="760" y="1118" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Public AZ1</text>
  <text x="760" y="1145" text-anchor="middle" fill="#111111" font-size="15">${EAST_PUBLIC_AZ1_CIDR}</text>
  <rect x="675" y="1160" width="170" height="38" rx="3" fill="white" stroke="#FF9900" stroke-width="1"/>
  <text x="760" y="1185" text-anchor="middle" fill="#111111" font-size="15">${EAST_AZ1_PRIVATE}</text>

  <rect x="890" y="1085" width="220" height="120" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="1000" y="1118" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Public AZ2</text>
  <text x="1000" y="1145" text-anchor="middle" fill="#111111" font-size="15">${EAST_PUBLIC_AZ2_CIDR}</text>
  <rect x="915" y="1160" width="170" height="38" rx="3" fill="white" stroke="#FF9900" stroke-width="1"/>
  <text x="1000" y="1185" text-anchor="middle" fill="#111111" font-size="15">${EAST_AZ2_PRIVATE}</text>

  <!-- East TGW Subnets -->
  <rect x="650" y="1220" width="220" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="760" y="1255" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">TGW AZ1</text>
  <text x="760" y="1282" text-anchor="middle" fill="#111111" font-size="15">${EAST_TGW_AZ1_CIDR}</text>

  <rect x="890" y="1220" width="220" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1000" y="1255" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">TGW AZ2</text>
  <text x="1000" y="1282" text-anchor="middle" fill="#111111" font-size="15">${EAST_TGW_AZ2_CIDR}</text>

  <!-- East TGW Connection -->
  <line x1="870" y1="940" x2="870" y2="990" stroke="#8C4FFF" stroke-width="2"/>

  <!-- East Route Status -->
  <rect x="650" y="1310" width="460" height="40" rx="3" fill="#007700" opacity="0.3"/>
  <text x="880" y="1337" text-anchor="middle" fill="#CC0000" font-size="15">Route: 0.0.0.0/0 -> TGW | TGW RT: ${EAST_TGW_DEFAULT_ROUTE}</text>

  <!-- ==================== WEST SPOKE VPC ==================== -->
  <rect x="1160" y="990" width="500" height="370" rx="10" fill="none" stroke="#3B48CC" stroke-width="3"/>
  <text x="1185" y="1030" fill="#111111" font-size="22" font-weight="bold">West Spoke VPC</text>
  <text x="1185" y="1060" fill="#444444" font-size="16">${WEST_VPC_ID} | ${VPC_CIDR_WEST}</text>

  <!-- West Public Subnets -->
  <rect x="1190" y="1085" width="220" height="120" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="1300" y="1118" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Public AZ1</text>
  <text x="1300" y="1145" text-anchor="middle" fill="#111111" font-size="15">${WEST_PUBLIC_AZ1_CIDR}</text>
  <rect x="1215" y="1160" width="170" height="38" rx="3" fill="white" stroke="#FF9900" stroke-width="1"/>
  <text x="1300" y="1185" text-anchor="middle" fill="#111111" font-size="15">${WEST_AZ1_PRIVATE}</text>

  <rect x="1430" y="1085" width="220" height="120" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="1540" y="1118" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">Public AZ2</text>
  <text x="1540" y="1145" text-anchor="middle" fill="#111111" font-size="15">${WEST_PUBLIC_AZ2_CIDR}</text>
  <rect x="1455" y="1160" width="170" height="38" rx="3" fill="white" stroke="#FF9900" stroke-width="1"/>
  <text x="1540" y="1185" text-anchor="middle" fill="#111111" font-size="15">${WEST_AZ2_PRIVATE}</text>

  <!-- West TGW Subnets -->
  <rect x="1190" y="1220" width="220" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1300" y="1255" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">TGW AZ1</text>
  <text x="1300" y="1282" text-anchor="middle" fill="#111111" font-size="15">${WEST_TGW_AZ1_CIDR}</text>

  <rect x="1430" y="1220" width="220" height="80" rx="5" fill="url(#purpleGradient)" opacity="0.8"/>
  <text x="1540" y="1255" text-anchor="middle" fill="#111111" font-size="17" font-weight="bold">TGW AZ2</text>
  <text x="1540" y="1282" text-anchor="middle" fill="#111111" font-size="15">${WEST_TGW_AZ2_CIDR}</text>

  <!-- West TGW Connection -->
  <line x1="1410" y1="940" x2="1410" y2="990" stroke="#8C4FFF" stroke-width="2"/>

  <!-- West Route Status -->
  <rect x="1190" y="1310" width="460" height="40" rx="3" fill="#007700" opacity="0.3"/>
  <text x="1420" y="1337" text-anchor="middle" fill="#CC0000" font-size="15">Route: 0.0.0.0/0 -> TGW | TGW RT: ${WEST_TGW_DEFAULT_ROUTE}</text>

"@)
}

# ---- Block K: Distributed VPC 1 (only if ENABLE_DISTRIBUTED and count >= 1) ----
$distributedCountNum = 0
if (-not [string]::IsNullOrEmpty($DISTRIBUTED_COUNT)) {
    [void][int]::TryParse($DISTRIBUTED_COUNT, [ref]$distributedCountNum)
}
if ($ENABLE_DISTRIBUTED -ceq 'true' -and $distributedCountNum -ge 1) {
    [void]$svg.Append(@"

  <!-- ==================== DISTRIBUTED VPC 1 ==================== -->
  <rect x="450" y="890" width="500" height="190" rx="10" fill="none" stroke="#3B48CC" stroke-width="3"/>
  <text x="460" y="915" fill="#111111" font-size="14" font-weight="bold">Distributed VPC 1</text>
  <text x="460" y="932" fill="#444444" font-size="11">${DISTRIBUTED_VPC_1_CIDR} | NOT attached to TGW</text>

  <!-- Distributed IGW -->
  <rect x="880" y="870" width="60" height="25" rx="5" fill="#232F3E" stroke="#FF9900" stroke-width="2"/>
  <text x="910" y="887" text-anchor="middle" fill="#FF9900" font-size="9" font-weight="bold">IGW</text>
  <line x1="910" y1="895" x2="910" y2="910" stroke="#FF9900" stroke-width="2" stroke-dasharray="4,2"/>

  <!-- Distributed Public Subnets -->
  <rect x="470" y="945" width="220" height="55" rx="5" fill="url(#greenGradient)" opacity="0.8"/>
  <text x="580" y="965" text-anchor="middle" fill="#111111" font-size="10" font-weight="bold">Public Subnets (AZ1, AZ2)</text>
  <text x="580" y="980" text-anchor="middle" fill="#111111" font-size="9">GWLBE ingress point</text>

  <!-- Distributed GWLBE Subnets -->
  <rect x="710" y="945" width="220" height="55" rx="5" fill="url(#orangeGradient)" opacity="0.8"/>
  <text x="820" y="965" text-anchor="middle" fill="#111111" font-size="10" font-weight="bold">GWLBE Subnets (AZ1, AZ2)</text>
  <text x="820" y="980" text-anchor="middle" fill="#111111" font-size="9">Traffic hairpin to FortiGates</text>

  <!-- Distributed Private Subnets with instances -->
  <rect x="470" y="1010" width="460" height="55" rx="5" fill="url(#blueGradient)" opacity="0.8"/>
  <text x="700" y="1028" text-anchor="middle" fill="#111111" font-size="10" font-weight="bold">Private Subnets (AZ1, AZ2)</text>
  <!-- Instance AZ1 -->
  <rect x="500" y="1035" width="140" height="22" rx="3" fill="#232F3E" stroke="#FF9900" stroke-width="1"/>
  <text x="570" y="1050" text-anchor="middle" fill="#111111" font-size="7">${DIST1_AZ1_PRIVATE}</text>
  <text x="570" y="1033" text-anchor="middle" fill="#007700" font-size="7">${DIST1_AZ1_PUBLIC}</text>
  <!-- Instance AZ2 -->
  <rect x="760" y="1035" width="140" height="22" rx="3" fill="#232F3E" stroke="#FF9900" stroke-width="1"/>
  <text x="830" y="1050" text-anchor="middle" fill="#111111" font-size="7">${DIST1_AZ2_PRIVATE}</text>
  <text x="830" y="1033" text-anchor="middle" fill="#007700" font-size="7">${DIST1_AZ2_PUBLIC}</text>

"@)
}

# ---- Block L: FortiTester 1 (only if FORTITESTER_1_PRIVATE is set) ----
if (-not [string]::IsNullOrEmpty($FORTITESTER_1_PRIVATE)) {
    [void]$svg.Append(@"

  <!-- ==================== FORTITESTER 1 (AZ1) ==================== -->
  <!-- FortiTester 1 spans: Mgmt VPC AZ1 (port1), East AZ1 (port2), West AZ1 (port3) -->
  <rect x="60" y="660" width="600" height="120" rx="5" fill="#232F3E" stroke="#00BFFF" stroke-width="2"/>
  <text x="85" y="690" fill="#00BFFF" font-size="18" font-weight="bold">FortiTester 1 (AZ1)</text>
  <text x="85" y="715" fill="#111111" font-size="14">Port1 (Mgmt): ${FORTITESTER_1_PRIVATE}</text>
  <text x="85" y="735" fill="#007700" font-size="14">Public: ${FORTITESTER_1_PUBLIC_DISP}</text>
  <text x="280" y="715" fill="#111111" font-size="14">Port2 (East): ${FORTITESTER_1_PORT2_DISP}</text>
  <text x="450" y="715" fill="#111111" font-size="14">Port3 (West): ${FORTITESTER_1_PORT3_DISP}</text>
  <!-- Connection lines to subnets -->
  <line x1="160" y1="660" x2="160" y2="435" stroke="#00BFFF" stroke-width="1" stroke-dasharray="3,2"/>
  <line x1="330" y1="760" x2="760" y2="1160" stroke="#00BFFF" stroke-width="1" stroke-dasharray="3,2"/>
  <line x1="500" y1="760" x2="1300" y2="1160" stroke="#00BFFF" stroke-width="1" stroke-dasharray="3,2"/>

"@)
}

# ---- Block M: FortiTester 2 (only if FORTITESTER_2_PRIVATE is set) ----
if (-not [string]::IsNullOrEmpty($FORTITESTER_2_PRIVATE)) {
    [void]$svg.Append(@"

  <!-- ==================== FORTITESTER 2 (AZ2) ==================== -->
  <!-- FortiTester 2 spans: Mgmt VPC AZ2 (port1), West AZ2 (port2), East AZ2 (port3) -->
  <rect x="60" y="795" width="600" height="120" rx="5" fill="#232F3E" stroke="#00BFFF" stroke-width="2"/>
  <text x="85" y="825" fill="#00BFFF" font-size="18" font-weight="bold">FortiTester 2 (AZ2)</text>
  <text x="85" y="850" fill="#111111" font-size="14">Port1 (Mgmt): ${FORTITESTER_2_PRIVATE}</text>
  <text x="85" y="870" fill="#007700" font-size="14">Public: ${FORTITESTER_2_PUBLIC_DISP}</text>
  <text x="280" y="850" fill="#111111" font-size="14">Port2 (West): ${FORTITESTER_2_PORT2_DISP}</text>
  <text x="450" y="850" fill="#111111" font-size="14">Port3 (East): ${FORTITESTER_2_PORT3_DISP}</text>

"@)
}

# ---- Block N: Legend + closing </svg> (always) ----
[void]$svg.Append(@"

  <!-- ==================== LEGEND ==================== -->
  <rect x="60" y="990" width="530" height="370" rx="5" fill="white" stroke="#cccccc" stroke-width="1"/>
  <text x="85" y="1030" fill="#111111" font-size="22" font-weight="bold">Legend</text>

  <!-- Subnet Types -->
  <rect x="85" y="1065" width="32" height="24" fill="url(#greenGradient)"/>
  <text x="130" y="1085" fill="#111111" font-size="17">Public Subnet</text>

  <rect x="85" y="1105" width="32" height="24" fill="url(#blueGradient)"/>
  <text x="130" y="1125" fill="#111111" font-size="17">Private/NAT GW Subnet</text>

  <rect x="85" y="1145" width="32" height="24" fill="url(#purpleGradient)"/>
  <text x="130" y="1165" fill="#111111" font-size="17">TGW Subnet</text>

  <rect x="85" y="1185" width="32" height="24" fill="url(#orangeGradient)"/>
  <text x="130" y="1205" fill="#111111" font-size="17">GWLB/GWLBE Subnet</text>

  <rect x="85" y="1225" width="32" height="24" fill="none" stroke="#EE3124" stroke-width="1" stroke-dasharray="3,2"/>
  <text x="130" y="1245" fill="#111111" font-size="17">${FGT_LEGEND_TEXT}</text>

  <rect x="85" y="1265" width="32" height="24" fill="#232F3E" stroke="#00BFFF" stroke-width="1"/>
  <text x="130" y="1285" fill="#111111" font-size="17">FortiTester</text>

  <!-- ENI Connection Legend -->
  <text x="340" y="1085" fill="#111111" font-size="17" font-weight="bold">ENI Connections:</text>
  <line x1="340" y1="1112" x2="395" y2="1112" stroke="#2E8B2E" stroke-width="2" stroke-dasharray="4,3"/>
  <text x="408" y="1118" fill="#2E8B2E" font-size="16">port1 (Public)</text>
  <line x1="340" y1="1145" x2="395" y2="1145" stroke="#ED7100" stroke-width="2" stroke-dasharray="4,3"/>
  <text x="408" y="1151" fill="#ED7100" font-size="16">port2 (GWLBE)</text>
  <line x1="340" y1="1178" x2="395" y2="1178" stroke="#147EBA" stroke-width="2" stroke-dasharray="4,3"/>
  <text x="408" y="1184" fill="#147EBA" font-size="16">port3 (Mgmt VPC)</text>

  <!-- IP Legend -->
  <text x="85" y="1285" fill="#111111" font-size="17" font-weight="bold">IP Addresses:</text>
  <text x="85" y="1312" fill="#111111" font-size="17">Private IP (white)</text>
  <text x="85" y="1339" fill="#007700" font-size="17">Public IP (green)</text>

  <!-- Status -->
  <text x="340" y="1220" fill="#111111" font-size="17" font-weight="bold">Deployment:</text>
  <text x="340" y="1247" fill="#007700" font-size="16">East/West TGW: Attached</text>
  <text x="340" y="1274" fill="$FGT_DEPLOY_STATUS_COLOR" font-size="16">${FGT_DEPLOY_STATUS}</text>

  <!-- Instance Summary -->
  <text x="340" y="1312" fill="#111111" font-size="17" font-weight="bold">Public IPs:</text>
  <text x="340" y="1339" fill="#007700" font-size="16">Jump Box: ${JUMP_BOX_PUBLIC}</text>

</svg>
"@)

[System.IO.File]::WriteAllText($SVG_FILE, $svg.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Pass "SVG diagram created: $SVG_FILE"

# ===========================================================================
# Generate Markdown file
# ===========================================================================
Write-Info "Generating Markdown documentation..."

if ($FORTIGATE_COUNT -gt 0) {
    $FGT_STATUS_TEXT = "The FortiGate AutoScale Group is deployed with $FORTIGATE_COUNT instance(s) running."
} else {
    $FGT_STATUS_TEXT = 'The FortiGate AutoScale Group has not yet been deployed.'
}

$md = New-Object System.Text.StringBuilder

[void]$md.Append(@"
# Network Diagram - ${PREFIX} Infrastructure

**Generated:** ${TIMESTAMP}
**Template:** ``existing_vpc_resources``
**Region:** ${AWS_REGION} (AZs: ${AZ1}, ${AZ2})

---

## FortiGate Credentials

| Username | Password |
|----------|----------|
| admin | ${FGT_PASSWORD} |

---

## Infrastructure Overview

This diagram shows the current state of the ``${PREFIX}`` infrastructure deployed using the ``existing_vpc_resources`` template. ${FGT_STATUS_TEXT}

![Network Diagram](network_diagram.svg)

---

## Resource Summary

### VPCs

| VPC | CIDR | VPC ID | Status |
|-----|------|--------|--------|

"@)

if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$md.Append("| Management VPC | ${VPC_CIDR_MANAGEMENT} | ${MGMT_VPC_ID} | Deployed |`n")
}

[void]$md.Append("| Inspection VPC | ${VPC_CIDR_INSPECTION} | ${INSPECTION_VPC_ID} | Deployed |`n")

if ($ENABLE_BUILD_SPOKES -ceq 'true') {
    [void]$md.Append("| East Spoke VPC | ${VPC_CIDR_EAST} | ${EAST_VPC_ID} | Deployed |`n")
    [void]$md.Append("| West Spoke VPC | ${VPC_CIDR_WEST} | ${WEST_VPC_ID} | Deployed |`n")
}

if ($ENABLE_DISTRIBUTED -ceq 'true') {
    [void]$md.Append("| Distributed VPC 1 | ${DISTRIBUTED_VPC_1_CIDR} | - | Deployed |`n")
}

[void]$md.Append(@"

### Transit Gateway

| Resource | ID | Name |
|----------|-----|------|
| Transit Gateway | ${TGW_ID} | ${PREFIX}-tgw |

### Transit Gateway Attachments

| Attachment ID | VPC | VPC ID |
|--------------|-----|--------|

"@)

if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$md.Append("| ${MGMT_TGW_ATTACH_ID} | Management VPC | ${MGMT_VPC_ID} |`n")
}

[void]$md.Append("| ${INSP_TGW_ATTACH_ID} | Inspection VPC | ${INSPECTION_VPC_ID} |`n")

if ($ENABLE_BUILD_SPOKES -ceq 'true') {
    [void]$md.Append("| ${EAST_TGW_ATTACH_ID} | East Spoke VPC | ${EAST_VPC_ID} |`n")
    [void]$md.Append("| ${WEST_TGW_ATTACH_ID} | West Spoke VPC | ${WEST_VPC_ID} |`n")
}

[void]$md.Append(@"

### Instances with Public IPs

| Instance Name | Instance ID | Private IP | Public IP |
|--------------|-------------|------------|-----------|
| ${JUMP_BOX_NAME} | ${JUMP_BOX_ID} | ${JUMP_BOX_PRIVATE} | ${JUMP_BOX_PUBLIC} |

"@)

if ($ENABLE_DISTRIBUTED -ceq 'true' -and -not [string]::IsNullOrEmpty($DIST1_AZ1_PUBLIC)) {
    [void]$md.Append("| ${DIST1_AZ1_NAME} | ${DIST1_AZ1_ID} | ${DIST1_AZ1_PRIVATE} | ${DIST1_AZ1_PUBLIC} |`n")
    [void]$md.Append("| ${DIST1_AZ2_NAME} | ${DIST1_AZ2_ID} | ${DIST1_AZ2_PRIVATE} | ${DIST1_AZ2_PUBLIC} |`n")
}

if (-not [string]::IsNullOrEmpty($FORTITESTER_1_PUBLIC)) {
    [void]$md.Append("| ${FORTITESTER_1_NAME} | ${FORTITESTER_1_ID} | ${FORTITESTER_1_PRIVATE} | ${FORTITESTER_1_PUBLIC} |`n")
}

if (-not [string]::IsNullOrEmpty($FORTITESTER_2_PUBLIC)) {
    [void]$md.Append("| ${FORTITESTER_2_NAME} | ${FORTITESTER_2_ID} | ${FORTITESTER_2_PRIVATE} | ${FORTITESTER_2_PUBLIC} |`n")
}

# FortiGate ASG instances section
if ($FORTIGATE_COUNT -gt 0) {
    [void]$md.Append(@"

### FortiGate AutoScale Group Instances

| Instance Name | Instance ID | Role | Private IP | Public IP (Management) |
|--------------|-------------|------|------------|------------------------|
${FORTIGATE_MD_TABLE}
> **Note:** FortiGate management interfaces are accessible via their public IPs. Use ``admin`` as username with the configured password. The **Primary** instance holds the configuration that is synced to Secondary instances.

"@)
} else {
    [void]$md.Append(@"

### FortiGate AutoScale Group Instances

*No FortiGate ASG instances deployed yet. Deploy the ``autoscale_template`` to create the FortiGate Auto Scaling Group.*

"@)
}

# FortiManager section
if ($ENABLE_FMG_INTEGRATION -ceq 'true' -and -not [string]::IsNullOrEmpty($FORTIMANAGER_IP)) {
    [void]$md.Append(@"

### FortiManager Integration

| Setting | Value |
|---------|-------|
| Integration Enabled | Yes |
| FortiManager IP | ${FORTIMANAGER_IP} |
| FortiManager Serial | ${FORTIMANAGER_SN_DISP} |

> **Note:** FortiGates in the AutoScale Group are configured to register with this FortiManager. Access FortiManager at ``https://${FORTIMANAGER_IP}``

"@)
}

# FortiTester detailed section
$anyFortiTester = ((-not [string]::IsNullOrEmpty($FORTITESTER_1_PRIVATE)) -or (-not [string]::IsNullOrEmpty($FORTITESTER_2_PRIVATE)))
if ($anyFortiTester) {
    [void]$md.Append(@"

### FortiTester Instances

FortiTesters are deployed with 3 network interfaces each for traffic generation testing across VPCs.

| FortiTester | Instance ID | Port1 (Mgmt VPC) | Port2 | Port3 | Public IP |
|-------------|-------------|------------------|-------|-------|-----------|

"@)

    if (-not [string]::IsNullOrEmpty($FORTITESTER_1_PRIVATE)) {
        [void]$md.Append("| FortiTester 1 (AZ1) | ${FORTITESTER_1_ID_DISP} | ${FORTITESTER_1_PRIVATE} | East: ${FORTITESTER_1_PORT2_DISP} | West: ${FORTITESTER_1_PORT3_DISP} | ${FORTITESTER_1_PUBLIC_DISP} |`n")
    }

    if (-not [string]::IsNullOrEmpty($FORTITESTER_2_PRIVATE)) {
        [void]$md.Append("| FortiTester 2 (AZ2) | ${FORTITESTER_2_ID_DISP} | ${FORTITESTER_2_PRIVATE} | West: ${FORTITESTER_2_PORT2_DISP} | East: ${FORTITESTER_2_PORT3_DISP} | ${FORTITESTER_2_PUBLIC_DISP} |`n")
    }

    [void]$md.Append(@"

> **Note:** FortiTesters span multiple VPCs for traffic generation testing:
> - **FortiTester 1**: Port1 in Management VPC AZ1, Port2 in East VPC AZ1, Port3 in West VPC AZ1
> - **FortiTester 2**: Port1 in Management VPC AZ2, Port2 in West VPC AZ2, Port3 in East VPC AZ2
>
> Access FortiTesters via HTTPS at their public IPs. Default credentials: **admin** / **Instance ID** (e.g., i-0abc123def456...)

"@)
}

if ($ENABLE_BUILD_SPOKES -ceq 'true') {
    [void]$md.Append(@"

### Spoke VPC Instances (No Public IPs)

| Instance Name | Private IP |
|--------------|------------|
| ${EAST_AZ1_NAME} | ${EAST_AZ1_PRIVATE} |
| ${EAST_AZ2_NAME} | ${EAST_AZ2_PRIVATE} |
| ${WEST_AZ1_NAME} | ${WEST_AZ1_PRIVATE} |
| ${WEST_AZ2_NAME} | ${WEST_AZ2_PRIVATE} |

"@)
}

[void]$md.Append(@"

---

## Routing Status

### Default Route (0.0.0.0/0) Summary

| Route Table | Target | Status |
|-------------|--------|--------|

"@)

if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$md.Append("| Management VPC Public | IGW | OK |`n")
}

[void]$md.Append("| Inspection VPC NAT GW AZ1 | IGW | OK |`n")
[void]$md.Append("| Inspection VPC NAT GW AZ2 | IGW | OK |`n")

if ($ENABLE_BUILD_SPOKES -ceq 'true') {
    [void]$md.Append("| East VPC Public | TGW | OK |`n")
    [void]$md.Append("| West VPC Public | TGW | OK |`n")
    [void]$md.Append("| East TGW Attachment RT | **${EAST_TGW_DEFAULT_ROUTE}** | ${ROUTE_STATUS_TEXT} |`n")
    [void]$md.Append("| West TGW Attachment RT | **${WEST_TGW_DEFAULT_ROUTE}** | ${ROUTE_STATUS_TEXT} |`n")
}

if ($ENABLE_BUILD_MGMT -ceq 'true') {
    [void]$md.Append("| Management TGW Attachment RT | No default route | Expected |`n")
}

[void]$md.Append(@"

### Notes

- Inspection VPC routes spoke traffic through GWLB to FortiGate ASG

---

## Next Steps

1. Deploy ``autoscale_template`` to create FortiGate Auto Scaling Group
2. ASG deployment will automatically:
   - Create GWLB and endpoints
   - Update TGW route tables with default routes pointing to Inspection VPC
   - Enable traffic inspection for East/West spoke VPCs

---

*Source: Generated by verify_all.sh*
"@)

[System.IO.File]::WriteAllText($MD_FILE, $md.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Pass "Markdown documentation created: $MD_FILE"

Write-Host ""
Write-Info "Network diagram files generated:"
Write-Host "  - SVG: $SVG_FILE"
Write-Host "  - MD:  $MD_FILE"
Write-Host ""

# ===========================================================================
# PORTING NOTES (for human review -- see also the task's final report)
#
# 1. Invoke-AwsText maps the literal text "None" to "" for EVERY text query,
#    whereas the bash original only did this explicitly for a subset of
#    variables (VPC/TGW/attachment IDs, AZ3-only subnet CIDRs, etc.) and left
#    it unguarded for most subnet CIDR lookups. In the normal/expected case
#    (fully-deployed infra) this never matters because none of those queries
#    actually return "None". This is a deliberate, minor robustness
#    improvement, not a structural content change.
#
# 2. Blank-line whitespace around the AZ3 banner / Mgmt-ENI conditional SVG
#    blocks may differ by a line or two from the bash output in edge cases,
#    because bash builds those via inline `$(if ...; then echo ...; fi)`
#    command substitutions (which strip trailing newlines in a
#    content-dependent way), while this port pre-computes each optional
#    block into its own variable and interpolates it. The actual SVG
#    elements/attributes/coordinates emitted are identical either way; only
#    insignificant XML whitespace between elements can differ.
# ===========================================================================
