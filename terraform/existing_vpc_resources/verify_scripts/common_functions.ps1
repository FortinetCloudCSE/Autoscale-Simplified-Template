#requires -Version 5.1
# common_functions.ps1
#
# PowerShell port of common_functions.sh
# Common helper functions for verification / diagram-generation scripts.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# No ternary operator, no null-coalescing operator, no PS7-only syntax is used
# anywhere in this file, by design.
#
# Dot-source this file from a calling script:
#   . (Join-Path $PSScriptRoot 'common_functions.ps1')

# ---------------------------------------------------------------------------
# Global counters (bash: PASSED_CHECKS / FAILED_CHECKS / SKIPPED_CHECKS)
# These live in "script scope". Because this file is meant to be dot-sourced
# (not dot-sourcing does not create a new scope), the counters end up living
# directly in the scope of whichever top-level script dot-sources this file,
# which is exactly the behavior we want (mirrors bash's global variables).
# ---------------------------------------------------------------------------
$script:PassedChecks = 0
$script:FailedChecks = 0
$script:SkippedChecks = 0

# ---------------------------------------------------------------------------
# Terraform verification data fast-path (bash: TF_DATA_AVAILABLE / sourcing of
# terraform_verification_data.sh)
#
# NOTE: terraform_verification_data.sh does not exist anywhere in this repo
# today, so the bash "source it if present" logic is dead code as far as this
# ported script is concerned. We do not port that sourcing logic in detail.
# We simply stub the flag to $false so any downstream logic that checks it
# (here, or in scripts added later) degrades gracefully to the AWS CLI
# lookup path, exactly like bash does when the file is absent.
# ---------------------------------------------------------------------------
$script:TF_DATA_AVAILABLE = $false

# Defensive: make sure [System.Numerics.BigInteger] (used by Get-CidrHost
# below) is loadable even on a bare Windows PowerShell 5.1 host that hasn't
# already pulled in System.Numerics.dll.
Add-Type -AssemblyName System.Numerics -ErrorAction SilentlyContinue

# ===========================================================================
# Print / output helpers
# ===========================================================================

function Write-Pass {
    # bash: print_pass
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASSED] $Message" -ForegroundColor Green
    $script:PassedChecks++
}

function Write-Fail {
    # bash: print_fail
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[FAILED] $Message" -ForegroundColor Red
    $script:FailedChecks++
}

function Write-Skip {
    # bash: print_skip
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[SKIPPED] $Message" -ForegroundColor Yellow
    $script:SkippedChecks++
}

function Write-Info {
    # bash: print_info
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Blue
}

function Write-Section {
    # bash: print_section
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host ("=" * 40) -ForegroundColor Blue
    Write-Host $Message -ForegroundColor Blue
    Write-Host ("=" * 40) -ForegroundColor Blue
}

function Write-Summary {
    # bash: print_summary
    # Returns 0 (success) if there were no failures, 1 otherwise -- mirrors
    # the bash function's return code so callers can check it the same way.
    Write-Host ""
    Write-Host ("=" * 40) -ForegroundColor Blue
    Write-Host "SUMMARY" -ForegroundColor Blue
    Write-Host ("=" * 40) -ForegroundColor Blue
    Write-Host -NoNewline "Total Passed:  "
    Write-Host $script:PassedChecks -ForegroundColor Green
    Write-Host -NoNewline "Total Failed:  "
    Write-Host $script:FailedChecks -ForegroundColor Red
    Write-Host -NoNewline "Total Skipped: "
    Write-Host $script:SkippedChecks -ForegroundColor Yellow
    Write-Host ""

    if ($script:FailedChecks -eq 0) {
        Write-Host "All checks passed!" -ForegroundColor Green
        return 0
    } else {
        Write-Host "Some checks failed!" -ForegroundColor Red
        return 1
    }
}

# ===========================================================================
# tfvars file helpers
# ===========================================================================

function Read-TfVars {
    # bash: read_tfvars
    param([Parameter(Mandatory = $true)][string]$TfvarsFile)

    if (-not (Test-Path -LiteralPath $TfvarsFile -PathType Leaf)) {
        Write-Fail "terraform.tfvars file not found at: $TfvarsFile"
        exit 1
    }

    Write-Info "Reading configuration from: $TfvarsFile"
}

function Get-TfVar {
    # bash: get_tfvar
    #
    # Replicates: grep "^${var_name}" "$file" | head -1 | sed 's/.*=[ ]*//' | sed 's/"//g' | sed 's/#.*//' | xargs
    #
    # Semantics preserved on purpose:
    #  - matches the FIRST line that starts with $VarName (no word boundary,
    #    same as the unescaped bash grep pattern -- "cp" would also match a
    #    line starting with "cpu_count", exactly like the bash version)
    #  - takes everything after the LAST "=" on that line (greedy, like sed's
    #    .*=), then strips a run of literal spaces right after it
    #  - strips ONLY double-quote characters (never single quotes)
    #  - strips everything from the first "#" onward (comment stripping)
    #  - finally collapses/trims whitespace the way `xargs` does (splits on
    #    runs of whitespace, drops empty tokens, rejoins with single spaces)
    param(
        [Parameter(Mandatory = $true)][string]$VarName,
        [Parameter(Mandatory = $true)][string]$TfvarsFile
    )

    if (-not (Test-Path -LiteralPath $TfvarsFile -PathType Leaf)) {
        return ""
    }

    $lines = @(Get-Content -LiteralPath $TfvarsFile -ErrorAction SilentlyContinue)
    $matchLine = $null
    foreach ($line in $lines) {
        if ($null -ne $line -and $line -match "^$VarName") {
            $matchLine = $line
            break
        }
    }

    if ($null -eq $matchLine) {
        return ""
    }

    # sed 's/.*=[ ]*//' : take substring after the LAST '=' on the line, then
    # eat any literal spaces immediately following it.
    $eqIndex = $matchLine.LastIndexOf('=')
    if ($eqIndex -ge 0) {
        $value = $matchLine.Substring($eqIndex + 1)
    } else {
        $value = $matchLine
    }
    $value = $value -replace '^ +', ''

    # sed 's/"//g' : strip all double-quote characters (not single quotes).
    $value = $value -replace '"', ''

    # sed 's/#.*//' : strip from the first '#' to end of line.
    $value = $value -replace '#.*$', ''

    # xargs : trim + collapse internal whitespace runs to single spaces.
    $tokens = @($value -split '\s+' | Where-Object { $_ -ne '' })
    return ($tokens -join ' ')
}

function Test-TfVarTrue {
    # bash: is_tfvar_true
    # Returns $true only if the tfvar's value is exactly the string "true".
    param(
        [Parameter(Mandatory = $true)][string]$VarName,
        [Parameter(Mandatory = $true)][string]$TfvarsFile
    )
    $value = Get-TfVar -VarName $VarName -TfvarsFile $TfvarsFile
    # bash uses `[ "$value" == "true" ]`, which is byte-for-byte case-sensitive;
    # PowerShell's -eq is case-INsensitive by default, so use -ceq to match.
    return ($value -ceq 'true')
}

# ===========================================================================
# AWS verification helpers
# (Ported for completeness / future reuse. generate_network_diagram.ps1 does
# not call most of these directly -- it does its own inline AWS CLI calls,
# same as the bash script does.)
#
# TF_DATA_AVAILABLE is always $false in this port (see note above), so the
# "try Terraform data first" branches from the bash originals are omitted;
# these always fall through to the AWS CLI lookup, which is the only path
# that can ever actually run here.
# ===========================================================================

function Get-VpcId {
    # bash: verify_vpc_exists
    # Returns the VPC ID string, or "" if not found.
    param(
        [Parameter(Mandatory = $true)][string]$VpcName,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $vpcId = (& aws ec2 describe-vpcs --region $Region `
            --filters "Name=tag:Name,Values=$VpcName" `
            --query 'Vpcs[0].VpcId' --output text 2>$null | Out-String).Trim()

    if ($vpcId -cne 'None' -and -not [string]::IsNullOrEmpty($vpcId)) {
        return $vpcId
    }
    return ""
}

function Test-VpcCidr {
    # bash: verify_vpc_cidr
    param(
        [Parameter(Mandatory = $true)][string]$VpcId,
        [Parameter(Mandatory = $true)][string]$ExpectedCidr,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $actualCidr = (& aws ec2 describe-vpcs --region $Region `
            --vpc-ids $VpcId `
            --query 'Vpcs[0].CidrBlock' --output text 2>$null | Out-String).Trim()

    if ($actualCidr -ceq $ExpectedCidr) {
        return $true
    }
    Write-Output "Expected: $ExpectedCidr, Got: $actualCidr"
    return $false
}

function Get-SubnetId {
    # bash: verify_subnet_exists
    param(
        [Parameter(Mandatory = $true)][string]$SubnetName,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $subnetId = (& aws ec2 describe-subnets --region $Region `
            --filters "Name=tag:Name,Values=$SubnetName" `
            --query 'Subnets[0].SubnetId' --output text 2>$null | Out-String).Trim()

    if ($subnetId -cne 'None' -and -not [string]::IsNullOrEmpty($subnetId)) {
        return $subnetId
    }
    return ""
}

function Test-SubnetCidr {
    # bash: verify_subnet_cidr
    param(
        [Parameter(Mandatory = $true)][string]$SubnetId,
        [Parameter(Mandatory = $true)][string]$ExpectedCidr,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $actualCidr = (& aws ec2 describe-subnets --region $Region `
            --subnet-ids $SubnetId `
            --query 'Subnets[0].CidrBlock' --output text 2>$null | Out-String).Trim()

    if ($actualCidr -ceq $ExpectedCidr) {
        return $true
    }
    Write-Output "Expected: $ExpectedCidr, Got: $actualCidr"
    return $false
}

function Test-SubnetAz {
    # bash: verify_subnet_az
    param(
        [Parameter(Mandatory = $true)][string]$SubnetId,
        [Parameter(Mandatory = $true)][string]$ExpectedAz,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $actualAz = (& aws ec2 describe-subnets --region $Region `
            --subnet-ids $SubnetId `
            --query 'Subnets[0].AvailabilityZone' --output text 2>$null | Out-String).Trim()

    if ($actualAz -ceq $ExpectedAz) {
        return $true
    }
    Write-Output "Expected: $ExpectedAz, Got: $actualAz"
    return $false
}

function Get-Igw {
    # bash: verify_igw
    param(
        [Parameter(Mandatory = $true)][string]$VpcId,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $igwId = (& aws ec2 describe-internet-gateways --region $Region `
            --filters "Name=attachment.vpc-id,Values=$VpcId" `
            --query 'InternetGateways[0].InternetGatewayId' --output text 2>$null | Out-String).Trim()

    if ($igwId -cne 'None' -and -not [string]::IsNullOrEmpty($igwId)) {
        return $igwId
    }
    return ""
}

function Test-RouteExists {
    # bash: verify_route_exists
    param(
        [Parameter(Mandatory = $true)][string]$RouteTableId,
        [Parameter(Mandatory = $true)][string]$DestCidr,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $route = (& aws ec2 describe-route-tables --region $Region `
            --route-table-ids $RouteTableId `
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='$DestCidr']" `
            --output text 2>$null | Out-String).Trim()

    return (-not [string]::IsNullOrEmpty($route))
}

function Get-RouteTarget {
    # bash: get_route_target
    param(
        [Parameter(Mandatory = $true)][string]$RouteTableId,
        [Parameter(Mandatory = $true)][string]$DestCidr,
        [Parameter(Mandatory = $true)][string]$Region
    )

    $target = (& aws ec2 describe-route-tables --region $Region `
            --route-table-ids $RouteTableId `
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='$DestCidr'].GatewayId" `
            --output text 2>$null | Out-String).Trim()

    if ([string]::IsNullOrEmpty($target) -or $target -ceq 'None') {
        $target = (& aws ec2 describe-route-tables --region $Region `
                --route-table-ids $RouteTableId `
                --query "RouteTables[0].Routes[?DestinationCidrBlock=='$DestCidr'].TransitGatewayId" `
                --output text 2>$null | Out-String).Trim()
    }

    if ([string]::IsNullOrEmpty($target) -or $target -ceq 'None') {
        $target = (& aws ec2 describe-route-tables --region $Region `
                --route-table-ids $RouteTableId `
                --query "RouteTables[0].Routes[?DestinationCidrBlock=='$DestCidr'].NatGatewayId" `
                --output text 2>$null | Out-String).Trim()
    }

    return $target
}

function Get-TgwVpcAttachment {
    # bash: verify_tgw_attachment (uses describe-transit-gateway-vpc-attachments)
    param(
        [Parameter(Mandatory = $true)][string]$VpcId,
        [Parameter(Mandatory = $true)][string]$TgwId,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $attachmentId = (& aws ec2 describe-transit-gateway-vpc-attachments --region $Region `
            --filters "Name=vpc-id,Values=$VpcId" "Name=transit-gateway-id,Values=$TgwId" "Name=state,Values=available" `
            --query 'TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId' --output text 2>$null | Out-String).Trim()

    if ($attachmentId -cne 'None' -and -not [string]::IsNullOrEmpty($attachmentId)) {
        return $attachmentId
    }
    return ""
}

function Get-Ec2InstanceId {
    # bash: verify_ec2_instance
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $instanceId = (& aws ec2 describe-instances --region $Region `
            --filters "Name=tag:Name,Values=$InstanceName" "Name=instance-state-name,Values=running" `
            --query 'Reservations[0].Instances[0].InstanceId' --output text 2>$null | Out-String).Trim()

    if ($instanceId -cne 'None' -and -not [string]::IsNullOrEmpty($instanceId)) {
        return $instanceId
    }
    return ""
}

function Get-InstancePrivateIp {
    # bash: get_instance_private_ip (common_functions.sh version: takes instance ID + region)
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region
    )
    return (& aws ec2 describe-instances --region $Region `
            --instance-ids $InstanceId `
            --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>$null | Out-String).Trim()
}

function Get-InstancePublicIp {
    # bash: get_instance_public_ip (common_functions.sh version: takes instance ID + region)
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Region
    )
    return (& aws ec2 describe-instances --region $Region `
            --instance-ids $InstanceId `
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>$null | Out-String).Trim()
}

function Get-TgwIdByName {
    # bash: get_tgw_id_by_name
    param(
        [Parameter(Mandatory = $true)][string]$TgwName,
        [Parameter(Mandatory = $true)][string]$Region
    )
    $tgwId = (& aws ec2 describe-transit-gateways --region $Region `
            --filters "Name=tag:Name,Values=$TgwName" "Name=state,Values=available" `
            --query 'TransitGateways[0].TransitGatewayId' --output text 2>$null | Out-String).Trim()

    if ($tgwId -cne 'None' -and -not [string]::IsNullOrEmpty($tgwId)) {
        return $tgwId
    }
    return ""
}

function Get-TfSubnetId {
    # bash: get_tf_subnet_id
    # Light stub only: TF_DATA_AVAILABLE is always $false in this port, so
    # this always "misses" -- exactly like the bash version when the
    # Terraform data file isn't sourced. Not used by generate_network_diagram.ps1.
    param(
        [string]$VpcType,
        [string]$SubnetType,
        [string]$Az
    )
    return ""
}

function Get-TfInstanceId {
    # bash: get_tf_instance_id
    # Light stub only -- see Get-TfSubnetId comment above.
    param(
        [string]$VpcType,
        [string]$Az
    )
    return ""
}

function Get-CidrHost {
    # bash: calculate_cidr_host
    #
    # bash shells out to `python3 -c "...ipaddress..."`. We must not depend
    # on python3 being present on Windows, so this is a native re-implementation
    # using [System.Net.IPAddress] + [System.Numerics.BigInteger].
    #
    # Mimics Terraform's cidrhost(): given a CIDR (e.g. "192.168.0.32/28") and
    # a host offset, returns network_address + hostoffset as a dotted-quad
    # string, or "" on any error (mirrors bash's `except: sys.exit(1)` -> empty
    # stdout via 2>/dev/null).
    #
    # IPv4 only (this script only ever deals with IPv4 VPC CIDRs).
    param(
        [Parameter(Mandatory = $true)][string]$Cidr,
        [Parameter(Mandatory = $true)][long]$HostNum
    )
    try {
        $parts = $Cidr.Split('/')
        if ($parts.Count -ne 2) { return "" }

        $ip = [System.Net.IPAddress]::Parse($parts[0].Trim())
        $prefixLen = [int]$parts[1].Trim()
        $ipBytes = $ip.GetAddressBytes()
        if ($ipBytes.Length -ne 4) {
            # IPv6 not supported by this port.
            return ""
        }

        [uint32]$ipInt = ([uint32]$ipBytes[0] -shl 24) -bor `
            ([uint32]$ipBytes[1] -shl 16) -bor `
            ([uint32]$ipBytes[2] -shl 8) -bor `
            ([uint32]$ipBytes[3])

        if ($prefixLen -le 0) {
            [uint32]$mask = 0
        } elseif ($prefixLen -ge 32) {
            [uint32]$mask = 0xFFFFFFFF
        } else {
            [uint32]$mask = [uint32]0xFFFFFFFF -shl (32 - $prefixLen)
        }

        $networkInt = $ipInt -band $mask
        $hostBig = [System.Numerics.BigInteger]$networkInt + [System.Numerics.BigInteger]$HostNum

        if ($hostBig -lt [System.Numerics.BigInteger]::Zero -or $hostBig -gt [System.Numerics.BigInteger]::Parse('4294967295')) {
            return ""
        }

        $resultInt = [uint32]$hostBig
        $b1 = [byte](($resultInt -shr 24) -band 0xFF)
        $b2 = [byte](($resultInt -shr 16) -band 0xFF)
        $b3 = [byte](($resultInt -shr 8) -band 0xFF)
        $b4 = [byte]($resultInt -band 0xFF)
        return "$b1.$b2.$b3.$b4"
    } catch {
        return ""
    }
}

function Test-InstanceIpInSubnet {
    # bash: verify_instance_ip_in_subnet
    # Bash returns 0 (match), 1 (mismatch, echoes Expected/Got), or 2 (warning,
    # could not calculate expected IP). We mirror this with a status string
    # in the returned object rather than relying on a numeric exit code, since
    # PowerShell functions don't have bash-style return codes.
    param(
        [Parameter(Mandatory = $true)][string]$ActualIp,
        [Parameter(Mandatory = $true)][string]$SubnetCidr,
        [Parameter(Mandatory = $true)][long]$ExpectedHostNum
    )

    $expectedIp = Get-CidrHost -Cidr $SubnetCidr -HostNum $ExpectedHostNum

    if ([string]::IsNullOrEmpty($expectedIp)) {
        Write-Output "WARNING: Could not calculate expected IP, checking if IP is in subnet range"
        return [pscustomobject]@{ Status = 'Warning'; Match = $null }
    }

    if ($ActualIp -ceq $expectedIp) {
        return [pscustomobject]@{ Status = 'Match'; Match = $true }
    }

    Write-Output "Expected: $expectedIp, Got: $ActualIp"
    return [pscustomobject]@{ Status = 'Mismatch'; Match = $false }
}
