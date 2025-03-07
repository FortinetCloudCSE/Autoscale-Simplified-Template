---
title: "Overview"
menuTitle: "Overview"
weight: 20
---

FortiOS supports native AWS Autoscaling. This provides horizontal scaling of a FortiGate Cluster in AWS. The autoscale cluster uses the AWS GatewayLoadBalancer (GWLB) to distribute traffic to the FortiGate instances. The FortiGate Autoscale cluster is monitored by the native AWS autoscale feature and if the cluster size is below the minimum size, new instances are launched. If the cluster size is above the maximum size, instances are terminated. When they are launched or terminated, they will be added to the target groups of associated load balancers and will assist with traffic inspection and increase the capacity of the autoscale group as a whole. 

The main benefits of this solution are:
  - Horizontal scaling of a FortiGate cluster in AWS
  - Support for a flexible licensing scheme including BYOL and FortiFlex licenses for static instances and PAYGO for autoscale instances
  - Configuration Sync between FortiGate instances in the cluster
  - FortiManager integration for centralized management of the FortiGate Autoscale Cluster
  - Deployment options for a centralized inspection architecture or a distributed inspection architecture (coming soon)
  - Support for egress traffic NAT behind an Elastic IP (EIP) for all instances in the cluster. 
  - Support for egress traffic behind a NAT Gateway for all instances in the cluster.

**Note:**  Other Fortinet solutions for AWS such as FGCP HA (Single AZ), AutoScaling, and Transit Gateway are available.  Please visit [www.fortinet.com/aws](https://www.fortinet.com/aws) for further information.