# Mode B: Overlapping-CIDR Distributed Egress via GENEVE Endpoint-ID

> **Status: NOT MERGED. Do not merge this branch until a non-STS FortiOS
> build ships `endpoint-id` support.** This is saved here purely to preserve
> validated, traffic-tested work — it depends on a special/test FortiOS build
> (`build_tag_7121`, contact Aaron Jones, Fortinet Cloud PM) that is not
> generally available. See [Status](#status) below.

## TL;DR

Fortinet's STS/test FortiOS build `build_tag_7121`
(`FGVMA6-7.6.7-FW-build3704-260817`) exposes a new `endpoint-id` field on
`config system geneve`, letting a GENEVE tunnel be keyed to a specific AWS
GWLB Endpoint (`vpce-id`) instead of only `remote-ip`. This removes the
[Mode A](content/5_Templates/5_6_Distributed_Egress/_index.md) hard
requirement that distributed VPCs must not share overlapping CIDRs — with
`remote-ip`-only keying, FortiOS has no way to tell which VPC a packet came
from when two VPCs use an identical CIDR; with `endpoint-id`, it does.

Two intentionally-overlapping distributed VPCs (`10.100.0.0/24` on both
sides), plus the pre-existing centralized path, were built against this
build and traffic-verified end to end (real SSH sessions, real ICMP/TCP
east-west and internet-egress traffic — not just clean `show`/config
application). Getting there required four real fixes beyond the initial
draft config, all found via `diagnose debug flow`, `diagnose firewall
proute list`, and `diagnose sys session list`. A second full pass moved the
distributed VPCs into their own VRFs and compared the two approaches.

## Status

- **Not proven on a generally-available FortiOS build.** Everything below
  was validated on the STS build only. Do not merge this branch until
  `endpoint-id` (or an equivalent mechanism) ships in a normal release.
- **Templatization is done**, on this branch — `terraform/autoscale_template`
  now has `enable_distributed_egress_endpoint_id`,
  `distributed_egress_routing_mode` (`"flat"`/`"vrf"`), and
  `distributed_1_vrf`/`distributed_2_vrf`, plus the rendered CLI in
  `2-arm-wdm-fgt-conf.cfg.tftpl` for both routing modes. Validated with
  `terraform validate` and `terraform plan` against real live
  infrastructure — the rendered config is byte-identical to the
  live-tested CLI below, including real vpce-ids and GWLB IPs. See
  [Terraform Implementation Notes](#terraform-implementation-notes).
- Real bugs/quirks found on this specific build are documented below so
  they aren't rediscovered from scratch next time, and so they can be
  reported back to Fortinet.
- A full write-up (this same content, PDF-exported) was prepared for
  submission to the STS build's developer contact.
- Three findings from integrating the vendored `terraform-aws-cloud-modules`
  dependency (one real bug, two documentation gaps) were written up
  separately for that project's maintainer — see
  `~/Downloads/terraform-aws-cloud-modules_findings.pdf` (not checked into
  this repo, it's about a different project).

## The four real fixes (flat/policy-route approach)

1. **`set type ppp` is required on every new GENEVE tunnel — not optional.**
   The developer's example syntax omitted it. Without it, FortiOS treats
   the tunnel as needing L2/ARP resolution instead of point-to-point, and
   it endlessly ARPs for the destination with no reply (AWS's GWLB GENEVE
   channel has no real L2 domain to answer it) — nothing forwards. The
   pre-existing centralized tunnels (`geneve-az1`/`geneve-az2`, only
   `edit`ed to add `endpoint-id`, never recreated) kept `type ppp` from the
   original Lambda bootstrap and were unaffected.

2. **RPF (`reverse path check fail, drop`) needs a specific, per-device
   `/24` static route — not `src-check disable`.** Deleting the old
   ambiguous shared `10.100.0.0/24` route (correct — one route can't
   represent two different VPCs) left RPF nothing to match except the
   generic `0.0.0.0/0` default routes — a 6-way tie instead of Mode A's
   original 2, which failed RPF 100% of the time. Fix: one specific `/24`
   route **per real device** (four total), all tied at a moderately
   elevated distance. RPF just needs *a* candidate whose interface matches
   the arrival interface, not a single globally-resolved one — this isn't
   the same ambiguity as the deleted shared route.
   **Pitfall found by trial:** `distance 250` (near FortiOS's 255 max)
   caused the real `port2` default route to win instead — apparently too
   extreme to be treated as a live candidate. `distance 10` worked.

3. **Router policy needs CIDR-paired entries, not bare `input-device`-only
   rules.** Four unconditional `input-device`→`output-device` entries were
   inconsistent — `proute list` showed real hits, but `diagnose debug flow`
   still sometimes resolved forwarding via the static table's ECMP tie
   across all 4 devices instead of policy-route's pinning (occasionally
   cross-VPC, though the zone split correctly caught and denied those).
   Fix: 8 entries — a `dst`-matched (forward leg) and `src`-matched (reply
   leg) pair per device, still keyed on `input-device` (doesn't reintroduce
   the CIDR ambiguity — `input-device` alone already disambiguates d1 vs
   d2).

4. **Router-policy rules combining `src` AND `dst` in the same entry appear
   to never match.** Found on the *pre-existing* centralized rules — both
   `src` and `dst` set simultaneously, `hit_count=0` in `diagnose firewall
   proute list`, never matched, despite repeated matching east-west
   traffic. Caused intermittent failures (worked twice, failed the third
   attempt) — forwarding fell through to the static table's ECMP tie,
   occasionally picking the "wrong" AZ. Fix: split into 4 single-clause
   entries (dst + src pair per AZ), same pattern as #3.

**Design decision:** 3 zones, not 1. Retrofitting all 6 tunnels into one
shared zone would have required deleting/editing the existing
`private-zone` (blocked by FortiOS while firewall policy still references
it). Going additive — new `d1-zone`/`d2-zone`, existing `private-zone`
untouched — avoided that dependency chain and gives a real structural
guarantee (no `d1↔d2` or `d1/d2→internet` firewall policy exists at all)
rather than relying purely on router-policy correctness.

**A fifth issue, found during the VRF comparison but applicable to the flat
model too:** the centralized `src`-matched router-policy entries
(mechanically copied from the d1/d2 pattern) have no `dst` restriction, so
they also capture legitimate spoke→internet traffic and incorrectly
hairpin it back through `geneve` instead of letting it fall through to
`port2`. This is a design distinction, not a build bug — distributed VPCs'
own internet-bound traffic is *supposed* to hairpin back through their own
tunnel (that's the point of distributed egress), but centralized traffic
is supposed to egress via `port2`. **Fix: centralized only needs the
`dst`-matched entries — the `src`-matched pair should not exist for
`geneve-az1`/`geneve-az2`.**

## Complete validated CLI (flat / policy-route approach)

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
#    untouched. Specific /24 routes (distance 10) fix RPF for
#    the overlapping CIDR itself. Do NOT collapse these into a
#    single shared /24 route across both VPCs — that reintroduces
#    the exact ambiguity this design exists to eliminate.
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
    edit 15
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d1-geneve-az1"
    next
    edit 16
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d1-geneve-az2"
    next
    edit 17
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d2-geneve-az1"
    next
    edit 18
        set dst 10.100.0.0 255.255.255.0
        set distance 10
        set device "d2-geneve-az2"
    next
end

# ============================================================
# 5. Router policy — d1/d2 need dst+src pairs (fix #3).
#    Centralized needs ONLY the dst-matched entries (fix #5) —
#    a src-matched centralized entry incorrectly hairpins
#    spoke->internet traffic that should egress via port2.
# ============================================================
config router policy
    edit 3
        set input-device "d1-geneve-az1"
        set dst "10.100.0.0/255.255.255.0"
        set output-device "d1-geneve-az1"
    next
    edit 4
        set input-device "d1-geneve-az1"
        set src "10.100.0.0/255.255.255.0"
        set output-device "d1-geneve-az1"
    next
    edit 7
        set input-device "d1-geneve-az2"
        set dst "10.100.0.0/255.255.255.0"
        set output-device "d1-geneve-az2"
    next
    edit 8
        set input-device "d1-geneve-az2"
        set src "10.100.0.0/255.255.255.0"
        set output-device "d1-geneve-az2"
    next
    edit 9
        set input-device "d2-geneve-az1"
        set dst "10.100.0.0/255.255.255.0"
        set output-device "d2-geneve-az1"
    next
    edit 10
        set input-device "d2-geneve-az1"
        set src "10.100.0.0/255.255.255.0"
        set output-device "d2-geneve-az1"
    next
    edit 11
        set input-device "d2-geneve-az2"
        set dst "10.100.0.0/255.255.255.0"
        set output-device "d2-geneve-az2"
    next
    edit 12
        set input-device "d2-geneve-az2"
        set src "10.100.0.0/255.255.255.0"
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

## Traffic verification performed

| Path | Test | Evidence |
|---|---|---|
| distributed_1 | SSH from a real client IP to d1's EIP → `10.100.0.43:22` | Real bidirectional session bytes, correct `route_policy_id`/`policy_id` |
| distributed_2 | SSH from the same client to d2's own (different) EIP → same internal `10.100.0.43:22` | Real bidirectional session bytes — correctly separated despite identical internal address |
| Centralized (east↔internet) | `curl`/`ping 8.8.8.8` from an east spoke instance | Sniffer confirmed traffic on `geneve-az1`/`geneve-az2` and the `port2` SNAT leg (filtered on the real destination, not the pre-NAT source, since SNAT changes the visible address) |
| Centralized (east↔west) | `ping` between east and west spoke instances, both AZs | Initially intermittent (fix #4) — reliable after the router-policy split |

## VRF-based alternative (comparison)

A second full pass moved `d1`/`d2`'s tunnels into their own VRFs (100 and
200) instead of relying purely on policy-route pinning in a single shared
table, to see whether it would have avoided the harder-won fixes above.

**What VRFs avoided:** the RPF ambiguity (fix #2) and the ECMP-tie
forwarding non-determinism (fix #3) are both consequences of one shared
routing table having no interface-awareness in its lookup. With `d1`'s
tunnels in `VRF=100` and `d2`'s in `VRF=200`, `get router info
routing-table all` showed each VRF with *only its own* `10.100.0.0/24` —
zero visibility into the sibling VPC's identical CIDR, a clean 2-way tie
(the VPC's own two AZs) instead of a 6-way tie across the whole box.

**What VRFs did NOT avoid:** `type ppp` (fix #1, interface-level, orthogonal
to VRF) and the combined-`src`+`dst`-never-matches bug (fix #4, a general
router-policy engine quirk found on the *centralized* rules, unrelated to
the overlapping-CIDR problem). Router-policy entry *count* for `d1`/`d2`
stayed the same under VRF (8 entries) — AZ-level flow symmetry is a
separate problem from cross-VPC CIDR ambiguity and doesn't go away just
because the VPCs are in different VRFs.

**Net assessment:** for a design with a hard "no cross-VPC traffic, ever"
requirement (which this one has), VRFs trade a small amount of upfront
structural setup (`set vrf <N>` on each interface and each VRF-scoped
static route) for eliminating the fragile, trial-and-error parts of the
flat approach (the `distance 250` pitfall, the 6-way ECMP non-determinism)
in favor of a structural guarantee. This box already uses VRFs elsewhere
(the management interface, `port3`, sits in `VRF=1`), so it wouldn't be a
novel operational pattern here.

### VRF-specific CLI diff (on top of everything above)

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
matching `set vrf 100`/`set vrf 200` line added. Zones, firewall policy,
and router-policy content are otherwise identical to the flat model above.

## Terraform Implementation Notes

**Endpoint creation is correctly ordered before the FortiGate boots — verified,
not assumed.** A natural question: the distributed VPCs' GWLB Endpoints
(source of the vpce-ids baked into `endpoint-id`) are created by the *same*
`terraform apply` as the FortiGate ASG itself — does the FortiGate's launch
template actually end up with the real vpce-ids, or could it boot before
they exist? Checked directly via `terraform graph`, not just reasoned about:
`aws_launch_template.fgt` (the real launch-template resource, not the
`data.aws_launch_template` AMI-lookup source) has a transitive dependency on
`aws_vpc_endpoint.gwlb_endps` (which includes the `distributed_1-*`/
`distributed_2-*` instances). This isn't something that had to be manually
wired up — it falls out naturally because `local.distributed_egress_endpoint_id_devices`
(in `vpc_distributed_egress_endpoint_id.tf`) references
`module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps[...]`, and that local feeds the
same `templatefile()` call that produces `user_conf_content`, which is an
input to that same module call.

This is *not* circular, even though it looks at first glance like a module
input depending on that module's own output: Terraform's dependency graph is
resource-level, not module-opaque. `aws_vpc_endpoint.gwlb_endps` and
`aws_launch_template`/`aws_autoscaling_group` are independent sibling
resources inside the module with no dependency on each other directly — our
root-level indirection through `gwlb_endps` only adds one valid, acyclic
edge (launch template → endpoint), never the reverse. Confirmed by
`terraform validate`/`terraform plan` succeeding with no cycle error, and by
directly walking the parsed `terraform graph` output to confirm the edge
exists. Holds on a true from-scratch `apply`, not just against
already-existing infrastructure — the edge is structural, not a property of
current state.

**Caveat, not unique to Mode B:** if a distributed VPC's endpoint is ever
*replaced* after initial deploy (e.g. a CIDR change forces recreation, new
vpce-id), already-running FortiGate instances will not pick up the new
`endpoint-id` automatically — only new instances launching after the launch
template is updated get it. This is the same characteristic Mode A already
has today (e.g. a `spoke_cidrs` change doesn't retroactively update
already-booted instances either); it isn't something Mode B introduces.

## Next steps (blocked)

1. Wait for `endpoint-id` (or equivalent) to ship in a non-STS FortiOS
   build.
2. Decide flat vs. VRF approach for the real implementation — VRF is the
   current default (`distributed_egress_routing_mode = "vrf"`) given the
   analysis above, but hasn't been pressure-tested beyond this one
   comparison pass.
3. ~~Templatize into `terraform/autoscale_template`'s `.cfg.tftpl` files~~ —
   done, see [Status](#status) and
   [Terraform Implementation Notes](#terraform-implementation-notes) above.
4. Only once `endpoint-id` ships generally: update
   `content/5_Templates/5_6_Distributed_Egress/_index.md` and
   `content/5_Templates/_index.md` to mention overlapping CIDRs as a
   generally-available option — they currently intentionally still frame
   it as experimental/STS-only, matching
   `content/5_Templates/5_7_Overlapping_CIDR_Egress/_index.md`.
