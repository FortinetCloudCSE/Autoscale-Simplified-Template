---
title: "Templates"
chapter: true
menuTitle: "Templates"
weight: 50
---

# Deployment Templates

The FortiGate Autoscale Simplified Template provides modular Terraform templates for deploying autoscale architectures in AWS. This section covers both templates and their integration patterns.

## Available Templates

### [Templates Overview](5_1_overview/)
Understand the template architecture, choose deployment patterns, and learn how templates work together.

### [existing_vpc_resources Template](5_2_existing_vpc_resources/) (Optional)
Create supporting infrastructure for lab and test environments including management VPC, Transit Gateway, and spoke VPCs with traffic generators.

### [unified_template](5_3_unified_template/) (Required)
Deploy the core FortiGate autoscale infrastructure including inspection VPC, Gateway Load Balancer, and FortiGate autoscale groups.

---

## Quick Start Paths

### For Lab/Test Environments
1. Start with [Templates Overview](5_1_overview/) to understand architecture
2. Deploy [existing_vpc_resources](5_2_existing_vpc_resources/) for complete test environment
3. Deploy [unified_template](5_3_unified_template/) connected to created resources
4. Time: ~30-40 minutes

### For Production Deployments
1. Review [Templates Overview](5_1_overview/) for integration patterns
2. Skip existing_vpc_resources template
3. Deploy [unified_template](5_3_unified_template/) to existing infrastructure
4. Time: ~15-20 minutes

---

## Template Coordination

When using both templates together, ensure these variables **match exactly**:
- `aws_region`
- `availability_zone_1` and `availability_zone_2`
- `cp` (customer prefix)
- `env` (environment)
- `vpc_cidr_management`
- `vpc_cidr_spoke`

See [Templates Overview](5_1_overview/) for detailed coordination requirements.

---

## What's Next?

- **New to autoscale?** Start with [Templates Overview](5_1_overview/)
- **Need lab environment?** Go to [existing_vpc_resources](5_2_existing_vpc_resources/)
- **Ready to deploy?** Go to [unified_template](5_3_unified_template/)
- **Need configuration details?** See [Solution Components](../4_solution_components/)
