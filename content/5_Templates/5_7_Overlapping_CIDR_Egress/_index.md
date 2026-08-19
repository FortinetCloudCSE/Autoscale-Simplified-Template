---
title: "Overlapping-CIDR Distributed Egress (Experimental)"
chapter: false
menuTitle: "Overlapping-CIDR Egress"
weight: 57
---

## Overview

[Distributed Egress](../5_6_distributed_egress/) requires every distributed VPC's CIDR to be distinct — the FortiGate classifies traffic by matching source/destination address against each VPC's CIDR, so two VPCs sharing the same range are indistinguishable to it. This page documents an alternate mechanism that removes that requirement: a GENEVE tunnel keyed to the specific AWS GWLB Endpoint (`vpce-id`) a packet actually arrived on, instead of only the shared GWLB's IP. Two distributed VPCs can then use the identical CIDR and still be told apart, because classification happens at the tunnel layer, not by address.

{{% notice warning %}}
**Requires a Special FortiOS Build — Not Available Today**

The `endpoint-id` field on `config system geneve` that this page depends on only exists in a Fortinet STS/test build (`build_tag_7121` as of this writing), not any generally-available FortiOS release. Do not attempt this against a production FortiGate. If you need this capability today, contact your Fortinet account team about the STS build's availability.
{{% /notice %}}

{{% notice note %}}
**All 6 `.cfg.tftpl` Variants, Different Levels of Testing**

Terraform templatization of this feature is in all six bootstrap config variants (1-arm/2-arm × plain/`wdm`/`wdm-eni`) — the block only ever references `port1`, the geneve-hosting interface in every variant, plus its own new zone/device names, so there's nothing arm-mode- or management-mode-specific about it. Testing coverage differs: `2-arm-wdm`, `1-arm-wdm`, and plain `1-arm` have been `terraform plan`-validated against real live infrastructure; `1-arm-wdm-eni` and `2-arm-wdm-eni` currently only have `terraform validate` (syntax/semantics), not a live plan.
{{% /notice %}}

---

## Architecture

The mechanism is additive on top of the existing [Distributed Egress](../5_6_distributed_egress/) architecture — same shared GWLB, same GWLB Endpoint Service, same Ingress Routing pattern for inbound-to-EIP traffic. The difference is entirely on the FortiGate side:

- Instead of two shared `geneve-az1`/`geneve-az2` tunnels carrying centralized *and* every distributed VPC's traffic together, **each distributed VPC gets its own pair of tunnels** (one per AZ), each bound with `set endpoint-id "vpce-xxxxxxxx"` to that VPC's specific GWLB Endpoint.
- Because classification now happens by tunnel identity, each distributed VPC also gets **its own firewall zone** — real structural isolation (no firewall policy exists permitting traffic between two distributed VPCs, or from a distributed VPC out through the centralized internet-egress policy) instead of relying on CIDR-address correctness.
- Two ways to keep routing unambiguous once tunnels are split this way — a **flat** approach (everything in the default routing table, disambiguated by policy routing) and a **VRF** approach (each distributed VPC gets its own routing table). Both are documented below, with a comparison at the end.

---

## Configuration — Flat (Policy-Route) Approach

Everything lives in the default routing table (`VRF=0`) alongside centralized traffic. Ambiguity between distributed VPCs sharing a CIDR is resolved entirely by `router policy` pinning traffic to the specific device it arrived on.

### GENEVE Tunnels

Every tunnel — including the pre-existing centralized ones, if you're retagging them — needs `set type ppp`:

```
config system geneve
    edit "geneve-az1"
        set interface "port1"
        set type ppp
        set endpoint-id "<centralized-vpce-id-az1>"
        set remote-ip <gwlb-ip-az1>
    next
    edit "geneve-az2"
        set interface "port1"
        set type ppp
        set endpoint-id "<centralized-vpce-id-az2>"
        set remote-ip <gwlb-ip-az2>
    next
    edit "d1-geneve-az1"
        set interface "port1"
        set type ppp
        set endpoint-id "<distributed-1-vpce-id-az1>"
        set remote-ip <gwlb-ip-az1>
    next
    edit "d1-geneve-az2"
        set interface "port1"
        set type ppp
        set endpoint-id "<distributed-1-vpce-id-az2>"
        set remote-ip <gwlb-ip-az2>
    next
    edit "d2-geneve-az1"
        set interface "port1"
        set type ppp
        set endpoint-id "<distributed-2-vpce-id-az1>"
        set remote-ip <gwlb-ip-az1>
    next
    edit "d2-geneve-az2"
        set interface "port1"
        set type ppp
        set endpoint-id "<distributed-2-vpce-id-az2>"
        set remote-ip <gwlb-ip-az2>
    next
end
```

`remote-ip` is the shared GWLB's own per-AZ IP — the same value for every VPC in a given AZ. `endpoint-id` is what actually disambiguates them.

### Zones

One zone per VPC. The existing centralized `private-zone` doesn't need to change — new zones are added alongside it:

```
config system zone
    edit "d1-zone"
        set interface "d1-geneve-az1" "d1-geneve-az2"
    next
    edit "d2-zone"
        set interface "d2-geneve-az1" "d2-geneve-az2"
    next
end
```

### Firewall Policy

Add a same-zone hairpin policy per VPC. Deliberately **no** policy permits `d1-zone`↔`d2-zone` or `d1-zone`/`d2-zone`→`port1`/`port2`/`port3` — isolation is structural, not just a matter of getting CIDR objects right:

```
config firewall policy
    edit 0
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
    edit 0
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
```

### Static Routes

Just the worse-priority `0.0.0.0/0` default route per device that centralized-only deployments already use, extended to the new devices — no CIDR-specific route is needed:

```
config router static
    edit 0
        set distance 5
        set priority 100
        set device "d1-geneve-az1"
    next
    edit 0
        set distance 5
        set priority 100
        set device "d1-geneve-az2"
    next
    edit 0
        set distance 5
        set priority 100
        set device "d2-geneve-az1"
    next
    edit 0
        set distance 5
        set priority 100
        set device "d2-geneve-az2"
    next
end
```

{{% notice note %}}
**Why no CIDR-specific route is needed:** GWLB is a bump-in-the-wire, not a router — once the FortiGate hands a packet back to GWLB, AWS's own routing underneath (e.g. this project's Inspection VPC `gwlbe` subnet route table) does the real forwarding, regardless of which specific device FortiOS used. The generic default route above is enough to satisfy FortiOS's own reverse-path-check bookkeeping.
{{% /notice %}}

### Policy Routes

A single bare `input-device`→`output-device` entry per device — no `dst`/`src` matching needed:

```
config router policy
    edit 0
        set input-device "d1-geneve-az1"
        set output-device "d1-geneve-az1"
    next
    edit 0
        set input-device "d1-geneve-az2"
        set output-device "d1-geneve-az2"
    next
    edit 0
        set input-device "d2-geneve-az1"
        set output-device "d2-geneve-az1"
    next
    edit 0
        set input-device "d2-geneve-az2"
        set output-device "d2-geneve-az2"
    next
end
```

If you're also retagging the *centralized* `geneve-az1`/`geneve-az2` rules while doing this, they need different treatment than the distributed devices:

{{% notice warning %}}
**Centralized router-policy rules must be `dst`-matched only — never bare, and never `src`-matched.** A bare or `src`-matched-only centralized rule (with no `dst` restriction) captures a spoke's legitimate internet-bound traffic and incorrectly hairpins it back through `geneve` instead of letting it exit normally via `port2` — distributed VPCs are *supposed* to hairpin their own egress this way, centralized is not. Also, on this specific STS build, combining both `src` and `dst` in the same centralized entry doesn't reliably match — use a single-clause `dst`-matched rule per AZ (see [Distributed Egress](../5_6_distributed_egress/#policy-routes) for the pattern). A broad RFC1918 summary (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) works as the `dst` match just as well as the specific spoke CIDRs — and means this rule doesn't need to know what's actually south of the TGW.
{{% /notice %}}

---

## Configuration — VRF Approach

Instead of disambiguating shared-table ambiguity with policy routing, give each distributed VPC its own routing table (VRF). GENEVE tunnels, zones, firewall policy, and policy routes are identical to the flat approach above — only interface VRF assignment and route scoping differ.

### VRF Assignment

```
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

Centralized tunnels stay in the default `VRF=0`, untouched.

### Static Routes

Same worse-priority default-route pattern as the flat approach, with a matching `set vrf` added:

```
config router static
    edit 0
        set vrf 100
        set distance 5
        set priority 100
        set device "d1-geneve-az1"
    next
    ... (same pattern for d1-geneve-az2, and vrf 200 for d2's two devices)
end
```

Each VRF's own `10.100.0.0/24` (or whatever the overlapping CIDR is) shows up as a directly-connected route from the interface itself — no static route needed for it at all, and no visibility into the sibling VPC's identical CIDR.

---

## Flat vs. VRF — Comparison

| | Flat (single table) | VRF |
|---|---|---|
| Reliability | Confirmed working | Confirmed working, equivalent |
| Config footprint | Smaller (no `set vrf` lines) | One extra `set vrf` line per interface and per VRF-scoped route |
| Cross-VPC isolation | Enforced by zone/firewall-policy only | Also structurally separated at the routing-table level |
| Future controlled cross-VPC traffic | Just add a firewall policy | Requires explicit VRF route-leaking |
| Precedent on this platform | — | This repo's management interface (`port3`) already uses a non-default VRF |

`distributed_egress_routing_mode` defaults to `"flat"` — smaller footprint, equivalent reliability. VRF (`"vrf"`) remains available and is a legitimate choice for its stronger structural-isolation guarantee, in the same spirit as the zone-per-VPC design above.

---

## Status

Not yet available outside the STS test build referenced above. The configuration above **is** templatized — on an unmerged branch (`feat/mode-b-endpoint-id-geneve`), not `main` — behind `enable_distributed_egress_endpoint_id` (requires `enable_distributed_egress = true`), `distributed_egress_routing_mode` (`"flat"`/`"vrf"`, default `"flat"`), and `distributed_1_vrf`/`distributed_2_vrf`. It stays on that branch, not merged, until `endpoint-id` (or an equivalent mechanism) ships in a generally-available FortiOS release — see `OVERLAPPING_CIDR_GENEVE_ENDPOINT_ID.md` at the repo root for full implementation detail.
