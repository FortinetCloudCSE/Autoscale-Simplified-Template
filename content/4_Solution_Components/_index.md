---
title: "Solution Components"
chapter: true
menuTitle: "Solution Components"
weight: 40
---

The FortiGate Autoscale Simplified Template abstracts complex architectural patterns into configurable components that can be enabled or customized through the `terraform.tfvars` file. 

This section provides detailed explanations of each component, configuration options, and architectural considerations to help you design the optimal deployment for your requirements.

## What You'll Learn

This section covers the major architectural elements available in the template:

- **Internet Egress Options**: Choose between EIP or NAT Gateway architectures
- **Firewall Architecture**: Understand 1-ARM vs 2-ARM configurations
- **Management Isolation**: Configure dedicated management ENI and VPC options
- **Licensing**: Manage BYOL licenses and integrate FortiFlex API
- **FortiManager Integration**: Enable centralized management and policy orchestration
- **Capacity Planning**: Configure autoscale group sizing and scaling strategies
- **Primary Protection**: Implement scale-in protection for configuration stability
- **Additional Options**: Fine-tune instance specifications and advanced settings

Each component page includes:
- Configuration examples
- Architecture diagrams
- Best practices
- Troubleshooting guidance
- Use case recommendations

---

Select a component from the navigation menu to learn more about specific configuration options.
