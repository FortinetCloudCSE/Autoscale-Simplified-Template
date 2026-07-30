---
title: "Prerequisites: AWS IAM Permissions"
chapter: false
menuTitle: "Prerequisites"
weight: 50
---

## Overview

Before deploying either template, the AWS identity you deploy with (IAM user, role, or SSO permission set) needs permissions across several AWS services. This page lists exactly which services are touched, based on scanning every resource type actually referenced across both templates and their downloaded external modules (`git::https://github.com/40netse/terraform-modules.git`) — not a generic guess.

{{% notice info %}}
**`existing_vpc_resources` and `autoscale_template` need different permission scopes.** If you're only running `existing_vpc_resources` (for example, to tag an existing production VPC manually and skip `autoscale_template`), you don't need the Lambda/DynamoDB/S3/EventBridge/CloudWatch permissions listed below — those are only exercised by `autoscale_template`.
{{% /notice %}}

---

## Services required

### Needed by both templates

| Service | What it's used for |
|---|---|
| **EC2** | VPCs, subnets, route tables, Internet Gateway, NAT Gateway, Elastic IPs, security groups, network interfaces, instances, AMI lookups, Transit Gateway (and attachments/routes/route tables), VPC Endpoints, resource tagging |
| **Elastic Load Balancing (ELBv2)** | The Gateway Load Balancer itself — `aws_lb`, target groups, listeners all use the ELBv2 API namespace, not a separate "GWLB" service |
| **IAM** | Instance profiles and roles for the FortiManager/FortiAnalyzer/jump box/Linux/Windows spoke instances, plus `iam:PassRole` |
| **STS** | `sts:GetCallerIdentity` (read-only) |

### Needed only by `autoscale_template`

| Service | What it's used for |
|---|---|
| **Auto Scaling** | The FortiGate ASG(s), scaling policies, launch templates |
| **Lambda** | The autoscale lifecycle function (launch/terminate handling) and its Lambda layer |
| **DynamoDB** | BYOL license/state tracking table |
| **S3** | Bucket and objects for license files and the Lambda deployment package |
| **EventBridge** (CloudWatch Events) | Rules/targets that trigger the Lambda on ASG launch/terminate |
| **CloudWatch** | Scaling metric alarms, Lambda log group |

---

## Recommended approach

There are two reasonable paths depending on what you're deploying into:

**Lab / POC / demo account** (what this template is built for): use broad AWS-managed policies per service — `AmazonEC2FullAccess`, `ElasticLoadBalancingFullAccess`, `IAMFullAccess`, `AWSLambda_FullAccess`, `AmazonDynamoDBFullAccess`, `AmazonS3FullAccess`, `CloudWatchEventsFullAccess`, `CloudWatchFullAccess` — or simply `AdministratorAccess` if the account is dedicated/sandboxed.

**Production account**: don't hand-author a least-privilege policy from a resource list alone — with dozens of resource types across 8 services, it's easy to miss a `Describe*` call Terraform issues during refresh. Instead, deploy once with `AdministratorAccess` in a scratch account, then generate a policy from real activity using **IAM Access Analyzer's policy generation** feature (built from CloudTrail events during that deployment). That guarantees nothing gets missed.

A systematic starting-point draft — built the same way (every resource type mapped to its standard IAM actions), but **not independently verified against a real deployment** — is available in the repo root as [`iam-least-privilege-policy.json`](https://github.com/FortinetCloudCSE/Autoscale-Simplified-Template/blob/main/iam-least-privilege-policy.json). Treat it as a draft to validate via Access Analyzer, not a final answer.

{{% notice warning %}}
**The most commonly-missed permission**: `iam:PassRole`. This is required separately from role-creation permissions any time an EC2 instance profile or Lambda execution role gets attached to a resource — it's the single most common gap people hit deploying Terraform templates like this one. In the draft policy, it's scoped with an `iam:PassedToService` condition (`ec2.amazonaws.com`, `lambda.amazonaws.com`) rather than left fully open.
{{% /notice %}}

---

## Next steps

- [Templates Overview](../5_1_overview/)
- [existing_vpc_resources Template](../5_2_existing_vpc_resources/)
- [autoscale_template](../5_3_autoscale_template/)
