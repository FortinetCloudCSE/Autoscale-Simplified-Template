---
title: "FortiFlex Setup"
chapter: false
menuTitle: "FortiFlex Setup"
weight: 441
---

## Overview

Before the autoscale template can activate FortiFlex licenses, several steps must be completed in the Fortinet support and FortiFlex portals. This page walks through creating an IAM user, configuring the required permission profile, and locating the credentials and identifiers needed in `terraform.tfvars`.

All portal work is done at **[support.fortinet.com](https://support.fortinet.com)**.

---

## Prerequisites

- Active Fortinet support account with account owner or IAM administrator rights
- FortiFlex program already registered and point packs purchased
- At least one FortiFlex Configuration created in the FortiFlex portal (see [Configuration IDs](#step-4-locate-your-configuration-id) below)

---

## Step 1: Create a Permission Profile

A permission profile defines what API operations an IAM user is allowed to perform. The autoscale Lambda requires read and write access to FortiFlex entitlements in order to activate, reactivate, and stop licenses as FortiGate instances scale in and out.

1. Log into **support.fortinet.com**
2. Navigate to **IAM → Permission Profiles**
3. Click **New Profile**
4. Enter a descriptive name such as `fortiflex-autoscale`
5. Under **FortiFlex**, enable the following permissions:

   - **Entitlements: Read** — allows Lambda to list available entitlements
   - **Entitlements: Write** — allows Lambda to activate, reactivate, and stop entitlements

   No other permissions are required. Do not grant billing, program management, or account administration access.

6. Click **Save**

{{% notice info %}}
**Minimum Permission Scope**

The Lambda makes exactly five FortiFlex API calls: `oauth/token` (authenticate), `entitlements/list`, `entitlements/vm/token` (activate), `entitlements/reactivate`, and `entitlements/stop`. Read + Write on Entitlements covers all five.
{{% /notice %}}

![Screenshot: IAM Permission Profile — FortiFlex Read/Write permissions enabled](screenshot-iam-permission-profile.png)
*Screenshot placeholder: Permission profile with FortiFlex Entitlements Read and Write checked*

---

## Step 2: Create an IAM User

IAM users are sub-accounts under your main FortiCare account. The username and password generated here become `fortiflex_username` and `fortiflex_password` in `terraform.tfvars`.

1. Navigate to **IAM → User Management**
2. Click **New User**
3. Fill in the required fields:
   - **First Name / Last Name**: descriptive label (e.g., `Autoscale Lambda`)
   - **Email**: a valid email address (used for credential delivery)
   - **Permission Profile**: select the profile created in Step 1 (`fortiflex-autoscale`)
4. Click **Save**

![Screenshot: IAM New User form with fields filled in and permission profile selected](screenshot-iam-new-user-form.png)
*Screenshot placeholder: New User form showing name, email, and permission profile assignment*

---

## Step 3: Download Credentials

After saving the new user, FortiCare generates credentials and packages them in a password-protected zip file.

1. On the user confirmation screen, note the **zip file password** displayed on screen — this password is shown **once only** and cannot be retrieved afterward
2. Click **Download Credentials**
3. Open the zip file using the password from step 1
4. The zip contains a CSV file with two values:

   | CSV Field | terraform.tfvars Variable |
   |-----------|--------------------------|
   | Username (UUID format) | `fortiflex_username` |
   | Password | `fortiflex_password` |

![Screenshot: Credential download confirmation screen showing zip password](screenshot-iam-credential-download.png)
*Screenshot placeholder: Download confirmation screen with zip password visible and Download button*

{{% notice warning %}}
**Zip Password Is Shown Once**

The password to open the credential zip file is displayed only at the moment of download. If you lose it, the IAM user must be deleted and recreated — there is no recovery mechanism.
{{% /notice %}}

{{% notice warning %}}
**Protect These Credentials**

Never commit `fortiflex_username` or `fortiflex_password` to version control. Use environment variables, AWS Secrets Manager, or Terraform Cloud sensitive variables to inject them at apply time.
{{% /notice %}}

---

## Step 4: Locate Your Configuration ID

FortiFlex Configurations define the FortiGate model, CPU count, and feature bundle. The Lambda uses the Configuration ID to create entitlements that match your EC2 instance type.

1. Navigate to **Services → FortiFlex** (or open the FortiFlex portal directly)
2. Click **Configurations**
3. Locate the configuration that matches your intended EC2 instance type
4. The **Name** column value is your Configuration ID — this is what goes into `fortiflex_configid_list`

![Screenshot: FortiFlex Configurations list showing Name column](screenshot-fortiflex-configurations.png)
*Screenshot placeholder: FortiFlex Configurations table with Name, CPU count, and bundle columns visible*

{{% notice info %}}
**CPU Count Must Match EC2 Instance**

The Configuration's vCPU count must match the vCPU count of `fgt_instance_type`. For example, a `c6i.xlarge` has 4 vCPUs — use a Configuration set to 4 vCPUs.

```hcl
fgt_instance_type       = "c6i.xlarge"   # 4 vCPUs
fortiflex_configid_list = ["My_4CPU_Config"]
```
{{% /notice %}}

---

## Step 5: Locate Your Serial Number List (Optional)

`fortiflex_sn_list` scopes license activation to entitlements from a specific FortiFlex program. If omitted, the Lambda will use any available entitlement matching the Configuration ID.

1. In the FortiFlex portal, navigate to **Programs**
2. Click into your program
3. Note the serial numbers listed under **Entitlements**
4. Add them to `fortiflex_sn_list` if you want to restrict which entitlements the Lambda uses

![Screenshot: FortiFlex Program detail showing entitlement serial numbers](screenshot-fortiflex-program-serials.png)
*Screenshot placeholder: Program detail view with entitlement serial numbers listed*

---

## Step 6: Verify Credentials Before Deploying

Test the credentials with a direct API call before running `terraform apply` to avoid troubleshooting inside a failed deployment.

```bash
# Step 1: Get an OAuth token
curl -s -X POST "https://customerapiauth.fortinet.com/api/v1/oauth/token/" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "YOUR_FORTIFLEX_USERNAME",
    "password": "YOUR_FORTIFLEX_PASSWORD",
    "client_id": "flexvm",
    "grant_type": "password"
  }' | jq .
```

A successful response contains `access_token`. Use it to verify entitlement access:

```bash
# Step 2: List entitlements
curl -s -X POST "https://support.fortinet.com/ES/api/fortiflex/v2/entitlements/list" \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .
```

If both calls return data without errors, the credentials and permissions are correct.

---

## terraform.tfvars Reference

```hcl
# FortiFlex credentials — from downloaded CSV inside credential zip
fortiflex_username      = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
fortiflex_password      = "xxxxxxxxxxxxxxxxxxxxx"

# Configuration ID — the Name field from FortiFlex Configurations
fortiflex_configid_list = ["My_4CPU_Config"]

# Serial number list — optional, scopes to specific program entitlements
# fortiflex_sn_list = ["FGVMELTMxxxxxxxx"]
```

---

## Updating Credentials Without Redeploying

If FortiFlex credentials need to be rotated after deployment, the Lambda environment variable can be updated directly without a `terraform apply`:

```bash
# Find the Lambda function name
aws lambda list-functions \
  --region <your-region> \
  --query "Functions[?contains(FunctionName, 'byol')].FunctionName"

# Update the password environment variable
aws lambda update-function-configuration \
  --function-name <lambda-function-name> \
  --region <your-region> \
  --environment 'Variables={
    "fortiflex_username": "existing-username",
    "fortiflex_password": "new-password",
    ... all other existing env vars preserved ...
  }'
```

{{% notice warning %}}
**Sync terraform.tfvars After Rotation**

A subsequent `terraform apply` will overwrite the Lambda environment variable back to whatever is in `terraform.tfvars`. Update `fortiflex_password` in `terraform.tfvars` after confirming the new credentials work.
{{% /notice %}}

---

## Next Steps

Return to [Licensing Options](../) to complete FortiFlex configuration in `terraform.tfvars` and proceed with deployment.
