---
title: "Is Autoscale Right for You?"
menuTitle: "Autoscale Considerations"
weight: 15
chapter: true
---

Before investing time in this deployment, it is worth asking whether autoscale
is the right architecture for your use case. Our general recommendation is to
consider **intentional scaling** — using Terraform to preemptively manage
instance count — before committing to an autoscale deployment.

Most customers, once they understand the trade-offs, choose intentional scaling
over autoscale. If you can make that case to your customer, you should.

---

## Reasons to Reconsider Autoscale

### Scale-Out Latency
A new FortiGate instance takes approximately 4-5 minutes to deploy, license,
and become traffic-ready. If the burst event that triggered the scale-out lasts
less than 4-5 minutes, the new instance will be ready after the event has
already passed. In many cases, autoscale provides no benefit for short-duration
bursts.

### Scale-In Delay
Once an instance is deployed, the scale-in backoff period is intentionally
conservative to avoid prematurely removing capacity. This means you may be
paying for instances well after they are needed.

### FortiGates Rarely Scale Out in Practice
In practice, FortiGate instances are often faster than the infrastructure they
are protecting. The CPU thresholds that trigger scale-out are rarely reached,
making the autoscale group effectively a fixed-size deployment with additional
complexity. Vertical scaling — choosing a larger instance type — is often a
simpler and more effective solution.

### Non-Deterministic Traffic Flows
GWLB uses 5-tuple hashing to pin a flow to a specific FortiGate instance, but
you have no visibility into which instance is handling a given flow without
digging through GWLB flow logs and individual FortiGate session tables. Because
instances are ephemeral, the instance that handled a flow may be terminated
before you can investigate it. This makes troubleshooting traffic and security
events significantly more difficult than in a static deployment.

### License Management Complexity
Licenses are assigned dynamically by a Lambda function backed by a DynamoDB
table. If Lambda fails or the table falls out of sync, instances can come up
unlicensed. Troubleshooting requires inspecting Lambda execution logs, DynamoDB
state, and FortiGate registration status simultaneously — none of which are
familiar tools for most FortiGate administrators.

### Lambda and CloudWatch Observability
Lambda functions orchestrate the entire autoscale lifecycle: instance launch,
license assignment, primary instance election, and scale-in cleanup. When
something goes wrong, diagnosis requires navigating CloudWatch log groups,
correlating Lambda execution events to specific FortiGate instance activity,
and understanding the autoscale state machine. This requires a combined skill
set of FortiGate administration, AWS networking, and AWS serverless operations.

### Upgrade Complexity
Upgrading FortiOS on a running autoscale group is a manual, multi-step process
involving AWS Console operations, new launch template versions, and per-instance
firmware upgrades through the FortiGate GUI. There is no automated upgrade path.

### VPN Limitations
VPN tunnels cannot be terminated on autoscale instances. IPSec requires a
stable, known IP address or FQDN for the remote peer to establish a tunnel
against. Autoscale instances are ephemeral — their IPs come and go as the group
scales. Even if an EIP is attached, IKE/IPSec session state lives on a specific
instance. If that instance is terminated, the tunnel drops and must be fully
re-negotiated with a replacement instance. If your design requires site-to-site
or client VPN termination on the FortiGate, a static deployment or HA pair is
the appropriate solution.

### Egress IP Non-Determinism
If you use per-instance Elastic IPs for egress rather than a NAT Gateway, the
source IP of outbound traffic is non-deterministic. EIPs are associated with
ephemeral instances and change as the group scales. If your downstream systems,
partners, or compliance requirements depend on a stable egress IP, you must use
a NAT Gateway — which adds cost and a fixed point of failure.

---

## When Autoscale Does Make Sense

If your workload has genuine, sustained traffic bursts that exceed what a
single instance can handle, and you cannot predict when those bursts will occur,
autoscale can be a good fit. The following guidance applies if you proceed:

- **Maintain at least one instance per Availability Zone.** This avoids
  cross-AZ traffic inspection costs and ensures local capacity is always
  available without a cold-start delay.

- **Tune the CloudWatch alarms.** The default scale-out threshold is CPU > 80%
  for two consecutive 120-second periods. If your bursts are shorter than the
  scale-out latency, adjust the thresholds or disable scale-out entirely and
  treat the group as a fixed-size deployment.

- **Enable `primary_scalein_protection`.** This prevents the primary FortiGate
  instance — which holds the authoritative configuration — from being selected
  as a scale-in candidate. Without this, configuration can be lost if the
  primary is terminated and a new primary election is required.

- **Use a NAT Gateway for egress.** Per-instance EIPs result in non-deterministic
  source IPs as instances come and go. A NAT Gateway provides a stable,
  predictable egress IP.

- **Plan licensing carefully.** A common pattern is BYOL or FortiFlex for
  baseline instances (those that never scale in) and PAYG for burst instances.
  Alternatively, size FortiFlex entitlements to cover the maximum desired
  capacity. Either way, license capacity must be planned ahead — running out
  of licenses during a scale-out event leaves new instances unlicensed.

- **Consider FortiAnalyzer.** Given the non-deterministic traffic flow and
  ephemeral instance nature of autoscale, a central logging and analytics
  platform is more valuable here than in a static deployment. Without it,
  correlating security events across instances is very difficult.

---

## The Alternative: Intentional Scaling

If your load patterns are predictable — scheduled batch jobs, business-hours
traffic, known maintenance windows — Terraform can manage instance count
intentionally and preemptively. You define the capacity you need, when you need
it, and Terraform applies it. This approach is simpler to operate, easier to
troubleshoot, and avoids the Lambda/DynamoDB/CloudWatch machinery entirely.

This workshop focuses on autoscale deployments. If intentional scaling is a
better fit, the [FortiGate AWS Autoscale TEC Workshop](https://fortinetcloudcse.github.io/FortiGate-AWS-Autoscale-TEC-Workshop/) covers the lower-level
components and gives you more direct control over the deployment.
