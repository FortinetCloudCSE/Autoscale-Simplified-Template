---
title: "Solution Components"
chapter: false
menuTitle: "Solution Components"
weight: 40
---

#### Egress Options

The FortiGate Autoscale solution provides two options for egress traffic. The first option is to use an Elastic IP (EIP). Each instance in the autoscale group will have an associated EIP and NAT all traffic with a public internet destination behind the public IP associated with the EIP. This option is configured in the template terraform.tfvars file by setting the following variable to eip:

access_internet_mode = "eip"

This architecture routes all internet traffic to port2 and the default route for port2 in the public subnet is the IGW. The traffic is NAT'd to the associated EIP as it passes through the IGW. The EIP's used in the autoscale group are pulled from a pool owned by AWS and you will be unable to predict the value assigned. This can be a problem if you are NATing to a destination that wants to whitelist the source IP. On the other hand, using EIP's to NAT will avoid the cost of using NAT Gateways. 

![EIP Diagram](eip-diagram.png)

The second option is to use a NAT Gateway to NAT all traffic to the internet. This architecture will use a Public IP that does not change for the life of the NAT Gateway. This makes whitelisting at the destination, easier to implement. The NAT Gateway requires an extra subnet and route table to send the traffic to the NAT Gateway, prior to egress through the IGW. This option is configured in the template terraform.tfvars file by setting the following variable to nat_gw:

access_internet_mode = "nat_gw"

![NAT Gateway Diagram](nat-gw-diagram.png)

#### 2-ARM vs 1-ARM

A Fortigate can be deployed in a 2-ARM or 1-ARM configuration. This is controlled by setting the firewall_policy_mode variable in the terraform.tfvars to "1-arm" or "2-arm". 

![Firewall Policy Mode](firewall-mode.png)

The 2-ARM configuration is the most common and is used when you want to have a "trusted/private" port and an "untrusted/public" port. All traffic coming into the Fortigate will ingress through the GWLB Endpoints. The traffic this then forwarded to the Gateway Load Balancer and this allows load-balancing between all members of the autoscale group. Connectivity between the Gateway Load Balancer and Fortigate instances is via Geneve Tunnel encapsulation. The tunnels are terminated on Fortigate port1. The Fortigate in 2-arm mode, will forward traffic destined to the public internet to port2 and NAT out the EIP or NAT Gateway. 

In 1-arm mode, the Fortigate will only have one port for the Fortigate data plane. That means, ingress traffic will arrive at port1, but encapsulated in Geneve. If the destination is the public internet, the Fortigate will remove the Geneve encapsulation and hairpin the traffic back to port1 and egress to the internet. The tunnels using Geneve encapsulation are logical interfaces to the Fortigate, so we are not violating any split-horizon rules by sending the traffic back to the same physical port it was originally received on. This can be illustrated on the Network interfaces screen on the Fortigate GUI. 

The important thing to remember here is; traffic received on a geneve tunnel and sent out to the public internet will allow responses to be sent back. The GWLB is a stateful load balancer and will allow response traffic to be sent back to through the geneve tunnel to the original source. But traffic that is sourced from the geneve tunnel side and sent to the GWLB, will be dropped. The traffic must originate from the GWLBe side to get an entry in the state table.

![Network Interfaces](interfaces.png)

#### Enable Dedicated Management ENI

The FortiGate Autoscale solution provides the option to enable a dedicated management ENI. This option is configured in the template terraform.tfvars file by setting the following variable to true:

enable_dedicated_mgmt_eni = true

When this option is enabled, port2 is taken out of the data plane and cannot be used by the Fortigate for data plane traffic. This is done by setting the dedicated-to attribute on the interface definition and putting the interface in a separate vrf. Once this is done, the Fortigate cannot assign a firewall policy to the interface and the interface will have a separate routing table. 

{{% notice note %}}
Be aware that setting a dedicated management ENI on a 2-arm router and setting Egress Option to nat_gw will not allocate an EIP to the port2 interface. This is a valid configuration, but you cannot access the management interface from the public internet. You MUST access the firewall on the private interface IP address through an AWS Direct Connect. 
{{% /notice %}}

![Dedicated Management ENI](management-eni.png)

This can be verified in the Fortigate GUI by looking at the Network->Interface definition. 

![GUI Dedicated Management ENI](management-eni-gui.png)

#### Enable Dedicated Management VPC

The FortiGate Autoscale solution provides the option to enable a dedicated management VPC. This option is configured in the template terraform.tfvars file by setting the following variable to true:

enable_dedicated_mgmt_vpc = true

When this option is enabled and "enable_build_management_vpc" was set to true in the "existing_vpc_resources", the template will create a dedicated management eni (described above) in the management VPC created by the "existing_vpc_resources" template. If the "existing_vpc_resources" did not build a management VPC, the simplified template will create a new management vpc and build a dedicated_management_eni (described above) in the management VPC. 

#### License Directory

All BYOL licenses allocated to license BYOL instances in the autoscale group my be stored in the directory indicated by the asg_license_directory variable in the terraform.tfvars file. The directory must be in the same directory as the terraform.tfvars file. The licenses found here will be copied to an S3 bucket and allocated to byol instances as they are spawned. Additional instances will be spawned under the on_demand autoscale group, if necessary. 

![License Directory](license-directory.png)

#### Autoscale Group Capacity

The initial autoscale group capacity can be set by setting the following variables in the terraform.tfvars file:

![Autoscale Group Capacity](asg-group-capacity.png)
