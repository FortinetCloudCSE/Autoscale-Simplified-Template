# Changing the East/West Spoke CIDRs

How to move the East/West spoke VPCs off the default `192.168.0.0/24` /
`192.168.1.0/24` and onto a different address range, across both
`existing_vpc_resources/terraform.tfvars` and
`autoscale_template/terraform.tfvars`.

**TL;DR — the real risk was not the AWS/TGW routes.** Almost every TGW/route
table reference is already parameterized by Terraform variable or covers the
full RFC1918 space regardless of which spoke CIDR you pick. The one thing
that would have broken silently — a **hardcoded static route inside the
FortiGate's own boot-time config** (`*.cfg.tftpl`), which wasn't wired to any
Terraform variable — has since been fixed in code (see
[The FortiGate static route](#the-fortigate-static-route-now-fixed) below),
and the design was improved further: there is no longer a `vpc_cidr_spoke`
"supernet" variable at all — see
[Why vpc_cidr_spoke was removed](#why-vpc_cidr_spoke-was-removed). All you
need to do now is set `vpc_cidr_east`/`vpc_cidr_west` consistently in both
`terraform.tfvars` files (and optionally `spoke_cidrs` if your real spoke
list differs from just those two).

## What to change

### `existing_vpc_resources/terraform.tfvars`

```hcl
vpc_cidr_east = "192.168.0.0/24"   # -> your new east CIDR
vpc_cidr_west = "192.168.1.0/24"   # -> your new west CIDR
```

That's it for this file. Everything derived from `vpc_cidr_east`/`vpc_cidr_west`
here — the east/west VPC itself, the public/TGW subnet CIDRs
(`cidrsubnet(var.vpc_cidr_east, var.spoke_subnet_bits, N)` in `vpc_east.tf` /
`vpc_west.tf`), the Linux test-instance IPs (`cidrhost(...)` in `ec2.tf`), and
the management VPC's dedicated TGW route table entries pointing at east/west
(`vpc_management.tf` lines ~127-137) — all recompute automatically from the
variable. No other file in this template needs a manual edit.
(`vpc_cidr_spoke` used to live here too — it was removed, see below.)

### `autoscale_template/terraform.tfvars`

```hcl
vpc_cidr_east = "192.168.0.0/24"   # -> must match existing_vpc_resources exactly
vpc_cidr_west = "192.168.1.0/24"   # -> must match existing_vpc_resources exactly

# Optional — only set this if your real spoke list is bigger than/different
# from just east+west (e.g. production spokes beyond this lab template):
# spoke_cidrs = ["192.168.0.0/24", "192.168.1.0/24", "10.20.0.0/16"]
```

The TGW routes this template creates to/from the inspection VPC
(`vpc_inspection.tf` — `inspection-route-to-east-tgw` /
`inspection-route-to-west-tgw`, and the east/west TGW-route-table default
route replacements gated by `create_tgw_routes_for_existing`) all read
`var.vpc_cidr_east` / `var.vpc_cidr_west` directly, and the FortiGate config
template now reads `local.spoke_cidrs` (next section) — which itself defaults
to `[var.vpc_cidr_east, var.vpc_cidr_west]` if you don't set `spoke_cidrs`
explicitly. Nothing left to hand-edit for a CIDR move.

**`vpc_cidr_east`/`vpc_cidr_west` must match between both files.** They
describe the same two spoke VPCs from two different templates' point of view;
`existing_vpc_resources` builds them, `autoscale_template` routes to them.

## The FortiGate static route (now fixed)

All six FortiGate config templates —

```
terraform/autoscale_template/1-arm-fgt-conf.cfg.tftpl
terraform/autoscale_template/1-arm-wdm-fgt-conf.cfg.tftpl
terraform/autoscale_template/1-arm-wdm-eni-fgt-conf.cfg.tftpl
terraform/autoscale_template/2-arm-fgt-conf.cfg.tftpl
terraform/autoscale_template/2-arm-wdm-fgt-conf.cfg.tftpl
terraform/autoscale_template/2-arm-wdm-eni-fgt-conf.cfg.tftpl
```

— used to contain a **hardcoded** static route in the `config router static`
block:

```
config router static
%{ for az in az_list ~}
    edit 0
        set dst 192.168.0.0 255.255.0.0
        set distance 5
        set priority 100
        set device "geneve-${az}"
    next
%{ endfor ~}
end
```

This is the route that sends east↔west inspected traffic out the FortiGate's
`geneve-<az>` interface (the GWLB Geneve tunnel used for east-west
inspection). `192.168.0.0 255.255.0.0` is `192.168.0.0/16` written as a
FortiOS netmask. It used to be a **plain string literal in the template**,
not driven by any Terraform variable — the `templatefile()` calls rendering
these six files (`autoscale_group.tf` lines 283 and 342) only passed in
`az_list`. Changing the spoke CIDRs without also fixing this line would have
silently broken east-west inspected traffic: nothing in
`terraform plan`/`apply` would have warned you, since this isn't
Terraform-managed — it's a line inside a heredoc-style config payload the
FortiGate reads at boot.

**Current state**: the block now loops over every CIDR in a list, not one
supernet:

```
config router static
%{ for az in az_list ~}
%{ for cidr in spoke_cidrs ~}
    edit 0
        set dst ${split("/", cidr)[0]} ${cidrnetmask(cidr)}
        set distance 5
        set priority 100
        set device "geneve-${az}"
    next
%{ endfor ~}
%{ endfor ~}
end
```

i.e. one static route per `(AZ, spoke CIDR)` pair — az_list × spoke_cidrs.
Both `templatefile()` calls in `autoscale_group.tf` now pass
`spoke_cidrs = local.spoke_cidrs`. `terraform validate` passes.

## Why `vpc_cidr_spoke` was removed

The original fix (an earlier revision of this doc) parameterized the static
route using a single `vpc_cidr_spoke` "supernet" variable, on the assumption
that `vpc_cidr_east`/`vpc_cidr_west` are subsets of it. That assumption was
never enforced anywhere — no `validation`/`check` block confirmed east/west
actually fall inside the declared supernet, in either template. Get it wrong
(stale supernet after moving the real spokes, a typo, or CIDRs that just
don't nest) and the FortiGate's static route silently stops matching real
spoke traffic again — the exact same class of silent failure as the original
bug, just moved one layer up.

Rather than add supernet-containment validation math to work around that,
`vpc_cidr_spoke` was removed entirely and replaced with **`spoke_cidrs`**
(`autoscale_template/variables.tf`) — an explicit `list(string)` of every
spoke CIDR south of the TGW that needs a FortiGate east-west route, with no
supernet math involved:

```hcl
variable "spoke_cidrs" {
  description = "List of all spoke VPC CIDRs south of the TGW that need FortiGate east-west inspection routes. Leave empty to default to [vpc_cidr_east, vpc_cidr_west]; override with the real list of production spoke CIDRs if they differ from the demo east/west VPCs."
  type        = list(string)
  default     = []
}
```

```hcl
locals {
  spoke_cidrs = length(var.spoke_cidrs) > 0 ? var.spoke_cidrs : [var.vpc_cidr_east, var.vpc_cidr_west]
}
```

Consequences of this design:

- **No containment assumption to get wrong.** Each entry in `spoke_cidrs`
  becomes its own static route. There's no supernet to keep in sync with
  east/west — if you add a third production spoke VPC at some unrelated
  CIDR, you add it to the list and it gets its own route, full stop.
- **Zero-touch default.** If you never set `spoke_cidrs`, it defaults to
  `[var.vpc_cidr_east, var.vpc_cidr_west]` — the lab/demo case (this doc's
  main scenario) needs no new variable at all, just the existing
  `vpc_cidr_east`/`vpc_cidr_west`.
- **`vpc_cidr_spoke` is gone, not just unused.** It's been deleted from
  `variables.tf`, `terraform.tfvars`, and `terraform.tfvars.example` in
  **both** `autoscale_template` and `existing_vpc_resources` (it was already
  dead/unreferenced in `existing_vpc_resources` before any of this — see the
  old "things that don't need changes" list this doc used to have). If your
  own `terraform.tfvars` still has a `vpc_cidr_spoke = ...` line left over
  from before, Terraform will just print a harmless "value for undeclared
  variable" warning — safe to delete whenever, not urgent.
- **More routes than before, on purpose.** The route count is now
  `len(az_list) * len(spoke_cidrs)` instead of `len(az_list)` — e.g. 2 AZs ×
  2 spokes = 4 routes instead of 2. That's the correct tradeoff: more static
  routes, but each one is unambiguous and independently correct.

## Things you flagged that turn out not to need changes

You originally called out several variables while investigating — worth
explaining why they're *relevant context* but not something you need to
touch because of a CIDR change specifically:

- **`modify_existing_route_tables`** (`autoscale_template`) — gates whether
  the private-subnet default route gets replaced to point at the GWLB
  endpoints. It's a yes/no "should I touch routing at all" switch; it's
  orthogonal to what the CIDRs actually are. Leave it at whatever value your
  deployment mode already needs.
- **`create_tgw_routes_for_existing`** — this exact variable name is declared
  independently in *both* `existing_vpc_resources/variables.tf` and
  `autoscale_template/variables.tf`, which is why you saw two different
  comments for what looks like one setting:
  - In `existing_vpc_resources`, it gates the **bootstrap** default routes
    (spoke → management VPC/jump box, for cloud-init) in `tgw.tf`.
  - In `autoscale_template`, it gates the **replacement** routes (spoke →
    inspection VPC, for FortiGate inspection) in `vpc_inspection.tf`, which
    supersede the bootstrap ones once the FortiGate ASG is up.

  Same name, two files, two purposes, both already driven by
  `var.vpc_cidr_east`/`var.vpc_cidr_west` wherever they reference a spoke
  CIDR. Not something to change for a CIDR move — just don't confuse the two
  when reading tfvars.
- **The RFC1918 blanket TGW routes** (`local.rfc1918_192` / `rfc1918_10` /
  `rfc1918_172` in `vpc_inspection.tf` and `vpc_management.tf` in
  `existing_vpc_resources`) — these create **three static routes covering
  all of `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`** to the TGW,
  unconditionally, together, regardless of your actual spoke CIDR. As long as
  your new spoke CIDR still falls inside one of those three RFC1918 ranges
  (which covers essentially every private CIDR you'd realistically pick),
  these routes already have you covered with zero changes. The equivalent
  `rfc1918_192`/`rfc1918_10`/`rfc1918_172` locals defined in
  `autoscale_template/vpc_inspection.tf` (lines 29-36) are unused dead code —
  harmless, nothing to fix, just don't go looking for where they're consumed.

## Other things worth checking when you change the CIDRs

- **Sizing, not just address.** If you also shrink the CIDR block (not just
  relocate it), remember `vpc_east.tf`/`vpc_west.tf` carve 6 subnets via
  `cidrsubnet(var.vpc_cidr_east, var.spoke_subnet_bits, 0..5)`
  (`spoke_subnet_bits` defaults to `4`, so a `/24` supernet yields `/28`
  subnets — 16 addresses, with AWS reserving the first 4 and the last,
  leaving host numbers ~4-14 usable per the `windows_host_ip` variable
  description in `existing_vpc_resources/variables.tf`). Going smaller than
  `/24` for `vpc_cidr_east`/`vpc_cidr_west` without also reducing
  `spoke_subnet_bits` risks subnets too small to be valid (AWS's minimum
  subnet size is `/28`).
- **No overlap validation exists.** Neither template has a Terraform
  `validation`/`check` block guarding against your new spoke CIDRs
  overlapping `vpc_cidr_management`, `vpc_cidr_inspection`, or (if you're
  using the dual-egress feature) any `distributed_egress_vpc_*_cidr`. That's
  on you to verify by inspection — nothing will fail fast in `plan` if they
  collide, you'll just get broken routing or a VPC peering/attachment error
  later. (This is exactly the class of problem `spoke_cidrs` was designed to
  avoid for the FortiGate's own route table — it just doesn't extend to
  cross-CIDR overlap checks in general.)
- **Stale doc comments, not functional issues.** A few comments reference
  the literal `192.168.0.11`/`192.168.1.11` example addresses (e.g.
  `linux_host_ip`'s comment in `terraform.tfvars.example`) and the published
  docs under `content/5_Templates/` show the same default CIDRs (and the old
  `vpc_cidr_spoke` variable) in their example snippets. These are just
  illustrative text — the actual IPs are computed dynamically via
  `cidrhost()`/`cidrsubnet()` from whatever CIDR you set, so nothing breaks —
  but if you want the example files/docs to stay accurate for the next
  person, they'd need a matching text update. Out of scope for this writeup
  unless you want it done.

## Suggested order of operations

1. Pick your new `vpc_cidr_east` / `vpc_cidr_west` values (same pair in both
   `terraform.tfvars` files). Set `spoke_cidrs` in `autoscale_template` only
   if your real spoke list differs from just those two.
2. `terraform apply` in `existing_vpc_resources` first (rebuilds/moves the
   east/west VPCs and their subnets).
3. `terraform apply` in `autoscale_template` second (re-establishes the TGW
   routes to the new spoke CIDRs and renders the FortiGate config — now one
   static route per `(AZ, spoke CIDR)` pair — on next boot/config-sync).
4. Re-run `verify_east_vpc.sh` / `verify_west_vpc.sh` /
   `verify_connectivity.sh` to confirm east-west inspected traffic still
   flows.
