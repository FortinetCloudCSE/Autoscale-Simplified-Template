---
title: "FortiGate Bootstrap Configuration"
chapter: false
menuTitle: "Bootstrap Config"
weight: 55
---

## Overview

Each FortiGate instance launched by the autoscale group receives a bootstrap configuration on first boot. This configuration establishes the GENEVE tunnel zones, static routes, router policies, firewall policies, and system settings required for the instance to begin inspecting traffic immediately without manual intervention.

The bootstrap configuration is defined in Terraform template files (`.tftpl`) located in `terraform/autoscale_template/`. Terraform renders the appropriate file at plan time, injects the result into the autoscale module as `user_conf_content`, and the Lambda function delivers it to each new FortiGate instance during the launch sequence.

---

## Template File Selection

The correct `.tftpl` file is selected automatically based on two `terraform.tfvars` settings: `firewall_policy_mode` and the management interface mode. Terraform builds the filename using these two locals in `autoscale_group.tf`:

```hcl
locals {
  dedicated_mgmt = var.enable_dedicated_management_vpc ? "-wdm"
                 : var.enable_dedicated_management_eni ? "-wdm-eni"
                 : ""
}
locals {
  fgt_config_template = "${path.module}/${var.firewall_policy_mode}${local.dedicated_mgmt}-fgt-conf.cfg.tftpl"
}
```

The filename pattern is:

```
{firewall_policy_mode}{dedicated_mgmt}-fgt-conf.cfg.tftpl
```

The six template files and when each is used:

| File | `firewall_policy_mode` | Management Mode |
|------|------------------------|-----------------|
| `1-arm-fgt-conf.cfg.tftpl` | `1-arm` | None |
| `1-arm-wdm-fgt-conf.cfg.tftpl` | `1-arm` | Dedicated Management VPC |
| `1-arm-wdm-eni-fgt-conf.cfg.tftpl` | `1-arm` | Dedicated Management ENI |
| `2-arm-fgt-conf.cfg.tftpl` | `2-arm` | None |
| `2-arm-wdm-fgt-conf.cfg.tftpl` | `2-arm` | Dedicated Management VPC |
| `2-arm-wdm-eni-fgt-conf.cfg.tftpl` | `2-arm` | Dedicated Management ENI |

{{% notice info %}}
**1-arm vs 2-arm**: In 1-arm mode, all traffic (management and inspection) flows through `port1`. In 2-arm mode, `port1` handles internet/management traffic and `port2` handles internal/GENEVE inspection traffic.
{{% /notice %}}

---

## Dynamic AZ Rendering

The selected template is rendered by Terraform's `templatefile()` function, which passes the `az_list` variable:

```hcl
locals {
  az_list = var.availability_zone_3 != "" ? ["az1", "az2", "az3"] : ["az1", "az2"]
}
```

```hcl
user_conf_content = templatefile(local.fgt_config_template, { az_list = local.az_list })
```

`az_list` is either `["az1", "az2"]` for a standard 2-AZ deployment or `["az1", "az2", "az3"]` when `availability_zone_3` is set in `terraform.tfvars`. Terraform renders the template once at plan time and embeds the fully rendered FortiOS CLI text into the deployment — the FortiGate instances themselves receive plain CLI, not template syntax.

---

## Template Syntax

The `.tftpl` files are standard FortiOS CLI with two Terraform templating constructs added for AZ-specific configuration.

### For Loop

Used for any configuration block that requires one entry per AZ — static routes, router policies, and GENEVE interface references:

```
%{ for az in az_list ~}
    edit 0
        set dst 192.168.0.0 255.255.0.0
        set distance 5
        set priority 100
        set device "geneve-${az}"
    next
%{ endfor ~}
```

For a 2-AZ deployment this renders as:

```
    edit 0
        set dst 192.168.0.0 255.255.0.0
        set distance 5
        set priority 100
        set device "geneve-az1"
    next
    edit 0
        set dst 192.168.0.0 255.255.0.0
        set distance 5
        set priority 100
        set device "geneve-az2"
    next
```

For a 3-AZ deployment a third entry for `geneve-az3` is automatically appended.

### Inline Expression

Used to build a space-separated list of interface names in a single CLI line — specifically for the system zone `set interface` statement:

```
set interface ${join(" ", [for az in az_list : "\"geneve-${az}\""])}
```

For a 2-AZ deployment this renders as:

```
set interface "geneve-az1" "geneve-az2"
```

For a 3-AZ deployment:

```
set interface "geneve-az1" "geneve-az2" "geneve-az3"
```

---

## What the Default Templates Configure

Each template establishes the following on first boot:

| Configuration | Purpose |
|---------------|---------|
| `config system zone` — `private-zone` | Groups all GENEVE tunnel interfaces into a single zone for use in firewall policies |
| `config router static` (one per AZ) | Static route to `192.168.0.0/16` via each GENEVE tunnel for return traffic |
| `config router policy` (one per AZ) | Policy-based routing to ensure symmetric traffic flow per GENEVE tunnel |
| `config firewall policy` — `private_to_internet` | Allows inspected traffic from the private zone to the internet port with NAT |
| `config firewall policy` — `private_to_private` | Allows east-west traffic within the private zone without NAT |
| `config system global` | Disables upgrade warnings and sets admin lockout duration |
| `config system fortiguard` | Disables automatic firmware upgrade |
| `config system probe-response` | Enables HTTP probe response on port 8008 for GWLB health checks |
| `config system interface` | Configures port allowaccess settings |

{{% notice warning %}}
**Health Check Dependency**

The `config system probe-response` stanza is required for GWLB target group health checks to pass. Removing or modifying it will cause all FortiGate instances to fail health checks and be deregistered from the load balancer.
{{% /notice %}}

---

## Customizing the Bootstrap Configuration

Any FortiOS CLI configuration that can be applied via the CLI can be added to the `.tftpl` files. Edit the file that matches your deployment mode (see [Template File Selection](#template-file-selection) above).

### Adding Static Configuration

For configuration that does not vary per AZ — address objects, application signatures, custom firewall policies, DNS settings — add standard FortiOS CLI directly to the file. No template syntax is required:

```
config firewall address
    edit "internal-servers"
        set subnet 10.10.0.0 255.255.0.0
    next
end
config firewall policy
    edit 0
        set name "block-internal-to-internet"
        set srcintf "private-zone"
        set dstintf "port2"
        set srcaddr "internal-servers"
        set dstaddr "all"
        set action deny
        set schedule "always"
        set service "ALL"
        set logtraffic all
    next
end
```

### Adding Per-AZ Configuration

For configuration that requires one entry per AZ, use the `%{ for az in az_list ~}` / `%{ endfor ~}` loop. The `${az}` interpolation produces `az1`, `az2`, or `az3`:

```
config router static
%{ for az in az_list ~}
    edit 0
        set dst 10.50.0.0 255.255.0.0
        set device "geneve-${az}"
        set distance 10
    next
%{ endfor ~}
end
```

{{% notice info %}}
**Apply Changes to All Relevant Files**

If your deployment could use multiple modes (e.g. both 1-arm and 2-arm configurations are in use across environments), add your customizations to all relevant `.tftpl` files. The files are independent — a change to `2-arm-fgt-conf.cfg.tftpl` has no effect on `1-arm-fgt-conf.cfg.tftpl`.
{{% /notice %}}

### Redeploying After Changes

Changes to `.tftpl` files only take effect on **newly launched** FortiGate instances. The bootstrap configuration is delivered once at launch and is not re-applied to running instances. To roll out changes to an existing autoscale group:

1. Edit the appropriate `.tftpl` file
2. Run `terraform apply` — Terraform detects the `user_conf_content` change and updates the EC2 launch template
3. Terminate existing FortiGate instances one at a time — the autoscale group will replace each with a new instance using the updated bootstrap configuration

{{% notice warning %}}
**Running Instances Are Not Updated**

`terraform apply` updates the EC2 launch template used for new instances. It does not push configuration changes to running FortiGate instances. Use FortiManager or direct CLI to apply changes to instances that are already running.
{{% /notice %}}
