---
title: "Templates"
chapter: false
menuTitle: "Templates"
weight: 40
---

#### Existing VPC Resources

The FortiGate Autoscale Simplified Template is designed to attach to an existing customer TGW that may have one or multiple "spoke VPC's". These spoke VPC's may have existing resources that run some sort of workloads that generate egress traffic to the public internet (North-South) or traffic that passes between spoke VPC's (East-West) that may or may not need inspection before being allowed to pass between spoke VPC's. If no firwall inspection is needed for a given workload, then the TGW route tables can be configured to route the traffic directly between the spoke VPC's. If inspection is needed, then the traffic can be routed to the FortiGate Autoscale Group for inspection. 

The "existing_vpc_resources" template is a template that creates the resources described above and can be used to create demo or testing resources to generate test traffic when testing the Autoscale templates in non-production environments. These templates create the following resources:





