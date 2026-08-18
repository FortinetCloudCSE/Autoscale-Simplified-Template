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

Each distributed VPC's CIDR needs its own specific route **per device** (four entries for two AZs × one VPC) — not one shared route, which would recreate the exact ambiguity this whole mechanism exists to avoid. A moderately elevated distance (e.g. `10`) keeps these from ever winning a real forwarding decision while still satisfying FortiOS's reverse-path check:

```
config router static
    edit 0
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d1-geneve-az1"
    next
    edit 0
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d1-geneve-az2"
    next
    edit 0
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d2-geneve-az1"
    next
    edit 0
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d2-geneve-az2"
    next
end
```

{{% notice warning %}}
**A very high distance value backfired in testing.** `distance 250` (near FortiOS's 255 maximum) caused the real default route to win instead — it appeared to fall out of consideration as a live candidate entirely. Keep the distance modest (`10` was used successfully) rather than pushing it to an extreme.
{{% /notice %}}

Also keep the same worse-priority `0.0.0.0/0` default route per device that centralized-only deployments already use, extended to the new devices — this satisfies the reverse-path check for arbitrary internet-sourced traffic (e.g. port scans hitting an EIP) the way it always has for centralized.

### Policy Routes

Each device needs a `dst`-matched (forward leg) **and** `src`-matched (reply leg) entry, both still keyed on `input-device`:

```
config router policy
    edit 0
        set input-device "d1-geneve-az1"
        set dst "10.100.0.0/255.255.255.0"
        set output-device "d1-geneve-az1"
    next
    edit 0
        set input-device "d1-geneve-az1"
        set src "10.100.0.0/255.255.255.0"
        set output-device "d1-geneve-az1"
    next
    ... (same dst/src pair for d1-geneve-az2, d2-geneve-az1, d2-geneve-az2)
end
```

{{% notice warning %}}
**A single unconditional `input-device`-only rule (no `src`/`dst` at all) proved unreliable** in testing — traffic sometimes still resolved via the static table's tie between devices instead of the policy-route pin, occasionally crossing between VPCs (though the zone split correctly denied those at the firewall-policy layer). The `dst`/`src`-paired form above is required, not just a style preference.
{{% /notice %}}

If you're also retagging the *centralized* `geneve-az1`/`geneve-az2` rules while doing this: use only the `dst`-matched pair for centralized, not a `src`-matched one. A `src`-matched centralized rule with no `dst` restriction also captures a spoke's legitimate internet-bound traffic and incorrectly hairpins it back through `geneve` instead of letting it exit normally — distributed VPCs are *supposed* to hairpin their own egress this way, centralized is not.

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

Same per-device specific-CIDR pattern as the flat approach, with a matching `set vrf` added:

```
config router static
    edit 0
        set vrf 100
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d1-geneve-az1"
    next
    ... (same pattern for d1-geneve-az2, and vrf 200 for d2's two devices)
end
```

### Policy Routes

**Still required — VRF does not remove the need for these.** VRF separation solves the *cross-VPC* ambiguity (two VPCs sharing a CIDR), but each VPC's own two AZ devices still tie against each other within that VPC's own VRF, and GWLB requires a flow to hairpin back out the same AZ it arrived on. Use the identical `dst`/`src`-paired form as the flat approach, unchanged.

### What Actually Improves Under VRF

Confirmed via `get router info routing-table all`: each VRF shows *only* its own VPC's `10.100.0.0/24`, with zero visibility into the sibling VPC's identical CIDR — a clean 2-way tie (that VPC's own two AZs) instead of a system-wide tie across every device on the box. This is what made the flat approach's RPF static-route distance genuinely fragile to tune (see the `distance 250` warning above) — under VRF, that fragility doesn't apply, since there's no cross-VPC candidate to accidentally lose to.

---

## Flat vs. VRF — Comparison

| | Flat (single table) | VRF |
|---|---|---|
| Cross-VPC RPF/routing ambiguity | Resolved by careful distance tuning on shared-table routes | Resolved structurally — separate tables, nothing to tune |
| AZ-level flow symmetry (same VPC, both AZs) | Requires policy-route `dst`/`src` pairing | Still requires policy-route `dst`/`src` pairing — VRF doesn't remove this |
| Config footprint | Slightly smaller (no `set vrf` lines) | One extra `set vrf` line per interface and per VRF-scoped route |
| Future controlled cross-VPC traffic | Just add a firewall policy | Requires explicit VRF route-leaking |
| Precedent on this platform | — | This repo's management interface (`port3`) already uses a non-default VRF |

For a design with a hard "no traffic between distributed VPCs, ever" requirement — which is the case here — VRF is the better default: it trades a small amount of upfront structure for eliminating the flat approach's least predictable failure mode.

---

## Known Issues Found on the STS Build

These were found through `diagnose debug flow`, `diagnose firewall proute list`, and `diagnose sys session list` while validating this feature — worth knowing about if you hit something that looks similar, and distinct from anything in shipped [Distributed Egress](../5_6_distributed_egress/):

1. **`set type ppp` is required on every new GENEVE tunnel.** Omitting it causes the tunnel to expect ARP resolution it can never get, and nothing forwards.
2. **RPF needs a specific per-device static route, not `src-check disable`.** Deleting an ambiguous shared route and relying only on generic `0.0.0.0/0` candidates fails FortiOS's reverse-path check entirely.
3. **Bare `input-device`-only policy-route rules are unreliable** — pair every rule with `dst` or `src`, matching the pattern already used in shipped [Distributed Egress](../5_6_distributed_egress/#policy-routes).
4. **Router-policy rules combining both `src` and `dst` in the same entry never matched, on this build specifically.** Note this is *not* a general FortiOS limitation — the shipped [Distributed Egress](../5_6_distributed_egress/#policy-routes) centralized east-west rule uses exactly this combined form successfully on generally-available FortiOS. It only failed on this specific STS test build; treat it as a build quirk to watch for if you're testing against this same STS build, not a pattern to avoid on production firmware.

---

## Status

Not yet available outside the STS test build referenced above. Once `endpoint-id` (or an equivalent mechanism) ships in a generally-available FortiOS release, the next step is templatizing the configuration above into this repo's `.cfg.tftpl` bootstrap files, gated behind a new variable, the same way [Distributed Egress](../5_6_distributed_egress/) is gated behind `enable_distributed_egress` today.
