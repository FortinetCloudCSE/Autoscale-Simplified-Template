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

The `endpoint-id` field on `config system geneve` that this page depends on only exists in a Fortinet STS/test build (`build_tag_7121` as of this writing), not any generally-available FortiOS release. Everything below is hand-applied CLI, validated with real traffic on that test build. Do not attempt this against a production FortiGate. If you need this capability today, contact your Fortinet account team about the STS build's availability.
{{% /notice %}}

{{% notice note %}}
**2-arm (`wdm`) Only**

Terraform templatization of this feature, where it exists, targets only the `2-arm-wdm` bootstrap config — the same variant that was actually live-tested when [Distributed Egress](../5_6_distributed_egress/) (Mode A) shipped. The other five `.cfg.tftpl` variants (1-arm, non-`wdm`, `eni`) do not have this feature and are not planned to until 2-arm-`wdm` is proven out further.
{{% /notice %}}

---

## Architecture

The mechanism is additive on top of the existing [Distributed Egress](../5_6_distributed_egress/) architecture — same shared GWLB, same GWLB Endpoint Service, same Ingress Routing pattern for inbound-to-EIP traffic. The difference is entirely on the FortiGate side:

- Instead of two shared `geneve-az1`/`geneve-az2` tunnels carrying centralized *and* every distributed VPC's traffic together, **each distributed VPC gets its own pair of tunnels** (one per AZ), each bound with `set endpoint-id "vpce-xxxxxxxx"` to that VPC's specific GWLB Endpoint.
- Because classification now happens by tunnel identity, each distributed VPC also gets **its own firewall zone** — real structural isolation (no firewall policy exists permitting traffic between two distributed VPCs, or from a distributed VPC out through the centralized internet-egress policy) instead of relying on CIDR-address correctness.
- Two ways to keep routing/RPF unambiguous once tunnels are split this way — a **flat** approach (everything in the default routing table, disambiguated by policy routing) and a **VRF** approach (each distributed VPC gets its own routing table). Both are documented below, with a comparison at the end.

---

## Configuration — Flat (Policy-Route) Approach

Everything lives in the default routing table (`VRF=0`) alongside centralized traffic. Ambiguity between distributed VPCs sharing a CIDR is resolved entirely by `router policy` pinning traffic to the specific device it arrived on.

### GENEVE Tunnels

Every tunnel — including the pre-existing centralized ones, if you're retagging them — needs `set type ppp`. Without it, FortiOS expects L2/ARP resolution over the tunnel, which GWLB's GENEVE channel can't answer, and nothing forwards:

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

Just the same worse-priority `0.0.0.0/0` default route per device that centralized-only deployments already use, extended to the new devices — this satisfies the reverse-path check for arbitrary internet-sourced traffic (e.g. port scans hitting an EIP) the way it always has for centralized:

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
**No specific-CIDR route needed — confirmed by direct retest, not just a simplification for its own sake.** An earlier version of this page recommended an additional specific `/24` route per device (at an elevated distance, to give RPF an unambiguous candidate). That turned out to be unnecessary: GWLB is a bump-in-the-wire, not a router — once the FortiGate hands a packet back to GWLB, AWS's own routing underneath (e.g. this project's Inspection VPC `gwlbe` subnet route table) does the real forwarding, regardless of which specific device FortiOS used. The generic default route above is enough to satisfy FortiOS's own RPF bookkeeping. See the "Resolved" section of `MODE_B_ENDPOINT_ID_GENEVE.md` at the repo root for the full story, including the colleague (Louie, Fortinet) who found this independently.
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

{{% notice note %}}
**Also confirmed unnecessary by direct retest.** An earlier version of this page recommended pairing every rule with a `dst`-matched and `src`-matched CIDR clause, based on inconsistent behavior seen with the bare form during initial testing. Retested (2026-08-19) with the specific-CIDR static route above also removed, and the bare form held up reliably — same conclusion Louie reached independently, backed by session-list evidence (`route_policy_id` correctly recorded per session, sustained multi-session traffic, no cross-VPC bleed).
{{% /notice %}}

If you're also retagging the *centralized* `geneve-az1`/`geneve-az2` rules while doing this: keep those `dst`-matched (not bare, not `src`-matched). A `src`-matched centralized rule with no `dst` restriction captures a spoke's legitimate internet-bound traffic and incorrectly hairpins it back through `geneve` instead of letting it exit normally — distributed VPCs are *supposed* to hairpin their own egress this way, centralized is not. This one is unrelated to the simplification above and still applies.

---

## Configuration — VRF Approach

Instead of disambiguating shared-table ambiguity with policy routing, give each distributed VPC its own routing table (VRF). GENEVE tunnels, zones, and firewall policy are identical to the flat approach above — only interface VRF assignment and route scoping differ.

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

### Policy Routes

Same bare `input-device`→`output-device` form as the flat approach, unchanged — VRF doesn't change what's needed here.

### What Actually Improves Under VRF

Confirmed via `get router info routing-table all`: each VRF shows *only* its own VPC's `10.100.0.0/24` (as a directly-connected route, from the interface itself — no static route needed for it at all), with zero visibility into the sibling VPC's identical CIDR. **This matters less than it first appeared to.** The original case for VRF was that it eliminates a fragile, hand-tuned specific-CIDR static route needed for RPF — but direct retest (see the note above) showed that route isn't needed at all, under either approach. GWLB's bump-in-the-wire model means the real forwarding decision happens in AWS's own routing once a packet is handed back to it, not in FortiOS's static/policy-route tables — so the structural isolation VRF provides isn't compensating for a real fragility the way it seemed to be.

---

## Flat vs. VRF — Comparison

Both approaches are now confirmed equally reliable — the specific-CIDR static route and CIDR-paired policy routes that originally motivated preferring VRF turned out to be unnecessary under either approach (see the notes above). The comparison is now mostly about structural properties, not reliability:

| | Flat (single table) | VRF |
|---|---|---|
| Reliability | Confirmed working, same as VRF | Confirmed working, same as flat |
| Config footprint | Smaller (no `set vrf` lines) | One extra `set vrf` line per interface and per VRF-scoped route |
| Cross-VPC isolation | Enforced by zone/firewall-policy only | Also structurally separated at the routing-table level |
| Future controlled cross-VPC traffic | Just add a firewall policy | Requires explicit VRF route-leaking |
| Precedent on this platform | — | This repo's management interface (`port3`) already uses a non-default VRF |

Given the reliability case for VRF no longer holds, **flat is arguably the simpler default now** — smaller diff, one less concept to explain. VRF still has a legitimate argument on structural grounds (routing-table-level isolation is a stronger guarantee than zone/policy alone, in the same spirit as the zone-per-VPC design decision above), but it's a genuine trade-off now rather than VRF clearly winning. Not yet revisited in the Terraform default (`distributed_egress_routing_mode` still defaults to `"vrf"`) — worth a deliberate decision rather than leaving it as a holdover from before this was known.

---

## Known Issues Found on the STS Build

These were found through `diagnose debug flow`, `diagnose firewall proute list`, and `diagnose sys session list` while validating this feature — worth knowing about if you hit something that looks similar, and distinct from anything in shipped [Distributed Egress](../5_6_distributed_egress/):

1. **`set type ppp` is required on every new GENEVE tunnel.** Omitting it causes the tunnel to expect ARP resolution it can never get, and nothing forwards.
2. **Router-policy rules combining both `src` and `dst` in the same entry never matched, on this build specifically.** Note this is *not* a general FortiOS limitation — the shipped [Distributed Egress](../5_6_distributed_egress/#policy-routes) centralized east-west rule uses exactly this combined form successfully on generally-available FortiOS. It only failed on this specific STS test build; treat it as a build quirk to watch for if you're testing against this same STS build, not a pattern to avoid on production firmware. Applies to the *centralized* rules only — always keep those `dst`-only regardless, as noted above.

Two earlier entries in this list — a specific per-device RPF static route, and CIDR-paired distributed policy-route rules — were retracted after further testing showed they weren't actually necessary. See the notes in the Static Routes and Policy Routes sections above.

---

## Status

Not yet available outside the STS test build referenced above. The configuration above **is** templatized — on an unmerged branch (`feat/mode-b-endpoint-id-geneve`), not `main` — behind `enable_distributed_egress_endpoint_id` (requires `enable_distributed_egress = true`), `distributed_egress_routing_mode` (`"flat"`/`"vrf"`, default `"vrf"`), and `distributed_1_vrf`/`distributed_2_vrf`. It stays on that branch, not merged, until `endpoint-id` (or an equivalent mechanism) ships in a generally-available FortiOS release — see `MODE_B_ENDPOINT_ID_GENEVE.md` at the repo root for full implementation detail.
