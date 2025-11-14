---
title: "Templates Overview"
chapter: false
menuTitle: "Overview"
weight: 51
---

## Introduction

The FortiGate Autoscale Simplified Template consists of two complementary Terraform templates that work together to deploy a complete FortiGate autoscale architecture in AWS:

1. **[existing_vpc_resources](../5_2_existing_vpc_resources/)** (Optional): Creates supporting infrastructure for testing, demonstration, and lab environments
2. **[unified_template](../5_3_unified_template/)** (Required): Deploys the FortiGate autoscale group and inspection VPC

This modular approach allows you to:
- Deploy only the inspection VPC to integrate with existing production environments
- Create a complete lab environment including management VPC, Transit Gateway, and spoke VPCs with traffic generators
- Mix and match components based on your specific requirements

---

## Template Architecture

### Component Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│ existing_vpc_resources Template (Optional)                      │
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
└──────────────────────┼──────────────────────────────────────────┘
                       │ (Connects via TGW)
┌──────────────────────┼──────────────────────────────────────────┐
│ unified_template (Required)     │                               │
│                      │                                          │
│  ┌────────────────── ▼ ────────────────┐                        │
│  │ Inspection VPC                      │                        │
│  │ - FortiGate Autoscale Group         │                        │
│  │ - Gateway Load Balancer             │                        │
│  │ - GWLB Endpoints                    │                        │
│  │ - Lambda Functions                  │                        │
│  └─────────────────────────────────────┘                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Decision Tree

Use this decision tree to determine which template(s) you need:

```
1. Do you have existing AWS infrastructure (VPCs, Transit Gateway, workloads)?
   ├─ YES → Skip existing_vpc_resources
   │         Deploy only unified_template
   │         See: Production Integration Pattern
   │
   └─ NO → Continue to question 2

2. Do you need a complete lab environment for testing?
   ├─ YES → Deploy both templates
   │         See: Lab Environment Pattern
   │
   └─ NO → Continue to question 3

3. Do you need centralized management (FortiManager/FortiAnalyzer)?
   ├─ YES → Deploy existing_vpc_resources (management VPC only)
   │         Then deploy unified_template
   │         See: Management VPC Pattern
   │
   └─ NO → Deploy only unified_template
           See: Minimal Deployment Pattern
```

---

## Template Comparison

| Aspect | existing_vpc_resources | unified_template |
|--------|----------------------|------------------|
| **Required?** | Optional | Required |
| **Purpose** | Supporting infrastructure | FortiGate inspection VPC |
| **Best For** | Lab/test environments | All deployments |
| **Components** | Management VPC, TGW, Spoke VPCs | FortiGate ASG, GWLB, Lambda |
| **Cost** | Medium-High (FortiManager/FortiAnalyzer) | Medium (FortiGate instances) |
| **Lifecycle** | Can be persistent | Typically ephemeral |
| **Production Use** | Rarely | Always |

---

## Common Integration Patterns

### Pattern 1: Complete Lab Environment

**Use case**: Full-featured testing environment with management and traffic generation

**Templates needed**:
1. ✅ existing_vpc_resources (with all components enabled)
2. ✅ unified_template (connects to created TGW)

**What you get**:
- Management VPC with FortiManager, FortiAnalyzer, and Jump Box
- Transit Gateway with spoke VPCs
- Linux instances for traffic generation
- FortiGate autoscale group with GWLB
- Complete end-to-end testing environment

**Estimated cost**: ~$300-400/month for complete lab

**Deployment time**: ~25-30 minutes

**Next steps**: [Lab Environment Workflow](#lab-environment-workflow)

---

### Pattern 2: Production Integration

**Use case**: Deploy FortiGate inspection to existing production infrastructure

**Templates needed**:
1. ❌ existing_vpc_resources (skip entirely)
2. ✅ unified_template (connects to existing TGW)

**Prerequisites**:
- Existing Transit Gateway
- Existing workload VPCs
- Network connectivity established

**What you get**:
- FortiGate autoscale group with GWLB
- Integration with existing Transit Gateway
- Minimal infrastructure changes

**Estimated cost**: ~$150-250/month (FortiGates only)

**Deployment time**: ~15-20 minutes

**Next steps**: [Production Integration Workflow](#production-integration-workflow)

---

### Pattern 3: Management VPC Only

**Use case**: Testing FortiManager/FortiAnalyzer integration without spoke VPCs

**Templates needed**:
1. ✅ existing_vpc_resources (management VPC components only)
2. ✅ unified_template (with FortiManager integration enabled)

**What you get**:
- Dedicated management VPC with FortiManager and FortiAnalyzer
- FortiGate autoscale group managed by FortiManager
- No Transit Gateway or spoke VPCs

**Estimated cost**: ~$300/month

**Deployment time**: ~20-25 minutes

**Next steps**: [Management VPC Workflow](#management-vpc-workflow)

---

### Pattern 4: Distributed Inspection (No TGW)

**Use case**: Bump-in-the-wire inspection for distributed architecture

**Templates needed**:
1. ❌ existing_vpc_resources (skip entirely)
2. ✅ unified_template (without TGW attachment)

**Prerequisites**:
- Existing spoke VPCs with their own internet gateways
- GWLB endpoints deployed in spoke VPCs (separate process)

**What you get**:
- FortiGate autoscale group with GWLB
- Endpoints available for spoke VPC integration
- No centralized Transit Gateway

**Estimated cost**: ~$150-200/month

**Deployment time**: ~15 minutes

**Next steps**: [Distributed Inspection Workflow](#distributed-inspection-workflow)

---

## Deployment Workflows

### Lab Environment Workflow

**Objective**: Create complete testing environment from scratch

```bash
# Step 1: Deploy existing_vpc_resources
cd terraform/existing_vpc_resources
cp terraform.tfvars.example terraform.tfvars
# Edit: Enable all components (FortiManager, FortiAnalyzer, TGW, Spoke VPCs)
terraform init && terraform apply

# Step 2: Note outputs
terraform output  # Save TGW name and FortiManager IP

# Step 3: Deploy unified_template  
cd ../unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: Set attach_to_tgw_name from Step 2 output
#       Use same cp and env values
#       Configure FortiManager integration
terraform init && terraform apply

# Step 4: Verify
ssh -i ~/.ssh/keypair.pem ec2-user@<jump-box-ip>
curl http://<linux-instance-ip>  # Test connectivity
```

**Time to complete**: 30-40 minutes

**See detailed guide**: [existing_vpc_resources Template](../5_2_existing_vpc_resources/)

---

### Production Integration Workflow

**Objective**: Deploy inspection VPC to existing production Transit Gateway

```bash
# Step 1: Identify existing resources
aws ec2 describe-transit-gateways --query 'TransitGateways[*].[Tags[?Key==`Name`].Value|[0],TransitGatewayId]'
# Note your production TGW name

# Step 2: Deploy unified_template
cd terraform/unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: Set attach_to_tgw_name to production TGW
#       Configure production-appropriate capacity
#       Use BYOL or FortiFlex for cost optimization
terraform init && terraform apply

# Step 3: Update TGW route tables
# Route spoke VPC traffic (0.0.0.0/0) to inspection VPC attachment
# via AWS Console or CLI

# Step 4: Test and validate
# Verify traffic flows through FortiGate
# Check FortiGate logs and CloudWatch metrics
```

**Time to complete**: 20-30 minutes (plus TGW routing configuration)

**See detailed guide**: [unified_template](../5_3_unified_template/)

---

### Management VPC Workflow

**Objective**: Deploy management infrastructure with FortiManager/FortiAnalyzer

```bash
# Step 1: Deploy existing_vpc_resources (management only)
cd terraform/existing_vpc_resources
cp terraform.tfvars.example terraform.tfvars
# Edit: enable_build_management_vpc = true
#       enable_fortimanager = true
#       enable_fortianalyzer = true
#       enable_build_existing_subnets = false
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
# Edit: enable_fortimanager_integration = true
#       fortimanager_ip = <from Step 1 output>
#       enable_dedicated_management_vpc = true
terraform init && terraform apply

# Step 4: Authorize devices on FortiManager
# Device Manager > Device & Groups
# Right-click unauthorized device > Authorize
```

**Time to complete**: 25-35 minutes

---

### Distributed Inspection Workflow

**Objective**: Deploy FortiGate without Transit Gateway

```bash
# Step 1: Deploy unified_template
cd terraform/unified_template
cp terraform.tfvars.example terraform.tfvars
# Edit: enable_tgw_attachment = false
#       firewall_policy_mode = "1-arm" (recommended)
terraform init && terraform apply

# Step 2: Note GWLB endpoint IDs
terraform output gwlb_endpoint_az1_id
terraform output gwlb_endpoint_az2_id

# Step 3: Deploy GWLB endpoints in spoke VPCs
# (Separate Terraform or CloudFormation process)
# Update spoke VPC route tables to point to GWLB endpoints

# Step 4: Test traffic flow
# Verify spoke VPC traffic routes through FortiGate
```

**Time to complete**: 20-25 minutes (plus spoke VPC endpoint deployment)

---

## When to Use Each Template

### Use existing_vpc_resources When:

✅ **Creating a lab or test environment from scratch**
- Need complete isolated environment
- Want to test all features including FortiManager/FortiAnalyzer
- Require traffic generation for load testing

✅ **Demonstrating FortiGate autoscale capabilities**
- Sales Engineering demonstrations
- Proof-of-concept deployments
- Training and enablement sessions

✅ **Need centralized management infrastructure**
- First-time FortiManager deployment
- Want persistent management VPC separate from inspection VPC
- Require FortiAnalyzer for logging/reporting

### Skip existing_vpc_resources When:

❌ **Deploying to production**
- Existing Transit Gateway and VPCs available
- Integration with established workloads required
- Management infrastructure already exists

❌ **Cost-sensitive testing**
- FortiManager/FortiAnalyzer not needed for specific tests
- Minimal viable deployment preferred
- Short-term testing (< 1 week)

❌ **Distributed inspection architecture**
- No Transit Gateway in design
- Spoke VPCs have their own internet gateways
- Bump-in-the-wire pattern preferred

---

## Template Variable Coordination

When using both templates together, **certain variables must match** for proper integration:

### Must Match Between Templates

| Variable | Purpose | Impact if Mismatched |
|----------|---------|---------------------|
| `aws_region` | AWS region | Resources created in wrong region |
| `availability_zone_1` | First AZ | Subnets in different AZs |
| `availability_zone_2` | Second AZ | Subnets in different AZs |
| `cp` (customer prefix) | Resource naming | Tag-based discovery fails |
| `env` (environment) | Resource naming | Tag-based discovery fails |
| `vpc_cidr_management` | Management VPC CIDR | Routing conflicts |
| `vpc_cidr_spoke` | Spoke VPC supernet | Routing conflicts |

### Example Coordinated Configuration

**existing_vpc_resources/terraform.tfvars**:
```hcl
aws_region          = "us-west-2"
availability_zone_1 = "a"
availability_zone_2 = "c"
cp                  = "acme"
env                 = "test"
vpc_cidr_management = "10.3.0.0/16"
```

**unified_template/terraform.tfvars**:
```hcl
aws_region          = "us-west-2"  # MUST MATCH
availability_zone_1 = "a"          # MUST MATCH
availability_zone_2 = "c"          # MUST MATCH
cp                  = "acme"       # MUST MATCH
env                 = "test"       # MUST MATCH
vpc_cidr_management = "10.3.0.0/16"  # MUST MATCH

attach_to_tgw_name = "acme-test-tgw"  # Matches cp-env naming
```

---

## Next Steps

Choose your deployment pattern and proceed to the appropriate template guide:

1. **Lab/Test Environment**: Start with [existing_vpc_resources Template](../5_2_existing_vpc_resources/)
2. **Production Deployment**: Go directly to [unified_template](../5_3_unified_template/)
3. **Need to review components?**: See [Solution Components](../../4_solution_components/)
4. **Need licensing guidance?**: See [Licensing Options](../../3_licensing/)

---

## Summary

The FortiGate Autoscale Simplified Template provides flexible deployment options through two complementary templates:

| Template | Required? | Best For | Deploy When |
|----------|-----------|----------|-------------|
| existing_vpc_resources | Optional | Lab/test environments | Creating complete test environment or need management VPC |
| unified_template | Required | All deployments | Every deployment - integrates with existing or created resources |

**Key Principle**: Start with the simplest deployment that meets your requirements. You can always add complexity later.

**Recommended Starting Point**: 
- First-time users: Deploy both templates for complete lab environment
- Production deployments: Skip to unified_template with existing infrastructure
- Cost-conscious testing: Deploy unified_template only with minimal capacity
