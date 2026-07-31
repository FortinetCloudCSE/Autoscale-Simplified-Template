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

A systematic starting-point draft — built the same way (every resource type mapped to its standard IAM actions), but **not independently verified against a real deployment** — is available below and in the repo root as [`iam-least-privilege-policy.json`](https://github.com/FortinetCloudCSE/Autoscale-Simplified-Template/blob/main/iam-least-privilege-policy.json). Treat it as a draft to validate via Access Analyzer, not a final answer.

{{% notice warning %}}
**The most commonly-missed permission**: `iam:PassRole`. This is required separately from role-creation permissions any time an EC2 instance profile or Lambda execution role gets attached to a resource — it's the single most common gap people hit deploying Terraform templates like this one. In the draft policy, it's scoped with an `iam:PassedToService` condition (`ec2.amazonaws.com`, `lambda.amazonaws.com`) rather than left fully open.
{{% /notice %}}

---

## Least-privilege policy (draft)

If you're deploying into a production or compliance-governed account and can't use `AdministratorAccess` even temporarily, attach this policy instead of the broad managed policies above. The `AutoscaleTemplateOnly_*` statements can be dropped entirely if you're only running `existing_vpc_resources`.

```json
{
  "Comment": "Least-privilege draft for deploying both existing_vpc_resources and autoscale_template. Built by enumerating every AWS resource/data type actually referenced across both templates and their downloaded external modules (git::https://github.com/40netse/terraform-modules.git), then mapping each to its standard Create/Describe/Modify/Delete/Tag IAM actions. NOT independently tested against a real deployment -- validate with IAM Access Analyzer's policy generation (built from real CloudTrail activity during a full apply+destroy cycle) before treating this as final for production use. Remove the Statement Sids for resources you know you'll never enable (e.g., drop EC2VpcEndpointService if you never build the inspection VPC's GWLB endpoint service) to tighten further.",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Core",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:DescribeVpcs",
        "ec2:ModifyVpcAttribute",
        "ec2:DescribeVpcAttribute",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSubnets",
        "ec2:ModifySubnetAttribute",
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:ReplaceRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:ReplaceRouteTableAssociation",
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:DescribeInternetGateways",
        "ec2:CreateNatGateway",
        "ec2:DeleteNatGateway",
        "ec2:DescribeNatGateways",
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress",
        "ec2:DescribeAddresses",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeNetworkInterfaceAttribute",
        "ec2:AttachNetworkInterface",
        "ec2:DetachNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:StopInstances",
        "ec2:StartInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceAttribute",
        "ec2:ModifyInstanceAttribute",
        "ec2:GetPasswordData",
        "ec2:DescribeImages",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeKeyPairs",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:ImportKeyPair",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeTags",
        "ec2:CreateLaunchTemplate",
        "ec2:DeleteLaunchTemplate",
        "ec2:CreateLaunchTemplateVersion",
        "ec2:ModifyLaunchTemplate",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeLaunchTemplateVersions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2TransitGateway",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTransitGateway",
        "ec2:DeleteTransitGateway",
        "ec2:DescribeTransitGateways",
        "ec2:ModifyTransitGateway",
        "ec2:CreateTransitGatewayVpcAttachment",
        "ec2:DeleteTransitGatewayVpcAttachment",
        "ec2:ModifyTransitGatewayVpcAttachment",
        "ec2:DescribeTransitGatewayVpcAttachments",
        "ec2:DescribeTransitGatewayAttachments",
        "ec2:AcceptTransitGatewayVpcAttachment",
        "ec2:CreateTransitGatewayRoute",
        "ec2:DeleteTransitGatewayRoute",
        "ec2:ReplaceTransitGatewayRoute",
        "ec2:SearchTransitGatewayRoutes",
        "ec2:CreateTransitGatewayRouteTable",
        "ec2:DeleteTransitGatewayRouteTable",
        "ec2:DescribeTransitGatewayRouteTables",
        "ec2:AssociateTransitGatewayRouteTable",
        "ec2:DisassociateTransitGatewayRouteTable",
        "ec2:GetTransitGatewayRouteTableAssociations",
        "ec2:EnableTransitGatewayRouteTablePropagation",
        "ec2:DisableTransitGatewayRouteTablePropagation",
        "ec2:GetTransitGatewayRouteTablePropagations"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2VpcEndpoints",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpcEndpoint",
        "ec2:DeleteVpcEndpoints",
        "ec2:ModifyVpcEndpoint",
        "ec2:DescribeVpcEndpoints",
        "ec2:CreateVpcEndpointServiceConfiguration",
        "ec2:DeleteVpcEndpointServiceConfigurations",
        "ec2:ModifyVpcEndpointServiceConfiguration",
        "ec2:DescribeVpcEndpointServiceConfigurations",
        "ec2:ModifyVpcEndpointServicePermissions",
        "ec2:DescribeVpcEndpointServicePermissions",
        "ec2:AcceptVpcEndpointConnections",
        "ec2:DescribeVpcEndpointConnections",
        "ec2:DescribeVpcEndpointServices"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ElasticLoadBalancingGWLB",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:DescribeTargetGroupAttributes",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:RemoveTags",
        "elasticloadbalancing:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMForInstanceAndLambdaRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:ListInstanceProfilesForRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMPassRoleScoped",
      "Comment": "PassRole is deliberately separate and should be scoped to this account's path/prefix in production rather than left as Resource *.",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": [
            "ec2.amazonaws.com",
            "lambda.amazonaws.com"
          ]
        }
      }
    },
    {
      "Sid": "STSReadOnly",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "AutoscaleTemplateOnly_AutoScaling",
      "Comment": "Only needed for autoscale_template (the FortiGate ASG).",
      "Effect": "Allow",
      "Action": [
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:DeleteAutoScalingGroup",
        "autoscaling:UpdateAutoScalingGroup",
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:PutScalingPolicy",
        "autoscaling:DeletePolicy",
        "autoscaling:DescribePolicies",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:CreateOrUpdateTags",
        "autoscaling:DeleteTags",
        "autoscaling:DescribeTags",
        "autoscaling:SetInstanceProtection"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoscaleTemplateOnly_Lambda",
      "Comment": "Only needed for autoscale_template (ASG launch/terminate lifecycle function).",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:DeleteFunction",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:PublishLayerVersion",
        "lambda:DeleteLayerVersion",
        "lambda:GetLayerVersion",
        "lambda:ListVersionsByFunction",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:GetPolicy",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:ListTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoscaleTemplateOnly_DynamoDB",
      "Comment": "Only needed for autoscale_template (BYOL license/state tracking table).",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DeleteTable",
        "dynamodb:DescribeTable",
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:DeleteItem",
        "dynamodb:UpdateItem",
        "dynamodb:TagResource",
        "dynamodb:UntagResource",
        "dynamodb:ListTagsOfResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoscaleTemplateOnly_S3",
      "Comment": "Only needed for autoscale_template (license file + Lambda deployment package bucket). Scope Resource to a specific bucket ARN/prefix in production.",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:PutBucketTagging",
        "s3:GetBucketTagging",
        "s3:PutEncryptionConfiguration",
        "s3:GetEncryptionConfiguration",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketPolicy",
        "s3:GetBucketAcl"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoscaleTemplateOnly_EventBridge",
      "Comment": "Only needed for autoscale_template (rules that trigger the Lambda on ASG launch/terminate).",
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:DeleteRule",
        "events:DescribeRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "events:ListTargetsByRule",
        "events:TagResource",
        "events:UntagResource",
        "events:ListTagsForResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoscaleTemplateOnly_CloudWatch",
      "Comment": "Only needed for autoscale_template (scaling metric alarms + Lambda log group).",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:DeleteAlarms",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:TagResource",
        "cloudwatch:UntagResource",
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy",
        "logs:TagResource",
        "logs:TagLogGroup",
        "logs:ListTagsForResource",
        "logs:ListTagsLogGroup"
      ],
      "Resource": "*"
    }
  ]
}
```

---

## Next steps

- [Templates Overview](../5_1_overview/)
- [existing_vpc_resources Template](../5_2_existing_vpc_resources/)
- [autoscale_template](../5_3_autoscale_template/)
