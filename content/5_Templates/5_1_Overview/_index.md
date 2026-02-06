---
title: "Templates Overview"
chapter: false
menuTitle: "Overview"
weight: 51
---

## Introduction

The FortiGate Autoscale Simplified Template consists of two complementary Terraform templates that work together to deploy a complete FortiGate autoscale architecture in AWS:

1. **[existing_vpc_resources](../5_2_existing_vpc_resources/)** (Required First): Creates the Inspection VPC and supporting infrastructure with `Fortinet-Role` tags for resource discovery
2. **[unified_template](../5_3_unified_template/)** (Required Second): Deploys the FortiGate autoscale group into the existing Inspection VPC

{{% notice warning %}}
**Important Workflow Change**

The `unified_template` now deploys **into existing VPCs** rather than creating them. You must run `existing_vpc_resources` first to create the Inspection VPC with proper `Fortinet-Role` tags, then run `unified_template` to deploy the FortiGate autoscale group.
{{% /notice %}}

This modular approach allows you to:
- Separate VPC infrastructure from FortiGate deployment for better lifecycle management
- Use tag-based resource discovery for flexible integration
- Create a complete lab environment including management VPC, Transit Gateway, and spoke VPCs with traffic generators
- Mix and match components based on your specific requirements

---

## Template Architecture

### Component Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│ existing_vpc_resources Template (Run First)                     │
│                                                                 │
│  ┌──────────────────┐    ┌─────────────────┐                    │
│  │ Management VPC   │    │ Transit Gateway │                    │
│  │ - FortiManager   │    │ - Spoke VPCs    │                    │
│  │ - FortiAnalyzer  │    │ - Linux Instances                    │
│  │ - Jump Box       │    │ - Test Traffic  │                    │
│  └──────────────────┘    └─────────────────┘                    │
│          │                       │                              │
│          └───────────┬───────────┘                              │
│                      │                                          │
│  ┌───────────────────▼───────────────────┐                      │
│  │ Inspection VPC (with Fortinet-Role    │                      │
│  │ tags for resource discovery)          │                      │
│  │ - Public/Private/GWLBE Subnets        │                      │
│  │ - Route Tables, IGW, NAT GW           │                      │
│  │ - TGW Attachment (optional)           │                      │
│  └───────────────────────────────────────┘                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                       │ (Fortinet-Role tag discovery)
┌──────────────────────┼──────────────────────────────────────────┐
│ unified_template (Run Second)   │                               │
│                      │                                          │
│  ┌────────────────── ▼ ────────────────┐                        │
│  │ Deploys INTO Inspection VPC         │                        │
│  │ - FortiGate Autoscale Group         │                        │
│  │ - Gateway Load Balancer             │                        │
│  │ - GWLB Endpoints                    │                        │
│  │ - Lambda Functions                  │                        │
│  │ - Route modifications               │                        │
│  └─────────────────────────────────────┘                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Fortinet-Role Tag Discovery

The `unified_template` discovers existing resources using `Fortinet-Role` tags. This tag-based approach provides:

- **Decoupled lifecycle management**: VPC infrastructure can persist while FortiGate deployments are updated
- **Flexible integration**: Works with any VPC that has the correct tags, not just those created by `existing_vpc_resources`
- **Clear resource ownership**: Tags explicitly identify resources intended for FortiGate integration

---

## Quick Decision Tree

Use this decision tree to determine your deployment approach:

```
1. Do you have existing VPCs with Fortinet-Role tags?
   ├─ YES → Deploy unified_template only
   │         (Resources discovered via Fortinet-Role tags)
   │
   └─ NO → Continue to question 2

2. Do you need a complete lab environment for testing?
   ├─ YES → Deploy existing_vpc_resources (all components)
   │         Then deploy unified_template
   │         See: Lab Environment Pattern
   │
   └─ NO → Continue to question 3

3. Do you need centralized management (FortiManager/FortiAnalyzer)?
   ├─ YES → Deploy existing_vpc_resources (with management VPC)
   │         Then deploy unified_template
   │         See: Management VPC Pattern
   │
   └─ NO → Deploy existing_vpc_resources (inspection VPC only)
           Then deploy unified_template
           See: Minimal Deployment Pattern
```

{{% notice info %}}
**Key Point**: The `unified_template` always requires an existing Inspection VPC with `Fortinet-Role` tags. Use `existing_vpc_resources` to create this infrastructure, or manually tag your existing VPCs.
{{% /notice %}}

---

## Template Comparison

| Aspect | existing_vpc_resources | unified_template |
|--------|----------------------|------------------|
| **Required?** | Yes (creates Inspection VPC) | Yes (deploys FortiGate) |
| **Run Order** | First | Second |
| **Purpose** | VPC infrastructure with Fortinet-Role tags | FortiGate autoscale deployment |
| **Creates** | Inspection VPC, Management VPC, TGW, Spoke VPCs | FortiGate ASG, GWLB, Lambda, route modifications |
| **Discovery** | N/A (creates resources) | Uses Fortinet-Role tags |
| **Cost** | VPC infrastructure costs | FortiGate instance costs |
| **Lifecycle** | Persistent infrastructure | Can be redeployed independently |
| **Production Use** | Yes (or tag existing VPCs) | Always |

---

## Common Integration Patterns

### Pattern 1: Complete Lab Environment

**Use case**: Full-featured testing environment with management and traffic generation

**Templates needed**:
1. ✅ existing_vpc_resources (with all components enabled including Inspection VPC)
2. ✅ unified_template (deploys into Inspection VPC via Fortinet-Role tags)

**What you get**:
- Inspection VPC with Fortinet-Role tags for resource discovery
- Management VPC with FortiManager, FortiAnalyzer, and Jump Box
- Transit Gateway with spoke VPCs
- Linux instances for traffic generation
- FortiGate autoscale group with GWLB
- Complete end-to-end testing environment

**Estimated cost**: ~$300-400/month for complete lab

**Deployment time**: ~25-30 minutes

**Next steps**: [Lab Environment Workflow](#lab-environment-workflow)

---

### Pattern 2: Production Integration (Existing VPCs)

**Use case**: Deploy FortiGate inspection to existing production infrastructure

**Templates needed**:
1. ⚠️ Manual tagging of existing VPCs with Fortinet-Role tags, OR
1. ✅ existing_vpc_resources (inspection VPC only, to create properly tagged infrastructure)
2. ✅ unified_template (discovers resources via Fortinet-Role tags)

**Prerequisites**:
- Existing VPCs must have `Fortinet-Role` tags (see [Required Tags](#required-fortinet-role-tags))
- OR use existing_vpc_resources to create new Inspection VPC with correct tags
- Network connectivity established

**What you get**:
- FortiGate autoscale group with GWLB deployed into existing/tagged VPC
- Integration with existing Transit Gateway
- Tag-based resource discovery for flexibility

**Estimated cost**: ~$150-250/month (FortiGates only, plus any new VPC infrastructure)

**Deployment time**: ~15-20 minutes (plus tagging time if manual)

**Next steps**: [Production Integration Workflow](#production-integration-workflow)

---

### Pattern 3: Management VPC Only

**Use case**: Testing FortiManager/FortiAnalyzer integration without spoke VPCs

**Templates needed**:
1. ✅ existing_vpc_resources (Inspection VPC + management VPC components)
2. ✅ unified_template (with FortiManager integration enabled)

**What you get**:
- Inspection VPC with Fortinet-Role tags
- Dedicated management VPC with FortiManager and FortiAnalyzer
- FortiGate autoscale group managed by FortiManager
- No Transit Gateway or spoke VPCs

**Estimated cost**: ~$300/month

**Deployment time**: ~20-25 minutes

**Next steps**: [Management VPC Workflow](#management-vpc-workflow)

---

### Pattern 4: Minimal Inspection VPC Only

**Use case**: Simplest deployment for testing FortiGate autoscale

**Templates needed**:
1. ✅ existing_vpc_resources (Inspection VPC only)
2. ✅ unified_template (without TGW attachment)

**Configuration**:
```hcl
# existing_vpc_resources
enable_build_inspection_vpc   = true
enable_build_management_vpc   = false
enable_build_existing_subnets = false
```

**What you get**:
- Inspection VPC with Fortinet-Role tags
- FortiGate autoscale group with GWLB
- No management infrastructure or spoke VPCs

**Estimated cost**: ~$150-200/month

**Deployment time**: ~15 minutes

**Next steps**: [Minimal Deployment Workflow](#minimal-deployment-workflow)

---

## Required Fortinet-Role Tags

The `unified_template` discovers existing resources using `Fortinet-Role` tags. These tags are automatically created by `existing_vpc_resources`, or you can manually apply them to existing VPCs.

### Required Tags for Inspection VPC

| Resource Type | Fortinet-Role Tag Value | Required |
|---------------|-------------------------|----------|
| VPC | `{cp}-{env}-inspection-vpc` | Yes |
| Internet Gateway | `{cp}-{env}-inspection-igw` | Yes |
| Public Subnet AZ1 | `{cp}-{env}-inspection-public-az1` | Yes |
| Public Subnet AZ2 | `{cp}-{env}-inspection-public-az2` | Yes |
| GWLBE Subnet AZ1 | `{cp}-{env}-inspection-gwlbe-az1` | Yes |
| GWLBE Subnet AZ2 | `{cp}-{env}-inspection-gwlbe-az2` | Yes |
| Private Subnet AZ1 | `{cp}-{env}-inspection-private-az1` | Yes |
| Private Subnet AZ2 | `{cp}-{env}-inspection-private-az2` | Yes |
| Public Route Table AZ1 | `{cp}-{env}-inspection-public-rt-az1` | Yes |
| Public Route Table AZ2 | `{cp}-{env}-inspection-public-rt-az2` | Yes |
| GWLBE Route Table AZ1 | `{cp}-{env}-inspection-gwlbe-rt-az1` | Yes |
| GWLBE Route Table AZ2 | `{cp}-{env}-inspection-gwlbe-rt-az2` | Yes |
| Private Route Table AZ1 | `{cp}-{env}-inspection-private-rt-az1` | Yes |
| Private Route Table AZ2 | `{cp}-{env}-inspection-private-rt-az2` | Yes |
| NAT Gateway AZ1 | `{cp}-{env}-inspection-natgw-az1` | If nat_gw mode |
| NAT Gateway AZ2 | `{cp}-{env}-inspection-natgw-az2` | If nat_gw mode |
| Mgmt Subnet AZ1 | `{cp}-{env}-inspection-management-az1` | If dedicated mgmt ENI |
| Mgmt Subnet AZ2 | `{cp}-{env}-inspection-management-az2` | If dedicated mgmt ENI |
| Mgmt Route Table AZ1 | `{cp}-{env}-inspection-management-rt-az1` | If dedicated mgmt ENI |
| Mgmt Route Table AZ2 | `{cp}-{env}-inspection-management-rt-az2` | If dedicated mgmt ENI |
| TGW Attachment | `{cp}-{env}-inspection-tgw-attachment` | If TGW enabled |
| TGW Route Table | `{cp}-{env}-inspection-tgw-rtb` | If TGW enabled |

**Example**: For `cp="acme"` and `env="test"`, the VPC tag would be `acme-test-inspection-vpc`

### Optional Tags for Management VPC

| Resource Type | Fortinet-Role Tag Value | Required |
|---------------|-------------------------|----------|
| VPC | `{cp}-{env}-management-vpc` | If dedicated mgmt VPC |
| Public Subnet AZ1 | `{cp}-{env}-management-public-az1` | If dedicated mgmt VPC |
| Public Subnet AZ2 | `{cp}-{env}-management-public-az2` | If dedicated mgmt VPC |

---

## Deployment Workflows

### Lab Environment Workflow

**Objective**: Create complete testing environment from scratch

```bash
# Step 1: Deploy existing_vpc_resources (creates Inspection VPC with Fortinet-Role tags)
cd terraform/existing_vpc_resources
cp terraform.tfvars.example terraform.tfvars
# Edit: Enable all components:
#   enable_build_inspection_vpc   = true
#   enable_build_management_vpc   = true
#   enable_build_existing_subnets = true
#   enable_fortimanager           = true
#   enable_fortianalyzer          = true
terraform init && terraform apply

# Step 2: Note outputs (Fortinet-Role tags created automatically)
terraform output  # Save TGW name and FortiManager IP

# Step 3: Deploy unified_template (discovers VPCs via Fortinet-Role tags)
cd ../unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: Use SAME cp and env values (critical for tag discovery)
#       Set attach_to_tgw_name from Step 2 output
#       Configure FortiManager integration
terraform init && terraform apply

# Step 4: Verify
ssh -i ~/.ssh/keypair.pem ec2-user@<jump-box-ip>
curl http://<linux-instance-ip>  # Test connectivity
```

**Time to complete**: 30-40 minutes

{{% notice warning %}}
**Critical**: The `cp` and `env` variables must match between both templates for Fortinet-Role tag discovery to work.
{{% /notice %}}

**See detailed guide**: [existing_vpc_resources Template](../5_2_existing_vpc_resources/)

---

### Production Integration Workflow

**Objective**: Deploy FortiGate inspection into existing or new Inspection VPC

**Option A: Tag Existing VPCs Manually**

If you have existing VPCs you want to use:
1. Apply Fortinet-Role tags to your existing VPC resources (see [Required Tags](#required-fortinet-role-tags))
2. Deploy unified_template with matching `cp` and `env` values

**Option B: Create New Inspection VPC (Recommended)**

```bash
# Step 1: Deploy existing_vpc_resources (Inspection VPC only)
cd terraform/existing_vpc_resources
cp terraform.tfvars.example terraform.tfvars
# Edit:
#   enable_build_inspection_vpc   = true
#   enable_build_management_vpc   = false
#   enable_build_existing_subnets = true  # if TGW needed
#   attach_to_tgw_name            = "production-tgw"  # existing TGW
terraform init && terraform apply

# Step 2: Deploy unified_template
cd ../unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: Use SAME cp and env values
#       Set attach_to_tgw_name to production TGW
#       Configure production-appropriate capacity
terraform init && terraform apply

# Step 3: Update TGW route tables (if needed)
# Route spoke VPC traffic (0.0.0.0/0) to inspection VPC attachment

# Step 4: Test and validate
# Verify traffic flows through FortiGate
```

**Time to complete**: 20-30 minutes

**See detailed guide**: [unified_template](../5_3_unified_template/)

---

### Management VPC Workflow

**Objective**: Deploy management infrastructure with FortiManager/FortiAnalyzer

```bash
# Step 1: Deploy existing_vpc_resources (Inspection + Management VPCs)
cd terraform/existing_vpc_resources
cp terraform.tfvars.example terraform.tfvars
# Edit:
#   enable_build_inspection_vpc   = true
#   enable_build_management_vpc   = true
#   enable_fortimanager           = true
#   enable_fortianalyzer          = true
#   enable_build_existing_subnets = false
terraform init && terraform apply

# Step 2: Configure FortiManager
# Access FortiManager GUI: https://<fmgr-ip>
# Enable VM device recognition if FMG 7.6.3+
config system global
    set fgfm-allow-vm enable
end

# Step 3: Deploy unified_template
cd ../unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: Use SAME cp and env values
#       enable_fortimanager_integration = true
#       fortimanager_ip = <from Step 1 output>
#       enable_dedicated_management_vpc = true
terraform init && terraform apply

# Step 4: Authorize devices on FortiManager
# Device Manager > Device & Groups
# Right-click unauthorized device > Authorize
```

**Time to complete**: 25-35 minutes

---

### Minimal Deployment Workflow

**Objective**: Deploy FortiGate with minimal infrastructure

```bash
# Step 1: Deploy existing_vpc_resources (Inspection VPC only)
cd terraform/existing_vpc_resources
cp terraform.tfvars.example terraform.tfvars
# Edit:
#   enable_build_inspection_vpc   = true
#   enable_build_management_vpc   = false
#   enable_build_existing_subnets = false
#   inspection_access_internet_mode = "eip"  # simpler, lower cost
terraform init && terraform apply

# Step 2: Deploy unified_template
cd ../unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: Use SAME cp and env values
#       enable_tgw_attachment = false
#       access_internet_mode = "eip"
terraform init && terraform apply

# Step 3: Note GWLB endpoint IDs for spoke VPC integration
terraform output gwlb_endpoint_az1_id
terraform output gwlb_endpoint_az2_id

# Step 4: Integrate spoke VPCs
# Deploy GWLB endpoints in spoke VPCs
# Update spoke VPC route tables to point to GWLB endpoints
```

**Time to complete**: 20-25 minutes (plus spoke VPC endpoint deployment)

---

## When to Use Each Template

### existing_vpc_resources - Always Required First

The `existing_vpc_resources` template is required to create the Inspection VPC with proper `Fortinet-Role` tags. Use it when:

✅ **Any new FortiGate autoscale deployment**
- Creates Inspection VPC with all required subnets and tags
- Can optionally include Management VPC, TGW, and spoke VPCs
- Provides foundation for `unified_template` deployment

✅ **Creating a lab or test environment**
- Enable all components for complete testing environment
- Includes FortiManager/FortiAnalyzer for management testing
- Traffic generators in spoke VPCs for load testing

✅ **Production deployments with new infrastructure**
- Creates properly tagged VPCs for FortiGate deployment
- Can attach to existing Transit Gateway
- Separates VPC lifecycle from FortiGate lifecycle

### Alternative to existing_vpc_resources:

⚠️ **Manually tag existing VPCs** (advanced users only)
- Apply `Fortinet-Role` tags to existing VPCs following the tag schema
- Ensures all required resources (subnets, route tables, IGW, etc.) are properly tagged
- Useful when you cannot create new VPCs

### unified_template - Always Required Second

The `unified_template` deploys FortiGate into the existing Inspection VPC:

✅ **All FortiGate autoscale deployments**
- Discovers Inspection VPC via Fortinet-Role tags
- Deploys FortiGate ASG, GWLB, Lambda functions
- Modifies route tables to enable traffic inspection

✅ **Can be redeployed independently**
- Inspection VPC persists between FortiGate redeployments
- Allows FortiGate version upgrades without VPC changes
- Simplifies lifecycle management

---

## Template Variable Coordination

When using both templates together, **certain variables must match exactly** for Fortinet-Role tag discovery to work:

### Critical Variables for Tag Discovery

| Variable | Purpose | Impact if Mismatched |
|----------|---------|---------------------|
| `cp` (customer prefix) | Fortinet-Role tag prefix | **unified_template cannot find VPCs** |
| `env` (environment) | Fortinet-Role tag prefix | **unified_template cannot find VPCs** |
| `aws_region` | AWS region | Resources in wrong region |
| `availability_zone_1` | First AZ | Subnet discovery fails |
| `availability_zone_2` | Second AZ | Subnet discovery fails |

{{% notice warning %}}
**Critical**: The `cp` and `env` variables form the prefix for all Fortinet-Role tags. If these don't match between templates, the `unified_template` will fail with "no matching VPC/Subnet found" errors.
{{% /notice %}}

### Example Coordinated Configuration

**existing_vpc_resources/terraform.tfvars**:
```hcl
aws_region          = "us-west-2"
availability_zone_1 = "a"
availability_zone_2 = "c"
cp                  = "acme"      # Creates tags like "acme-test-inspection-vpc"
env                 = "test"
vpc_cidr_ns_inspection = "10.0.0.0/16"
vpc_cidr_management    = "10.3.0.0/16"
```

**unified_template/terraform.tfvars**:
```hcl
aws_region          = "us-west-2"  # MUST MATCH
availability_zone_1 = "a"          # MUST MATCH
availability_zone_2 = "c"          # MUST MATCH
cp                  = "acme"       # MUST MATCH - used for tag lookup
env                 = "test"       # MUST MATCH - used for tag lookup
vpc_cidr_inspection = "10.0.0.0/16"  # Should match existing VPC CIDR
vpc_cidr_management = "10.3.0.0/16"  # Should match if using management VPC

attach_to_tgw_name = "acme-test-tgw"  # Matches cp-env naming convention
```

### How Tag Discovery Works

When `unified_template` runs, it looks up resources like this:

```hcl
# unified_template/vpc_inspection.tf
data "aws_vpc" "inspection" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-vpc"]  # e.g., "acme-test-inspection-vpc"
  }
}
```

This is why matching `cp` and `env` values is essential.

---

## Next Steps

Choose your deployment pattern and proceed to the appropriate template guide:

1. **Lab/Test Environment**: Start with [existing_vpc_resources Template](../5_2_existing_vpc_resources/)
2. **Production Deployment**: Go directly to [unified_template](../5_3_unified_template/)
3. **Need to review components?**: See [Solution Components](../../4_solution_components/)
4. **Need licensing guidance?**: See [Licensing Options](../../3_licensing/)

---

## Summary

The FortiGate Autoscale Simplified Template uses a two-phase deployment approach with Fortinet-Role tag discovery:

| Template | Purpose | Run Order | Creates |
|----------|---------|-----------|---------|
| existing_vpc_resources | VPC infrastructure | First | Inspection VPC, Management VPC, TGW, Spoke VPCs (with Fortinet-Role tags) |
| unified_template | FortiGate deployment | Second | FortiGate ASG, GWLB, Lambda (discovers VPCs via tags) |

**Key Principles**:
1. **Run existing_vpc_resources first** - Creates Inspection VPC with Fortinet-Role tags
2. **Match cp and env values** - Critical for tag discovery between templates
3. **unified_template deploys into existing VPCs** - Does not create VPC infrastructure

**Recommended Starting Point**:
- First-time users: Deploy both templates for complete lab environment
- Production deployments: Use existing_vpc_resources for new Inspection VPC, or manually tag existing VPCs
- All deployments: Ensure `cp` and `env` match between templates
