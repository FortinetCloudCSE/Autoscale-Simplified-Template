# Mode B: Overlapping-CIDR Distributed Egress via GENEVE Endpoint-ID

> **Status: NOT MERGED. Do not merge this branch until a non-STS FortiOS
> build ships `endpoint-id` support.** This depends on a special/test
> FortiOS build (`build_tag_7121`, contact Aaron Jones, Fortinet Cloud PM)
> that is not generally available. See [Status](#status) below.

## Overview

Fortinet's STS/test FortiOS build `build_tag_7121`
(`FGVMA6-7.6.7-FW-build3704-260817`) exposes a new `endpoint-id` field on
`config system geneve`, letting a GENEVE tunnel be keyed to a specific AWS
GWLB Endpoint (`vpce-id`) instead of only `remote-ip`. This removes the
[Mode A](content/5_Templates/5_6_Distributed_Egress/_index.md) requirement
that distributed VPCs must not share overlapping CIDRs — classification
happens by tunnel identity instead of by address, so two distributed VPCs
can use the identical CIDR and still be told apart.

Traffic-verified end to end: two distributed VPCs on an identical CIDR
(`10.100.0.0/24`), plus the pre-existing centralized path, with real SSH
sessions, ICMP/TCP east-west traffic, and internet egress — not just clean
`show`/config application.

## Requirements

- STS FortiOS build with `endpoint-id` support on `config system geneve`
  (`build_tag_7121` or later).
- `enable_distributed_egress` already enabled (Mode B reuses Mode A's
  distributed VPC discovery and GWLB Endpoint attachment).

## Configuration Rules

- Every GENEVE tunnel — existing centralized (`geneve-az1`/`geneve-az2`)
  and new distributed (`d1-geneve-*`/`d2-geneve-*`) alike — requires
  `set type ppp`.
- Centralized router-policy entries (`geneve-az1`/`geneve-az2`): one
  `dst`-matched rule per AZ, matching the centralized spoke CIDRs. Never
  combine `src` and `dst` in the same entry, and never use a
  `src`-matched-only entry — either form incorrectly hairpins a spoke's
  legitimate internet-bound traffic back through `geneve` instead of
  letting it egress normally via `port2`.
- Distributed devices (`d1`/`d2`, both AZs): a single
  `input-device`→`output-device` router-policy entry each — no `dst`/`src`
  matching needed. Only the generic worse-priority `0.0.0.0/0` default
  static route (the same pattern centralized already uses) — no
  CIDR-specific static route needed.
- Zones: one per distributed VPC (`d1-zone`, `d2-zone`), added alongside
  the existing centralized `private-zone` — never merge them into one
  shared zone. This gives structural isolation: no firewall policy exists
  permitting `d1`↔`d2` traffic, or `d1`/`d2`→internet traffic, at all.

**Why the distributed devices don't need CIDR-specific routing:** GWLB is
a bump-in-the-wire, not a router. Once the FortiGate hands a packet back
to GWLB, AWS's own routing (e.g. this project's Inspection VPC `gwlbe`
subnet route table, which sends RFC1918 destinations to the TGW and
everything else to the IGW) does the real forwarding, regardless of which
specific device FortiOS used. The generic default route is enough to
satisfy FortiOS's own reverse-path-check bookkeeping — it doesn't need to
correctly steer final delivery, AWS's routing underneath already does
that. This doesn't extend to `endpoint-id` itself, though — that's a
different mechanism (which *originating VPC's* endpoint gets return
traffic when multiple VPCs share a CIDR), and does matter.

## Complete Validated CLI (flat approach)

```
# ============================================================
# 1. GENEVE tunnels — 6 total, all require "set type ppp"
# ============================================================
config system geneve
    edit "geneve-az1"
        set interface "port1"
        set type ppp
        set endpoint-id "vpce-090adb5f3b8028e00"
        set remote-ip 10.0.2.204
    next
    edit "geneve-az2"
        set interface "port1"
        set type ppp
        set endpoint-id "vpce-05c0a74867679f753"
        set remote-ip 10.0.7.81
    next
    edit "d1-geneve-az1"
        set interface "port1"
        set type ppp
        set endpoint-id "vpce-0492247e859f691c6"
        set remote-ip 10.0.2.204
    next
    edit "d1-geneve-az2"
        set interface "port1"
        set type ppp
        set endpoint-id "vpce-0b47abf854aa5fe45"
        set remote-ip 10.0.7.81
    next
    edit "d2-geneve-az1"
        set interface "port1"
        set type ppp
        set endpoint-id "vpce-09f0f5471fab6133c"
        set remote-ip 10.0.2.204
    next
    edit "d2-geneve-az2"
        set interface "port1"
        set type ppp
        set endpoint-id "vpce-05255912996916e07"
        set remote-ip 10.0.7.81
    next
end

# ============================================================
# 2. Zones — one per VPC. Existing private-zone untouched.
# ============================================================
config system zone
    edit "private-zone"
        set interface "geneve-az1" "geneve-az2"
    next
    edit "d1-zone"
        set interface "d1-geneve-az1" "d1-geneve-az2"
    next
    edit "d2-zone"
        set interface "d2-geneve-az1" "d2-geneve-az2"
    next
end

# ============================================================
# 3. Firewall policy — existing centralized policies untouched.
#    No d1<->d2 or d1/d2->internet policy exists at all.
# ============================================================
config firewall policy
    edit 1
        set name "private_to_internet"
        set srcintf "private-zone"
        set dstintf "port2"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat enable
    next
    edit 2
        set name "private_to_private"
        set srcintf "private-zone"
        set dstintf "private-zone"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat disable
    next
    edit 3
        set name "d1_hairpin"
        set srcintf "d1-zone"
        set dstintf "d1-zone"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat disable
    next
    edit 4
        set name "d2_hairpin"
        set srcintf "d2-zone"
        set dstintf "d2-zone"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat disable
    next
end

# ============================================================
# 4. Router static — GWLB host routes + centralized spoke CIDRs
#    unchanged. Worse-priority 0.0.0.0/0 defaults per device are
#    the only entries needed for the distributed devices.
# ============================================================
config router static
    edit 1
        set dst 10.0.2.204 255.255.255.255
        set device "port1"
        set dynamic-gateway enable
    next
    edit 2
        set dst 10.0.7.81 255.255.255.255
        set device "port1"
        set dynamic-gateway enable
    next
    edit 3
        set dst 192.168.0.0 255.255.255.0
        set distance 5
        set priority 100
        set device "geneve-az1"
    next
    edit 4
        set dst 192.168.1.0 255.255.255.0
        set distance 5
        set priority 100
        set device "geneve-az1"
    next
    edit 6
        set dst 192.168.0.0 255.255.255.0
        set distance 5
        set priority 100
        set device "geneve-az2"
    next
    edit 7
        set dst 192.168.1.0 255.255.255.0
        set distance 5
        set priority 100
        set device "geneve-az2"
    next
    edit 9
        set distance 5
        set priority 100
        set device "geneve-az1"
    next
    edit 10
        set distance 5
        set priority 100
        set device "geneve-az2"
    next
    edit 11
        set distance 5
        set priority 100
        set device "d1-geneve-az1"
    next
    edit 12
        set distance 5
        set priority 100
        set device "d1-geneve-az2"
    next
    edit 13
        set distance 5
        set priority 100
        set device "d2-geneve-az1"
    next
    edit 14
        set distance 5
        set priority 100
        set device "d2-geneve-az2"
    next
end

# ============================================================
# 5. Router policy — distributed devices get a single bare
#    input-device->output-device entry each. Centralized keeps
#    its dst-only entries -- never src-matched.
# ============================================================
config router policy
    edit 3
        set input-device "d1-geneve-az1"
        set output-device "d1-geneve-az1"
    next
    edit 7
        set input-device "d1-geneve-az2"
        set output-device "d1-geneve-az2"
    next
    edit 9
        set input-device "d2-geneve-az1"
        set output-device "d2-geneve-az1"
    next
    edit 11
        set input-device "d2-geneve-az2"
        set output-device "d2-geneve-az2"
    next
    edit 13
        set input-device "geneve-az1"
        set dst "192.168.0.0/255.255.255.0" "192.168.1.0/255.255.255.0"
        set output-device "geneve-az1"
    next
    edit 15
        set input-device "geneve-az2"
        set dst "192.168.0.0/255.255.255.0" "192.168.1.0/255.255.255.0"
        set output-device "geneve-az2"
    next
end
```

`edit` IDs above reflect the shape of the box after iterative testing, not a
literal from-scratch script — for templatizing, use `edit 0` and let
FortiOS auto-assign.

## Traffic Verification

| Path | Test | Result |
|---|---|---|
| distributed_1 | SSH from a real client IP to d1's EIP → `10.100.0.43:22` | Real bidirectional session, correct `route_policy_id`/`policy_id` |
| distributed_2 | SSH from the same client to d2's own (different) EIP → same internal `10.100.0.43:22` | Real bidirectional session — correctly separated despite identical internal address |
| Centralized (east↔internet) | `curl`/`ping 8.8.8.8` from an east spoke instance | Confirmed on `geneve-az1`/`geneve-az2` and the `port2` SNAT leg |
| Centralized (east↔west) | `ping` between east and west spoke instances, both AZs | Confirmed reliable across repeated tests |

## VRF Approach (Optional)

Instead of relying on policy-route pinning in the shared default routing
table, each distributed VPC can get its own VRF (`distributed_1_vrf`,
`distributed_2_vrf`) for routing-table-level isolation. GENEVE tunnels,
zones, firewall policy, and router-policy content are identical to the
flat approach above — only interface VRF assignment and route scoping
differ.

```
# Interface VRF assignment — the only structurally new piece
config system interface
    edit "d1-geneve-az1"
        set vdom "root"
        set vrf 100
        set type geneve
        set interface "port1"
    next
    edit "d1-geneve-az2"
        set vdom "root"
        set vrf 100
        set type geneve
        set interface "port1"
    next
    edit "d2-geneve-az1"
        set vdom "root"
        set vrf 200
        set type geneve
        set interface "port1"
    next
    edit "d2-geneve-az2"
        set vdom "root"
        set vrf 200
        set type geneve
        set interface "port1"
    next
end
```

All `router static` entries for `d1-geneve-*`/`d2-geneve-*` devices get a
matching `set vrf 100`/`set vrf 200` line added.

### Flat vs. VRF

| | Flat (single table) | VRF |
|---|---|---|
| Reliability | Confirmed working | Confirmed working, equivalent |
| Config footprint | Smaller (no `set vrf` lines) | One extra `set vrf` line per interface and per VRF-scoped route |
| Cross-VPC isolation | Enforced by zone/firewall-policy only | Also structurally separated at the routing-table level |
| Future controlled cross-VPC traffic | Just add a firewall policy | Requires explicit VRF route-leaking |
| Precedent on this platform | — | This repo's management interface (`port3`) already uses a non-default VRF |

**Flat is the default** — smaller footprint, equivalent reliability. VRF
remains available for its stronger structural-isolation guarantee.

## Terraform Implementation

Templatized in `terraform/autoscale_template`:

- `enable_distributed_egress_endpoint_id` (bool, requires
  `enable_distributed_egress = true`)
- `distributed_egress_routing_mode` (`"flat"`, default, or `"vrf"`)
- `distributed_1_vrf`/`distributed_2_vrf` (used only in `"vrf"` mode)

`vpc_distributed_egress_endpoint_id.tf` computes each distributed VPC's
per-AZ GWLB Endpoint `vpce-id` and the shared GWLB's own per-AZ IP, feeding
the `.cfg.tftpl` bootstrap templates.

Rendered into all 6 `.cfg.tftpl` variants (1-arm/2-arm ×
plain/`wdm`/`wdm-eni`) — the block only ever references `port1` (the
geneve-hosting interface in every variant) plus its own new zone/device
names, nothing arm-mode-specific.

Endpoint creation is guaranteed to complete before the FortiGate boots — a
structural property of the Terraform dependency graph (`aws_launch_template`
transitively depends on the `aws_vpc_endpoint` resources that produce the
vpce-ids), not something that needs manual sequencing.

**Operational note:** if a distributed VPC's endpoint is ever replaced
after initial deploy (e.g. a CIDR change forces recreation, new vpce-id),
already-running FortiGate instances won't pick up the new `endpoint-id`
automatically — only new instances launching after the launch template
updates will. Same characteristic Mode A already has for `spoke_cidrs`
changes.

## Status

Not available outside the STS test build referenced above. Fully
templatized on this branch (`feat/mode-b-endpoint-id-geneve`), not merged
to `main`, until `endpoint-id` (or an equivalent mechanism) ships in a
generally-available FortiOS release.

## Next Steps (Blocked)

1. Wait for `endpoint-id` (or equivalent) to ship in a non-STS FortiOS
   build.
2. Once available: update
   `content/5_Templates/5_6_Distributed_Egress/_index.md` and
   `content/5_Templates/_index.md` to mention overlapping CIDRs as a
   generally-available option — they currently intentionally still frame
   it as experimental/STS-only, matching
   `content/5_Templates/5_7_Overlapping_CIDR_Egress/_index.md`.
