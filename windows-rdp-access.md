# Accessing the Windows Spoke Instances via RDP

The optional Windows spoke instances (`enable_windows_spoke_instances`, one in the East VPC and one in the West VPC) are always private — no public IP. They're reachable only through the jump box or a FortiGate VIP.

This document covers the jump-box path: an SSH local port-forward tunnel from your Mac, through the jump box, to the Windows instance's RDP port.

## Why this works with no extra configuration

- The jump box's security group allows all outbound traffic (`vpc_management.tf`), and its userdata script never touches `/etc/ssh/sshd_config` or enables `ufw` — so OpenSSH's default `AllowTcpForwarding yes` applies, and nothing blocks the tunnel locally.
- Routing between the Management VPC (jump box) and the East/West spoke VPCs already exists via the Transit Gateway, as long as `enable_management_tgw_attachment = true` and `create_tgw_routes_for_existing = true` (both required for this to work, and both `true` in a typical demo/lab deployment).
- The Windows instances share the same "allow all" security group as the Linux spoke instances, so inbound RDP (3389) from the jump box is already permitted.

## 1. Find the Windows instances' private IPs

These are deterministic — computed from `windows_host_ip` and each spoke VPC's CIDR, not something you need to look up in AWS:

```
East instance:  <vpc_cidr_east base>.<windows_host_ip>
West instance:  <vpc_cidr_west base>.<windows_host_ip>
```

With the defaults in this repo (`vpc_cidr_east = 192.168.0.0/24`, `vpc_cidr_west = 192.168.1.0/24`, `windows_host_ip = 13`):

```
East instance:  192.168.0.13
West instance:  192.168.1.13
```

If you've changed `windows_host_ip` or the spoke CIDRs in your `terraform.tfvars`, recompute accordingly.

## 2. Get the jump box's public IP

```bash
cd terraform/existing_vpc_resources
terraform output jump_box_public_ip
```

## 3. Open the SSH tunnel

Leave this running in its own terminal window — it's what carries the RDP traffic:

```bash
ssh -i ~/.ssh/<your-keypair>.pem -L 3389:192.168.0.13:3389 ubuntu@<jump-box-public-ip>
```

Swap `192.168.0.13` for `192.168.1.13` to reach the West instance instead. Adjust the path to your `.pem` file to match wherever you actually store it.

## 4. Connect with RDP

Open **Windows App** (Mac App Store — Microsoft's RDP client, renamed from "Microsoft Remote Desktop" in May 2025) and connect to:

```
localhost:3389
```

The connection routes through the SSH tunnel from step 3 to the Windows instance's actual RDP port. Close the SSH terminal to end the tunnel.

## Retrieving the Windows admin password

AWS encrypts the initial Windows admin password using the keypair you launched the instance with. Retrieve and decrypt it with:

```bash
aws ec2 get-password-data --instance-id <windows-instance-id> \
  --priv-launch-key ~/.ssh/<your-keypair>.pem \
  --region <your-region>
```
