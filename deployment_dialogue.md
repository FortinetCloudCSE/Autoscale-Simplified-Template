# FortiGate Autoscale Simplified Template — Deployment Wizard

**Audience for this file: Claude.** A customer has asked you to walk them through
configuring and deploying this repo's two Terraform templates. Follow the phases
below as an interactive dialogue — ask one group of questions at a time, explain
the tradeoffs in plain language, recommend a default when one exists, and link the
published docs so the customer can read more if they want. Do not dump the whole
wizard on them at once.

The customer may be non-technical or new to Terraform/AWS. Assume they can copy
commands and read a browser, but don't assume they know what a CIDR, TGW, or GWLB
is until you've explained it once.

**Shape of the wizard**: architecture/solution-component decisions first
(Phase 1 — the "what kind of deployment is this" questions), *then* the
fill-in-the-blank specifics (Phases 2–3 — CIDRs, keypairs, names, exact
numbers). Answering the architecture questions first means the specifics phases
never have to ask "wait, do you even want this component" mid-stream — by the
time you get there, every yes/no decision has already been made.

**Docs site**: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/
Every section below has a specific page linked — prefer linking the specific page
over the site root.

**Before starting, scan the local `content/` directory** (the Hugo source for
the docs site — `content/**/_index.md`) rather than relying only on this file's
summaries or fetching the live site. It's faster, always in sync with the code
in this checkout, and lets you catch anything this playbook doesn't cover yet
or any further docs/code drift beyond what's noted below.

---

## Ground rules (read before starting)

1. **variables.tf is the source of truth, not the prose docs.** The published docs
   occasionally drift from the actual Terraform (e.g. the docs mention a `my_ip`
   variable that doesn't exist — the real variable is `management_cidr_sg` in
   `existing_vpc_resources` and `vpc_cidr_sg` in `autoscale_template`; the docs also
   describe an `enable_debug_tgw_attachment` flag, per-spoke
   `enable_east_linux_instances`/`enable_west_linux_instances` flags, and
   `dedicated_management_vpc_tag`-style variables that don't exist in the current
   `variables.tf`). Before you tell the customer a variable name, grep
   `terraform/existing_vpc_resources/variables.tf` or
   `terraform/autoscale_template/variables.tf` to confirm it's real. Use the docs
   for *concepts and links*, not for the literal variable list.
2. **Never silently overwrite an existing `terraform.tfvars`.** If
   `terraform/existing_vpc_resources/terraform.tfvars` or
   `terraform/autoscale_template/terraform.tfvars` already exists, tell the customer
   and ask whether to overwrite it, back it up first, or write to a different
   filename (`terraform.tfvars.new`, etc.). `terraform.tfvars` and
   `terraform.tfvars.mdw` are both gitignored in this repo, so nothing you write to
   either one gets committed automatically — but that doesn't mean it's safe to
   clobber someone's working config without asking.
3. **`cp` and `env` must match exactly between both templates.** This is the single
   most common failure mode (`autoscale_template` fails with "no matching VPC
   found"). Once the customer picks these, reuse them verbatim everywhere else —
   don't ask again.
4. **Passwords and credentials**: never print a password back in full once set,
   and remind the customer these values land in a local `.tfvars` file that should
   never be committed to git (it isn't, by default — `.gitignore` excludes
   `terraform.tfvars`).
5. Prefer asking one grouped set of related questions at a time rather than one
   variable per message. Use multiple-choice prompts for anything with a fixed
   set of options (yes/no flags, `1-arm` vs `2-arm`, licensing model) and free
   text for values like CIDRs, names, and passwords.
6. At the end of each template's specifics phase, show the customer the full
   `terraform.tfvars` content you're about to write and get explicit confirmation
   before writing it.
7. **Standing rule — always append `vpc_cidr_management` to the management
   security-group CIDR list** (`management_cidr_sg` in `existing_vpc_resources`,
   `vpc_cidr_sg` in `autoscale_template`), on top of whatever external/admin IPs
   the customer gives — **even if they didn't ask for it.** External IPs alone
   only cover access from outside the VPC; management-plane traffic *inside* the
   VPC (jump box → FortiManager, FortiManager → FortiGate over the management
   ENI) flows through this same security group and needs the VPC's own CIDR
   allowed too, or internal management connectivity breaks. **Tell the customer
   you're doing this and why**, and give them the explicit option to remove it if
   they'd rather lock things down further.
8. **Before telling the customer a `terraform.tfvars` file is complete, run
   `terraform init` + `terraform plan` against it if you have AWS credentials
   available** (or at minimum `terraform validate`, which needs no credentials).
   This playbook's per-variable lists have already been wrong more than once —
   variables assumed "only required if some flag is enabled" that were actually
   unconditionally required by `variables.tf`. `terraform plan` catches every
   missing-required-variable error in one pass; don't rely solely on this
   document's memory of which variables need placeholders.
9. **`terraform plan` doesn't catch everything — some errors only surface at
   `terraform apply`.** Verified directly: a keypair name that doesn't exist in
   the target region passes `plan` fine (nothing in the config validates it
   against AWS) and only fails at `apply` with `InvalidKeyPair.NotFound`, by
   which point other resources may already be created. If credentials are
   available, proactively verify anything `plan` can't check — keypair
   existence (`aws ec2 describe-key-pairs`), AMI versions actually being
   published (Phase 2/3 notes below), license files actually existing on disk
   — rather than waiting for `apply` to discover it the hard way.
10. **When actually running `terraform`/`aws` commands yourself (not just
    telling the customer what to run), always `cd` with the full absolute
    path immediately before each command — don't rely on a previously-set
    working directory persisting.** Verified repeatedly: background command
    execution does not carry directory changes forward to subsequent commands
    in the same session, and re-running a command from the wrong directory
    (e.g. the repo root, which has stray reference `.tf` files) produces
    confusing "Unsupported argument" errors that look like a tfvars problem
    but aren't.
11. **A clean `terraform plan` is necessary but not sufficient — verify with a
    real `terraform apply` when you can.** Several real bugs in this repo only
    ever showed up at `apply` time or later: a keypair that doesn't exist
    (#9), FortiManager/FortiAnalyzer AMI versions that resolve at `plan` time
    but the instance itself fails to launch, and a tag-reconciliation bug
    (fixed via `ignore_tags` in `provider.tf` as of this writing — see
    Phase 2's Security-adjacent note) that silently deleted
    `Fortinet-Role` tags on the *second* apply even though the first apply and
    every `plan` looked completely clean. If you have credentials and the
    customer wants to actually deploy (not just generate the tfvars files),
    don't stop at a clean `plan` and call it done.
12. **Never assume the customer wants to reuse a previous run's values as a
    shortcut — not even when reconfiguring from scratch after an existing
    `terraform.tfvars` you already have on disk.** Corrected directly by the
    customer: presenting old values as an implicit default (e.g. "same as
    before?") skips the point of walking through the phase at all. Ask every
    question explicitly and let the customer supply each value themselves,
    even if it turns out identical to what came before.
13. **When writing the final `terraform.tfvars`, start from
    `terraform.tfvars.example` (copy it, checking Ground Rule 2 first) and
    edit only the specific variable values decided in the dialogue — never
    hand-assemble a bare-bones tfvars containing just the discussed
    variables.** Corrected directly by the customer. The example file's
    comments, section headers, `USE CASE` examples, and `IMPORTANT NOTES`
    aren't just scaffolding to discard once you have the values — they're
    what the customer (or whoever tweaks this file later, possibly without
    you in the loop) uses to understand what every other variable does and
    how to safely change it themselves. A minimal rewritten file loses all of
    that context permanently. Practically: `cp terraform.tfvars.example
    terraform.tfvars`, then apply the dialogue's answers as targeted edits to
    that copy, leaving every comment, every unrelated variable, and the
    file's original structure intact.

---

## Phase 0 — Orient

Start by explaining, briefly, the two-template architecture:

> This deployment uses two Terraform templates that run in order:
> 1. **existing_vpc_resources** — builds the Inspection VPC (and optionally a
>    Management VPC, Transit Gateway, and test spoke VPCs), tagging everything
>    with `Fortinet-Role` tags.
> 2. **autoscale_template** — deploys the FortiGate autoscale group *into* the
>    Inspection VPC, finding it via those tags.
>
> Full architecture overview: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_1_overview/

Then ask:

- **Do you already have VPCs tagged with `Fortinet-Role`?**
  - Yes → Skip Phase 2 entirely (still do Phase 1 for the `autoscale_template`-
    relevant decisions, then go straight to Phase 3). Warn the customer they're
    responsible for manually tagging all required resources per the
    [Required Fortinet-Role Tags](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_1_overview/#required-fortinet-role-tags)
    table before `autoscale_template` will find anything.
  - No → continue, both Phase 2 and Phase 3 run.
- **What's the Transit Gateway situation: none, a brand-new demo TGW, or an
  existing production TGW?** This is the main cost/complexity lever
  ([full cost breakdown](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_2_existing_vpc_resources/#component-overview)),
  and it's easy to steer a real customer toward the wrong option here if you
  don't explain what `enable_build_existing_subnets` actually does — it does
  **not** mean "attach to my existing TGW." It means "build a brand-new TGW
  plus synthetic East/West spoke VPCs with Linux traffic-generator instances"
  — this is a Fortinet demo/lab construct for generating test traffic and
  exercising east-west inspection in a self-contained sandbox, not something a
  real customer's production TGW setup normally wants. **A real customer
  almost always already has an existing TGW with real workload VPCs attached
  to it, and what they actually want is to attach the Inspection VPC to that
  existing TGW** — which is `enable_build_existing_subnets = false` +
  `enable_tgw_attachment = true` + `attach_to_tgw_name` set to their real TGW's
  name, not the demo-spokes path. Lay out all three options plainly:
  - **No TGW** — just the core Inspection VPC, cheapest/fastest path, no
    east-west inspection between other VPCs.
  - **Build a new demo TGW + East/West spoke VPCs** (`enable_build_existing_subnets
    = true`) — for lab/demo/POC use, generates its own synthetic test traffic.
    Adds ~$100–150/month. Don't recommend this to a customer describing a real
    production network unless they specifically want a sandboxed demo alongside it.
  - **Attach to an existing TGW** (`enable_build_existing_subnets = false`,
    `enable_tgw_attachment = true`, `attach_to_tgw_name` = their real TGW's
    name) — the customer's actual workload VPCs are already attached to that
    TGW; this just adds the Inspection VPC as another attachment so it can
    inspect east-west traffic between the customer's existing VPCs.

Everything else that used to be bundled into a single "pick a pattern" choice
(management VPC, FortiManager, licensing, egress mode, etc.) is now asked
explicitly, one decision at a time, in Phase 1 below — so don't ask about those
here.

---

## Phase 1 — Architecture & Solution Options

This phase makes every yes/no/which-one architecture decision **before**
touching a single CIDR or keypair. Ask in this order — it's the order where
each answer only ever depends on answers already given, never on ones still
to come.

**For every sub-section below, follow this shape:**
1. **Explain the concept in 2–3 plain-language sentences** — what it is, why
   it matters, what breaks if you pick wrong. Don't assume the customer knows
   what a GWLB, VDOM, or scale-in event is.
2. **Link the specific doc page** for that topic (each sub-section has one
   below) — tell them it has more detail/diagrams if they want to read
   further, don't just drop the link with no framing.
3. **State the tradeoff** between the options in one line each, with a
   recommendation and *why* (cost, complexity, production-readiness).
4. **Then ask the question.**

Don't skip straight to the question — a skill-limited customer needs the
"why" before the "which one," not after.

### 1. Licensing

Explain up front: FortiGate instances need a license to run at full
throughput and get FortiGuard security updates. This template supports three
licensing mechanisms, and the `asg_byol_asg_*` autoscale group needs exactly
**one** of them — perpetual license files and FortiFlex are alternative ways
of licensing that *same* group and are **mutually exclusive**. Never configure
both `asg_license_directory` and the `fortiflex_*` variables together.

Full comparison with cost tradeoffs: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/4_solution_components/4_4_licensing_options/

Ask in this order:

1. **"Do you want to license FortiGates yourself (BYOL/FortiFlex), or run
   entirely on AWS Marketplace pay-as-you-go (PAYG)?"**
   - **PAYG-only** → skip straight to question 3, `asg_byol_asg_max_size = 0`.
   - **BYOL/FortiFlex** → continue to question 2.
2. **"Perpetual license files (traditional BYOL `.lic` files), or FortiFlex
   (API-driven, usage-based licensing)?"**
   - **Perpetual files** → set `asg_license_directory` (default
     `"asg_license"`). Ask how many `.lic` files the customer actually has
     available (or will have) — that count becomes the basis for
     `asg_byol_asg_max_size` in question 4, not just a tier picked off a table.
     Remind them to create the directory and drop the files in it before
     `terraform apply`. Do not ask about FortiFlex.
   - **FortiFlex** → collect credentials **now**: `fortiflex_username`,
     `fortiflex_password`, `fortiflex_configid_list` (config ID(s) from the
     FortiFlex portal), and `fortiflex_sn_list` (optional — restricts to
     specific program serial numbers). **Don't infer the required vCPU count
     from the config ID's name** — corrected directly by the customer. A name
     like `Standard_Autoscale_FGT_4vcpu` is just a human-chosen label; nothing
     about the string itself is enforced by FortiFlex or this template. The
     actual vCPU requirement lives in that config ID's real definition in the
     FortiFlex portal, which you can't see from the name alone — ask the
     customer to confirm it directly (or check the portal) rather than
     assuming the name is accurate, when picking `fgt_instance_type` in Phase 3.
     Point to the
     [FortiFlex setup guide](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/4_solution_components/4_4_licensing_options/4_4_1_fortiflex_setup/).
     Ask whether these go directly in the tfvars file or as
     `TF_VAR_fortiflex_username` / `TF_VAR_fortiflex_password` environment
     variables instead (keeps credentials out of the file) — never assume the
     file is fine, ask. **Then ask how many entitlements/serial numbers are
     actually provisioned/available** under that config ID (if `fortiflex_sn_list`
     was given explicitly, that count is the answer; otherwise ask directly) —
     that count becomes the basis for `asg_byol_asg_max_size` in question 4.
3. **"Hybrid scaling — burst beyond your licensed/PAYG-only capacity using
   on-demand Marketplace instances — or keep scaling limited strictly to one
   pool?"**
   - If they answered PAYG-only above, this question is really "PAYG only,
     no BYOL baseline at all" — confirm `asg_byol_asg_max_size = 0` and size
     `asg_ondemand_asg_*` as the sole pool.
   - **Hybrid** (licensed/FortiFlex baseline + Marketplace burst) → both pools
     get real capacity. Recommended production pattern. Remind them to accept
     the FortiGate-VM PAYG terms in AWS Marketplace *before* running
     `terraform apply`.
   - **Licensed-only** (no burst) → `asg_ondemand_asg_min_size = 0`,
     `asg_ondemand_asg_max_size = 0`, `asg_ondemand_asg_desired_size = 0`.
     Also skips the AWS Marketplace PAYG subscription requirement entirely —
     worth mentioning if the customer wants to avoid that step.
4. **Capacity** — for the licensed (BYOL/FortiFlex) pool, **default
   `asg_byol_asg_max_size` to the license/entitlement count from question 2**
   (not a generic tier) — you can't scale to more instances than you have
   licenses for anyway. Give the customer the explicit option to set it lower
   if they want headroom or aren't ready to use full capacity. For min/desired,
   offer two shapes:
   - **Active immediately** — `min`/`desired` > 0 so instances launch as soon
     as `terraform apply` runs. Use the tier table below as a starting point,
     capped at the license count.
   - **Deploy idle, scale manually when ready** — `asg_byol_asg_min_size = 0`,
     `asg_byol_asg_desired_size = 0`. This deploys the full autoscale
     infrastructure (Lambda, GWLB, DynamoDB, etc.) but launches **zero**
     FortiGate instances until the customer manually edits the ASG desired
     capacity — a clean way to stage everything and flip it on when ready.
     `max_size` still caps at the license count either way.

   Tier table for the "active immediately" shape
   ([source](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_3_autoscale_template/#step-9-configure-autoscale-group-capacity)),
   remembering `max` is capped at the license count regardless of tier:

   | Profile | min | max | desired |
   |---|---|---|---|
   | Dev/Test | 1 | 2 | 1 |
   | Small Production | 2 | 4 | 2 |
   | Medium Production | 2 | 8 | 4 |
   | Large Production | 4 | 16 | 6 |

   If using on-demand/PAYG capacity (hybrid, question 3), size
   `asg_ondemand_asg_*` separately — it isn't license-constrained the same way,
   size it for expected burst traffic instead.

### 2. Internet Egress

Explain first: FortiGates need internet access — for FortiGuard updates, and
(if this VPC handles outbound customer traffic) for the traffic itself. There
are two ways to give it that access, and they cost and behave differently.
Doc: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/4_solution_components/4_1_internet_egress/

**"NAT Gateway or per-instance Elastic IP for internet access?"**

- **NAT Gateway** — predictable single egress IP, ~$33/month per AZ. Better
  when downstream systems need to allowlist a fixed source IP.
- **EIP** (recommended for lab/test) — cheaper, simpler, no NAT Gateway. Each
  FortiGate gets its own public IP instead of sharing one.

Sets `create_nat_gateway_subnets` (existing_vpc_resources) and
`access_internet_mode` (autoscale_template) — these two variables must always
match (`true`↔`"nat_gw"`, `false`↔`"eip"`), remember the mapping, don't ask
twice.

### 3. Firewall Architecture

Explain first: this decides how traffic flows through each FortiGate's
network interfaces — one shared interface for both incoming and outgoing
traffic, or two separate ones. It affects routing complexity and throughput,
not security posture. Doc: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/4_solution_components/4_2_firewall_architecture/

**"Single-interface (1-arm) or dual-interface (2-arm) firewall policy mode?"**

- **1-arm** — single interface for data plane (hairpin routing). Simpler to
  reason about, fine for lab/test.
- **2-arm** (recommended for production) — separate trust/untrust interfaces,
  better throughput, the traditional firewall model.

Sets `firewall_policy_mode` in `autoscale_template`.

### 4. Management Isolation

Explain first: this decides whether FortiGate/FortiManager/FortiAnalyzer
management traffic (GUI, SSH, config sync) shares the same network path as
customer data traffic, or gets its own isolated path. Isolation matters more
as you get closer to production. Doc: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/4_solution_components/4_3_management_isolation/

**This is genuinely two independent questions, not one three-way choice —
verified end-to-end by actually deploying and hitting the failure mode of
treating it as one.** The docs present it as three mutually exclusive options,
but the underlying variables don't actually couple that way:

**Question A: build a separate Management VPC to host FortiManager/
FortiAnalyzer/jump box at all?** → `enable_build_management_vpc`
(existing_vpc_resources). Independent of everything below — you can build this
VPC and reach FortiManager/FortiAnalyzer/jump box by their **public IPs**
regardless of how (or whether) the FortiGate's own management traffic is
isolated.

**Question B: does the FortiGate get a dedicated management interface, and
does it reach the separate Management VPC's *private* IPs?** →
`enable_dedicated_management_eni` / `enable_dedicated_management_vpc`
(autoscale_template) plus `create_management_subnet_in_inspection_vpc`
(existing_vpc_resources). Three sub-options:
- **No dedicated ENI** — FortiGate management traffic shares the data-plane
  interface. `enable_dedicated_management_eni = false`,
  `enable_dedicated_management_vpc = false`,
  `create_management_subnet_in_inspection_vpc = false`. Works regardless of
  Question A / TGW — this is the only fully safe choice when there's no TGW.
- **Dedicated ENI, isolated to the Inspection VPC only** — FortiGate gets a
  second ENI/subnet for management traffic, but it doesn't reach the separate
  Management VPC (no route). `create_management_subnet_in_inspection_vpc =
  true`, `enable_dedicated_management_eni = true`,
  `enable_dedicated_management_vpc = false`. This is the only sub-option that
  actually uses the Inspection VPC's own dedicated management subnet
  (`{cp}-{env}-inspection-management-az{N}`) — verified: `autoscale_template`'s
  lookups for that subnet and its route table (`vpc_inspection.tf` lines
  142-157, 228-243) are gated on `enable_dedicated_management_eni`, not
  `enable_dedicated_management_vpc`. If `existing_vpc_resources` didn't
  actually set `create_management_subnet_in_inspection_vpc = true`, those
  lookups find nothing and `terraform plan` fails with `Missing required
  argument: route_table_id` — a mismatch between the two templates' settings,
  not a TGW issue.
- **Dedicated ENI reaching the separate Management VPC** —
  `enable_dedicated_management_vpc = true` (mutually exclusive with
  `enable_dedicated_management_eni` — a `check` block hard-fails `plan` if
  both are `true`, so leave `enable_dedicated_management_eni = false`
  explicitly). **Corrected — verified the hard way, `create_management_subnet_in_inspection_vpc`
  must be `false` here, not `true`.** This option never touches the
  Inspection VPC's own dedicated management subnet at all: it uses AWS's
  multi-VPC ENI attachment feature to attach the FortiGate's second interface
  directly to the *Management VPC's own* public subnet instead
  (`autoscale_group.tf` lines 243, 247, 309, 313 pull
  `data.aws_subnet.public_subnet_az1/az2`, not the inspection-management
  subnets, whenever `enable_dedicated_management_vpc = true`). Setting
  `create_management_subnet_in_inspection_vpc = true` here just creates a
  wasted, unused subnet in the Inspection VPC.
  **Also corrected — does not require a TGW**, contrary to what this file
  previously said: checked every resource gated by
  `enable_dedicated_management_vpc` in `autoscale_template` (`autoscale_group.tf`,
  `vpc_inspection.tf`) and none of them reference TGW, TGW attachments, or
  any routed connectivity — they only look up the Management VPC's own public
  subnets/IGW. The multi-VPC ENI attachment is a direct interface attachment,
  not IP-routed connectivity, so it needs no TGW and no VPC peering. Safe to
  offer this sub-option regardless of Phase 0's TGW answer.

**Practical guidance**: since "Dedicated ENI reaching Management VPC" doesn't
require a TGW (see above), Phase 0's TGW answer doesn't constrain Question B
at all — all three sub-options are always available regardless. The customer
only ends up on "no dedicated ENI" if they actually choose it, or if Question
A was "no" (no Management VPC built at all, nothing to reach). If Question B
picked "reaching Management VPC," FortiManager integration (Section 6 below)
can use FortiManager's **private** IP — the multi-VPC ENI attachment gives
the FortiGate a real interface directly in the Management VPC regardless of
TGW.

**Question C: if Question B chose either dedicated-ENI sub-option, does the
FortiGate's dedicated management port itself get a public IP?** →
`enable_fgt_management_public_ip` (`autoscale_template`, default `true`).
Default assumption is yes (internet access to that port), unless the customer
has Direct Connect/VPN giving a private path to it — same logic as Section 5's
public-IP sub-questions below, just for the FortiGate's own management port
instead of FortiManager/FortiAnalyzer/jump box.

**Doc/code drift**: the published docs show `dedicated_management_vpc_tag`,
`dedicated_management_public_az1_subnet_tag`, and
`dedicated_management_public_az2_subnet_tag` variables for pointing
`autoscale_template` at a custom-tagged management VPC. **These don't exist in
`variables.tf`.** The actual implementation always discovers the management
VPC via `Fortinet-Role` tags computed from `cp`/`env` — there's nothing to ask
or set here. Don't offer these variables to the customer.

### 5. FortiManager / FortiAnalyzer / Jump Box

**Only ask if Section 4 Question A was "yes" (building a Management VPC).**
Otherwise skip this section entirely (`enable_fortimanager = false`,
`enable_fortianalyzer = false`, `enable_jump_box = false`) — no need to
explain these to a customer who can't use them. Note this is independent of
Question B / TGW — these instances get deployed and are reachable by public IP
either way.

Explain briefly: these are three optional instances that live in the
Management VPC. None are required for the FortiGates themselves to work —
they add centralized management, logging, and access convenience on top.

- **FortiManager** — centralized policy management/orchestration across all
  FortiGates in the group, instead of configuring each one by hand.
- **FortiAnalyzer** — centralized logging/reporting/analytics.
- **Jump box** — a small bastion host for SSH access to private resources
  (useful for reaching spoke Linux instances or FortiGate private IPs without
  exposing them directly).

Ask which of the three the customer wants (independent yes/no each) — sets
`enable_fortimanager`, `enable_fortianalyzer`, `enable_jump_box` in
`existing_vpc_resources`. (Instance sizes, versions, passwords, and license
files for whichever ones are enabled get collected in Phase 2 — this section is
just the yes/no.)

**Fold the public-IP decision into each component's yes/no, right here — don't
defer it to a separate batched question in Phase 2 Section 5a.** For each of
FortiManager/FortiAnalyzer/jump box the customer enables, immediately ask
whether *that one* gets a public IP: default assumption is yes (internet
access), unless the customer has Direct Connect/VPN reaching it privately, in
which case recommend `false` — same reasoning as Question C above, just
per-component instead of templatewide. This sets
`enable_fortimanager_public_ip` / `enable_fortianalyzer_public_ip` /
`enable_jump_box_public_ip` right away; Phase 2 Section 5a just writes the
values already decided here, it doesn't ask again.

**Historical bug, now fixed — kept here as context in case it regresses.**
`vpc_management.tf` intentionally builds its own custom jump box
(`aws_instance.jump_box` + custom NAT-enabling userdata + custom security
group — see the `# Jump Box - Created directly instead of via module for
custom configuration` comment) rather than using the child
`aws_management_vpc` module's generic one, and correctly hardcodes
`enable_jump_box = false` in the module call to avoid creating a duplicate
instance. The bug was that the module also only creates the management VPC's
*private subnets/route tables* when it sees `enable_jump_box=true` (which we
correctly don't pass) OR `enable_tgw_attachment=true` for the management VPC —
and the root module's `aws_route.private-az1/az2/az3-default-to-jump-box`
resources (which route spoke-VPC traffic through the jump box's NAT, per their
own comment) unconditionally assumed those private subnets exist whenever
`enable_jump_box=true`, regardless of whether the management VPC actually has
a TGW attachment. Since those routes only matter for spoke traffic reaching
the jump box *via TGW* in the first place, the fix was to gate them on
`enable_management_tgw_attachment` too — not to touch the (correct,
intentional) jump box implementation itself. If `terraform plan` errors with
`Missing required argument: route_table_id` on those resources again, check
this gating hasn't regressed before assuming jump box is broken again.

### 6. FortiManager Integration (autoscale_template)

**Only ask if FortiManager was enabled in Section 5.**

Explain first: enabling FortiManager in Section 5 only deploys the instance —
it doesn't automatically connect the FortiGates to it. This section decides
whether the FortiGate autoscale group actually registers itself with that
FortiManager for centralized policy push.
Doc: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/4_solution_components/4_5_fortimanager_integration/

**"Should FortiGates register with FortiManager for centralized policy
management?"** If yes, sets `enable_fortimanager_integration = true` in
`autoscale_template` (the IP/serial number get collected in Phase 3, since the
serial number isn't known until FortiManager is actually deployed). Warn:
FortiManager 7.6.3+ requires `set fgfm-allow-vm enable` under
`config system global` on the FortiManager CLI before FortiGates can register.

**Which IP for `fortimanager_ip` depends directly on Section 4's answer**:
if Question B ended up "no dedicated ENI" (or Question A was "no", no
Management VPC at all), use FortiManager's **public** IP — the FortiGate has
no private path to `10.3.0.x`. Use the private IP (`vpc_cidr_management` base
+ `fortimanager_host_ip`) if Question B's third sub-option (dedicated ENI
reaching the Management VPC via multi-VPC ENI attachment — no TGW required,
see Section 4) was selected. Get this wrong and `terraform apply` succeeds
but the FortiGates simply can never reach FortiManager — no error, just
silent non-functionality, so get it right rather than defaulting to the
private IP out of habit.

### 7. Primary Scale-In Protection

Explain briefly: during a scale-in event, the autoscale group can terminate
any instance to reduce capacity — including the "primary" FortiGate that
holds the master HA config. This setting protects the primary from ever being
picked for termination, so the group doesn't lose its config source of truth
mid-scale-down.

Quick default confirm, not really a decision point:
`primary_scalein_protection = true` — protects the primary instance from
being terminated during scale-in. Recommended, essentially always left on.
Keep it, or turn off?

---

## Phase 2 — `existing_vpc_resources/terraform.tfvars` specifics

Skip this phase if the customer said (Phase 0) they already have tagged VPCs.
Every yes/no architecture decision is already made by this point — this phase
is purely filling in names, numbers, and CIDRs.

Doc for this whole phase:
https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_2_existing_vpc_resources/

### 1. Region and Availability Zones

Ask for `aws_region` (e.g. `us-east-1`) and two AZ letters, `availability_zone_1`
/ `availability_zone_2` (e.g. `a`, `b`). Mention they can confirm AZ availability
in their target region with `aws ec2 describe-availability-zones --region <region>`.
There's also an `availability_zone_3` for 3-AZ deployments — default it to `""`
unless the customer specifically wants 3 AZs (see the
[Three AZ Deployment guide](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_4_three_az_deployment/)
if they do).

### 2. Customer prefix and environment (`cp` / `env`)

Explain these get prepended to every resource name and `Fortinet-Role` tag
(`{cp}-{env}-inspection-vpc`, etc.). Ask for both. **Save these values — they
get reused verbatim in Phase 3.**

### 3. Security

- `keypair` — an AWS EC2 keypair name that must already exist in the target
  region. **Verify it, don't just take the customer's word for it** — a typo'd
  or misremembered keypair name (verified the hard way: `terraform apply` got
  most of the way through creating real, billable infrastructure before
  failing with `InvalidKeyPair.NotFound` on the last resources) doesn't
  surface until `terraform apply`, by which point other resources may already
  be created. If you have AWS credentials available, run
  `aws ec2 describe-key-pairs --region <region> --query 'KeyPairs[].KeyName'`
  yourself and confirm the name the customer gave you is actually in the list
  before writing it into the tfvars file, rather than just suggesting they
  check.

**Historical bug, now fixed in `provider.tf` — no action needed by the wizard,
kept here so you recognize the symptom if it ever regresses (e.g. on a repo
checkout predating this fix).** `existing_vpc_resources` manages its
`Fortinet-Role` tags via standalone `aws_ec2_tag` resources, separate from
each resource's own `tags` argument. Verified via CloudTrail: without an
`ignore_tags` block in the provider config, any later `terraform apply` that
touches one of those tagged resources (even for something unrelated, like a
provider version adding a new computed attribute) causes the AWS provider to
reconcile that resource's live tags against what it computes from its own
`tags` argument alone — and since it doesn't know about the out-of-band
`Fortinet-Role` tag, it deletes it. Symptom: a `terraform plan` for
`existing_vpc_resources` looks completely clean (`No changes` or only
unrelated changes) right after a successful `apply`, but `autoscale_template`
still fails resource discovery with "no matching VPC/Subnet/Route Table
found" — because the tags were silently stripped on a *later* apply, not
because anything is wrong with `autoscale_template`'s config. If you ever see
that combination, check `provider.tf` for `ignore_tags { keys =
["Fortinet-Role"] }` before assuming the tfvars are wrong.

- `management_cidr_sg` — list of CIDRs allowed to reach management interfaces
  (FortiManager/FortiAnalyzer/jump box). Default suggestion: their current public
  IP as a /32 (`curl ifconfig.me`).
  **Always ask if they have a VPN/SASE tunnel** — if so, their public IP differs
  depending on whether it's up or down, and they need access in both states.
  Grab it once with the tunnel up and once with it down (`curl ifconfig.me`
  each time, prompting them to toggle in between), and add both to the list.
  **The only CIDR this wizard auto-appends to this list is `vpc_cidr_management`
  itself, per Ground Rule 7, once that value is known in the next step — never
  proactively suggest adding the inspection VPC CIDR, spoke CIDRs, or any other
  VPC's CIDR here.** Those aren't what this security group is for.
  **Always end with one explicit followup question**: "Any other CIDRs to add
  that I can't detect myself?" — prompt with concrete examples rather than
  asking blind, since the customer may not think to mention these unprompted:
  additional public IP ranges for an on-prem FortiAnalyzer/FortiManager that
  also needs to reach these management interfaces, or private CIDRs if
  management access happens exclusively over Direct Connect. Don't skip this
  just because you already have their current public IP(s).
  **Public IP exposure for FortiManager/FortiAnalyzer/jump box is a separate
  question, folded into each component's yes/no in Phase 1 Section 5** — don't
  raise it here, this section is CIDRs only.
  **Reassure the customer this list isn't set in stone**: `management_cidr_sg`
  becomes a security group rule set, which can be edited directly in the AWS
  Console (EC2 > Security Groups) after the fact if they need to add a CIDR
  later — they don't have to get it perfectly complete right now, and don't
  need a `terraform apply` just to add one more allowed IP.

### 4. Network CIDRs

Explain the CIDR plan needs non-overlapping ranges for: management VPC,
inspection VPC, and the spoke supernet.

**Present the suggested defaults up front as a table, don't just ask the
customer to supply every value cold** — most lab/test deployments take the
defaults as-is, and making them ask "what's the default?" separately wastes a
turn:

| Variable | Suggested default |
|---|---|
| `vpc_cidr_management` | `10.3.0.0/16` (only needed if building a management VPC) |
| `vpc_cidr_inspection` | `10.0.0.0/16` |
| `vpc_cidr_east` | `192.168.0.0/24` (only needed if deploying spoke VPCs, Phase 0) |
| `vpc_cidr_west` | `192.168.1.0/24` (only needed if deploying spoke VPCs, Phase 0) |
| `subnet_bits` | `8` |
| `spoke_subnet_bits` | `4` |

**Fixed since this was last a footgun**: `existing_vpc_resources` used to
declare *both* `vpc_cidr_inspection` (dead, unused) and `vpc_cidr_ns_inspection`
(the one that actually built the VPC) — `autoscale_template`'s
`vpc_cidr_inspection` had to match the *latter*, not the similarly-named
former. `vpc_cidr_ns_inspection` has been removed entirely; both templates now
use `vpc_cidr_inspection` for the same thing, with the same name, so there's
nothing left to mix up. Likewise, `vpc_cidr_spoke` (a "supernet" variable that
was supposed to contain `vpc_cidr_east`/`vpc_cidr_west` but was never actually
validated against them) has also been removed — see `spoke_cidrs` in
`autoscale_template` if you need the FortiGate's east-west inspection route to
cover more than just the two demo spoke VPCs; it defaults to
`[vpc_cidr_east, vpc_cidr_west]` with no supernet math required.
`subnet_bits`/`spoke_subnet_bits` control how big the subnets are within each
VPC's CIDR.

Then ask: use these defaults as-is, or adjust any of them?

Now apply Ground Rule 7: append `vpc_cidr_management` to `management_cidr_sg`
from Section 3, tell the customer you're doing it and why, offer to remove it.

### 5. Component flags (from Phase 1 answers)

Translate Phase 1 answers directly — no new decisions here, just confirm:

- `enable_build_inspection_vpc = true` (always)
- `enable_build_management_vpc`, `create_management_subnet_in_inspection_vpc`
  — from Phase 1 Section 4 (Management Isolation)
- `create_nat_gateway_subnets` — from Phase 1 Section 2 (Internet Egress)
- `enable_fortimanager`, `enable_fortianalyzer`, `enable_jump_box` — from
  Phase 1 Section 5
- `enable_build_existing_subnets`, `enable_linux_spoke_instances` — from
  Phase 0 (TGW + spoke VPCs decision)

If FortiManager/FortiAnalyzer are enabled: **before asking about their
licensing, check whether license files already exist** — look in
`terraform/existing_vpc_resources/licenses/` (and check the repo for any other
`*.lic` files, e.g. `find . -iname '*.lic'`) for something like
`fmgr_license.lic` / `faz_license.lic`. If files are already sitting there,
surface that to the customer directly ("I found a FortiManager/FortiAnalyzer
license file already in the repo — want to use it?") instead of asking the
perpetual-vs-PAYG question cold and letting them default to PAYG without
knowing a license was available. This is a separate license decision from the
FortiGate ASG license (Phase 1 Section 1) — FortiManager and FortiAnalyzer
license themselves independently.

Then ask for instance type (default `m5.large` for lab/test), OS version, host
IP octet (defaults `fortimanager_host_ip = 10`, `fortianalyzer_host_ip = 11`
within `vpc_cidr_management`), and an admin password (min 8 characters —
required, or they can't log in).

**IP collision, verified the hard way (`terraform apply` failed with
`InvalidIPAddress.InUse`)**: if `enable_jump_box = true`, its private IP is
also computed within the *same* management VPC subnet (`linux_host_ip`,
Section 5a below) — the docs' own suggested defaults for
`fortianalyzer_host_ip` (`11`) and `linux_host_ip` (`11`) are identical and
collide. Whenever both FortiAnalyzer and the jump box are enabled together
(or any combination of FortiManager/FortiAnalyzer/jump box), assign them
**distinct** host IPs before writing the tfvars file — don't apply each
component's doc-suggested default independently without checking the others.
A safe convention: FortiManager `10`, FortiAnalyzer `11`, jump box `12`.

**Same AMI-freshness caveat as Phase 3
Section 3's `fortios_version`** — don't default to a doc example version
without checking it's still published:
```bash
aws ec2 describe-images --owners 679593333241 \
  --filters "Name=name,Values=FortiManager*VM64-AWS*GA*" \
  --query 'sort_by(Images, &CreationDate)[].Name' --output text
# swap FortiManager for FortiAnalyzer in the filter for that one
```
FortiManager, FortiAnalyzer, and FortiGate version catalogs are independent —
don't assume a version available for one is available for the others; pick
one present in all three if you want them aligned.

**These three TGW-related questions are important enough to ask individually,
each with a full explanation — don't batch them into one grouped question:**

**1. `attach_to_tgw_name`** — this is the `Name` tag applied to the Transit
Gateway `existing_vpc_resources` creates. It matters beyond cosmetics:
`autoscale_template` (Phase 3) uses this exact name to *discover* which TGW to
attach the FortiGate autoscale group to. If the names don't match
byte-for-byte between the two templates, `autoscale_template` either fails to
find the TGW or attaches to the wrong one if multiple TGWs share similar names
in the account. Default convention: `{cp}-{env}-tgw` (this repo auto-creates a
TGW with that name when `enable_build_existing_subnets = true`). Only deviate
from this if attaching to an **existing** production TGW instead — in that
case use its actual `Name` tag (`aws ec2 describe-transit-gateways --query
'TransitGateways[*].[Tags[?Key==`Name`].Value|[0],TransitGatewayId]'` finds
it), and `existing_vpc_resources` won't be the one creating it.

### 5a. Public IPs and spoke instance settings

These have **no default in `variables.tf`** — they're required whenever the
component they belong to is enabled, easy to miss, and not covered elsewhere in
this playbook. Don't skip them:

- `enable_fortimanager_public_ip`, `enable_fortianalyzer_public_ip`,
  `enable_jump_box_public_ip` — **already decided in Phase 1 Section 5**,
  folded into each component's yes/no question at the point it was asked.
  Just write the values here, don't ask again.
- `linux_instance_type` and `linux_host_ip` are needed whenever **either**
  `enable_linux_spoke_instances = true` **or** `enable_jump_box = true`, not
  just spoke instances — the jump box uses the same two variables
  (`linux_host_ip` becomes its private IP within `vpc_cidr_management`, via
  `cidrhost(cidrsubnet(vpc_cidr_management, subnet_bits, 0), linux_host_ip)`).
  **If jump box is enabled, pick `linux_host_ip` to avoid colliding with
  `fortimanager_host_ip`/`fortianalyzer_host_ip`** — see the collision note in
  Section 5 above. `acl` (`"public"` for internet-reachable spoke test
  instances, `"private"` for internal-only) only matters when
  `enable_linux_spoke_instances = true`.

**Optional: Windows spoke instances.** Ask whether the customer also wants
`enable_windows_spoke_instances = true` — one bare Windows Server instance per
spoke VPC (East and West, not per-AZ, so 2 total, not 4 like the Linux ones).
No bootstrap script; these are for RDP connectivity testing only, always
private (no public IP) — reachable via SSH port-forward through the jump box
(`ssh -i <keypair>.pem -L 3389:<private-ip>:3389 ubuntu@<jump-box-public-ip>`,
then RDP to `localhost:3389`) or a FortiGate VIP. Defaults to `false`; when
enabled, also confirm `windows_instance_type` (default `t3.medium`) and
`windows_host_ip` (default `13`).
**`windows_host_ip` has two collision constraints, not one — verified the hard
way via a real `terraform plan` failure**: it must not collide with
`linux_host_ip` (both instance types share the same East/West public AZ1
subnet), **and** it must fit within that subnet's actual host range. With the
default `spoke_subnet_bits = 4`, the East/West public subnets are `/28`s (16
addresses), and AWS always reserves the first 4 and the last address in every
subnet, leaving only host numbers roughly 4-14 usable. A value like `21`
looks like a normal host number but is invalid for a `/28` regardless of
whether `enable_windows_spoke_instances` is even `true` — the IP-address
locals in `ec2.tf` call `cidrhost()` unconditionally unless explicitly guarded
by the enable flag, so an out-of-range value here can break `terraform plan`
even for customers who never touch this feature. If the customer sets a
smaller `spoke_subnet_bits` (larger subnets, more room) or a larger one
(smaller subnets, less room), recompute the usable range accordingly rather
than assuming `4-14` always applies.

**Windows instances need their own, separate keypair — verified via a real
`terraform apply` failure**: `windows_keypair` is a distinct variable from
`keypair`, not an oversight. AWS rejects ED25519 keypairs for Windows AMIs
outright (`Unsupported: ED25519 key pairs are not supported with Windows
AMIs`) — Windows password retrieval (`GetPasswordData`) requires RSA
encryption, which ED25519 doesn't support. Since a customer's main `keypair`
(used for Linux/FortiGate instances) is very often ED25519 these days (it's
`ssh-keygen`'s modern default), **always ask whether their existing keypair is
RSA or ED25519 before assuming it can be reused for Windows** —
`aws ec2 describe-key-pairs --query 'KeyPairs[].{Name:KeyName,Type:KeyType}'`
shows the type. If they don't have an RSA keypair, create one:
`aws ec2 create-key-pair --key-name <name> --key-type rsa --key-format pem
--query 'KeyMaterial' --output text > ~/.ssh/<name>.pem && chmod 400
~/.ssh/<name>.pem`. `windows_keypair` defaults to `""` (empty) in
`variables.tf` and has no validation forcing it to be set — `terraform plan`
won't catch a missing/wrong keypair here, only `apply` will, so don't skip
asking just because `plan` looked clean.

**Required-but-unused gotcha — verified by actually running `terraform plan`**:
`linux_instance_type`, `linux_host_ip`, `acl`, `enable_management_tgw_attachment`,
`vpc_cidr_east`, and `vpc_cidr_west` all have **no default**
in `existing_vpc_resources/variables.tf` — Terraform requires values for all of
them even when `enable_linux_spoke_instances = false` and
`enable_build_existing_subnets = false` (no TGW/spokes at all). If the
customer skipped TGW/spokes in Phase 0, fill these in as unused placeholders
so `terraform plan` doesn't fail with "No value for required variable":
`linux_instance_type = "t3.micro"`, `linux_host_ip = 11`, `acl = "private"`,
`enable_management_tgw_attachment = false`,
`vpc_cidr_east = "192.168.0.0/24"`, `vpc_cidr_west = "192.168.1.0/24"` — tell
the customer these are unused placeholders in that case, not a real network
they need to plan around. **Run `terraform plan` yourself before telling the
customer the tfvars file is complete** — don't just trust the variable list
in this playbook, `variables.tf` is ground truth and this file has already
been wrong about "only required if enabled" more than once.

If TGW/spokes ARE enabled, the same variables get real values instead of
placeholders, and also confirm the remaining two important TGW questions
below — same rule as `attach_to_tgw_name` above: ask each individually, with a
full explanation, not batched:

**2. `create_tgw_routes_for_existing`** — this populates the Transit Gateway's
own route tables with default routes pointing spoke VPC traffic toward the
Management VPC. Concretely, this is what lets the jump box (and FortiManager/
FortiAnalyzer) actually reach the East/West spoke Linux instances over the
TGW, and vice versa — without it, the spoke VPCs and Management VPC are both
attached to the TGW but have no routes telling traffic how to cross between
them. Recommended `true` for lab/test environments where you want that
connectivity for testing. Recommended `false` for production: in production
you typically don't want the management plane automatically routable to every
spoke VPC by default — routing should be deliberate, not a blanket default
route baked in at TGW setup time.

**Hard dependency, now enforced in code**: this variable only makes sense when
`enable_build_existing_subnets = true` — the template can only populate TGW
route tables for spoke VPCs it actually built and knows the CIDRs/attachments
for, and has no way to safely generate routes for a customer's existing,
unknown network behind their own TGW. `existing_vpc_resources/variables.tf`'s
`create_tgw_routes_for_existing` variable has a `validation` block that fails
`terraform plan` immediately with a clear message if you set it `true` while
`enable_build_existing_subnets = false` — you no longer need to catch this
yourself, but still explain the *why* to the customer rather than just
letting the validation error surprise them.

**Related cross-template gotcha in `autoscale_template` — verified, deliberately left undocumented-only (not fixed in code)**: `autoscale_template` has its own separately-declared `create_tgw_routes_for_existing` variable (`autoscale_template/variables.tf` line 85), gating four `data` sources in `autoscale_template/vpc_inspection.tf` (lines 313, 324, 331, 342) that look up the `{cp}-{env}-east-tgw-attachment`/`east-tgw-rtb`/`west-tgw-attachment`/`west-tgw-rtb` tags `existing_vpc_resources` only creates when *its* `enable_build_existing_subnets = true`. Because these are two separate Terraform configurations/state files, `autoscale_template` has no way to see `existing_vpc_resources`'s variable value — a `validation` block can't reach across templates. **This means the same-name `create_tgw_routes_for_existing` in Phase 3 must be kept manually in sync with Phase 2's `enable_build_existing_subnets`** (not just Phase 2's own `create_tgw_routes_for_existing` value, which is what Phase 3 Section 2 currently says to mirror) — if they drift, `autoscale_template` fails with a generic "no matching resource found" on those four data sources rather than anything pointing at the real cause. Flag this explicitly to the customer in Phase 3 Section 2 rather than assuming the mirrored value is automatically safe.

**3. `enable_management_tgw_attachment`** — this attaches the Management VPC
itself to the Transit Gateway. **Get the directionality right — corrected
directly by the customer**: this is not about spokes reaching into the
management plane. It's the other way around — it's what lets the **jump box
(and other tools in the Management VPC) reach OUT to the demo East/West spoke
Linux instances** over the TGW, for testing/administering that synthetic
traffic-generator setup. Without this attachment, the Management VPC is
isolated from the TGW entirely — FortiManager/FortiAnalyzer/jump box are only
reachable by their public IPs (or via the dedicated management ENI path from
Phase 1 Section 4), and the jump box has no path *into* the spoke VPCs at all.

**This is a test/demo-environment feature specifically, not a production
consideration to weigh** — it only matters because the demo East/West spokes
(Phase 0's `enable_build_existing_subnets = true` path) exist to be reached
and administered from the jump box in the first place. A real customer
attaching to their existing production TGW (Phase 0's other branch) has no
synthetic spokes to reach this way, so this variable is simply irrelevant to
them, not something to weigh production risk against. Recommended `true`
whenever you're building the demo spokes and want the jump box to reach them;
`false` (or just not applicable) otherwise.

### 6. Review and write

Per Ground Rule 13: copy `terraform/existing_vpc_resources/terraform.tfvars.example`
to `terraform/existing_vpc_resources/terraform.tfvars` (checking Ground Rule 2
first), then edit only the variables this phase's dialogue actually decided —
leave every comment, section header, and unrelated variable from the example
file untouched. Show the customer a summary of exactly which values you
changed from the example (not the whole file — they can read the file
themselves), confirm, then save.

---

## Phase 3 — `autoscale_template/terraform.tfvars` specifics

Doc for this whole phase:
https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_3_autoscale_template/

If Phase 2 ran, **auto-fill and do not re-ask**: `aws_region`,
`availability_zone_1`, `availability_zone_2`, `availability_zone_3`, `cp`, `env`,
`vpc_cidr_management`. Set `vpc_cidr_inspection` here to the **same
`vpc_cidr_inspection` value from Phase 2** — both templates now use the same
variable name for this CIDR (the old `vpc_cidr_ns_inspection` duplicate that
used to cause copy-paste mistakes here has been removed).
All architecture flags (`firewall_policy_mode`, `access_internet_mode`,
`enable_dedicated_management_eni`, `enable_dedicated_management_vpc`,
`enable_tgw_attachment`, licensing model, capacity tier) are already *decided*
from Phase 1 — this phase just fills in the remaining values. **"Decided" is
not the same as "written"**: both `enable_dedicated_management_eni` and
`enable_dedicated_management_vpc` have no default in `variables.tf`, so both
must be written explicitly even though only one is really "on."
**Corrected — this previously said the opposite and was wrong**: do NOT set
`enable_dedicated_management_eni = true` alongside `enable_dedicated_management_vpc
= true`. A `check` block (`autoscale_template/vpc_inspection.tf` line 12)
hard-fails `terraform plan` if both are `true` simultaneously
(`!(enable_dedicated_management_eni && enable_dedicated_management_vpc)` — pure
boolean logic, not something that needs a live test to confirm). When Phase 1
Section 4 chose "dedicated ENI reaching the Management VPC," write
`enable_dedicated_management_vpc = true` and `enable_dedicated_management_eni
= false` explicitly — the `vpc` flag alone is sufficient to create the extra
network interface (see `autoscale_group.tf`'s `extra_network_interfaces`
condition, which triggers on *either* flag being true, not requiring both).

If Phase 0 said the customer already has tagged VPCs, ask for the carried-
forward values fresh, and remind them they must exactly match whatever tags
exist on their VPCs.

### 1. Security

- `keypair` — same rules as Phase 2; can reuse the same keypair or a different
  one for FortiGate SSH access.
- `vpc_cidr_sg` — CIDRs allowed to reach FortiGate management (GUI/SSH). Can
  reuse Phase 2's `management_cidr_sg` value or ask fresh. Apply Ground Rule 7
  again here: always append `vpc_cidr_management`.
- `fortigate_asg_password` — **required**, min 8 characters. This becomes the
  FortiGate `admin` password and syncs to all instances in the group via HA
  sync.

### 2. Transit Gateway integration

From Phase 0 (TGW+spokes decision):
- `enable_tgw_attachment` — attaches the inspection VPC to the TGW.
- If true: `attach_to_tgw_name` (reuse Phase 2's TGW name), 
  `create_tgw_routes_for_existing`.
- `enable_east_west_inspection` — routes spoke-to-spoke traffic through the
  FortiGate for inspection. Only meaningful with TGW attachment on — ask.

**`create_tgw_routes_for_existing` here must match Phase 2's
`enable_build_existing_subnets`, not Phase 2's own `create_tgw_routes_for_existing`
value.** Verified cross-template gotcha: this is a *separately declared*
variable in `autoscale_template`, gating four `data` sources
(`autoscale_template/vpc_inspection.tf` lines 313, 324, 331, 342) that look up
the demo East/West TGW attachment/route-table tags `existing_vpc_resources`
only creates when *its* `enable_build_existing_subnets = true`. Since
`autoscale_template` is a separate Terraform configuration/state, there's no
code-level check tying these together — get it wrong and you get a generic
"no matching resource found" instead of anything pointing at the real cause.
**Only set this `true` if Phase 2 built the demo TGW + spokes
(`enable_build_existing_subnets = true`) — if Phase 0 chose "attach to an
existing TGW" instead, this must be `false` here regardless of what Phase 2's
own `create_tgw_routes_for_existing` was set to.**

**`create_tgw_routes_for_existing` and `enable_east_west_inspection` have no
default in `variables.tf` — write them even when `enable_tgw_attachment =
false`** (both `false` in that case, they're just not meaningfully "used").
Same class of gotcha as `vpc_cidr_east`/`west` below — don't skip
writing a variable just because the feature it controls is off.

**Required-but-unused gotcha**: `vpc_cidr_east` and `vpc_cidr_west` have **no
defaults** in `autoscale_template/variables.tf` — Terraform requires a value
for both even when `enable_tgw_attachment = false` and no spoke VPCs exist
anywhere in this deployment. If Phase 2 built spoke VPCs, reuse those exact
CIDRs here (they must match). If not, fill in the conventional placeholder
values anyway so `terraform plan` doesn't fail:
`vpc_cidr_east = "192.168.0.0/24"`, `vpc_cidr_west = "192.168.1.0/24"` — tell
the customer these are unused placeholders in this case, not a real network
they need to plan around. (There's also an optional `spoke_cidrs` list — leave
it unset; it defaults to `[vpc_cidr_east, vpc_cidr_west]` and only needs
setting if the real spoke list differs from those two.)

### 3. FortiGate specs

- `fgt_instance_type` — recommend based on use case: `t3.xlarge` (testing/lab),
  `c6i.xlarge` (small production, ~12.5 Gbps), `c7gn.xlarge` (high performance,
  ~25 Gbps, ARM-based cost-efficient).
- `fortios_version` — **do not trust the docs' example version (`7.4.5`) —
  verified by actually deploying that it's stale and no longer published.**
  Marketplace AMIs get deprecated/removed over time, so a version that worked
  when the docs were written may 404 at `terraform plan` time with "Your query
  returned no results." If you have AWS credentials available, check what's
  actually published before setting this:
  ```bash
  aws ec2 describe-images --owners aws-marketplace \
    --filters "Name=name,Values=FortiGate-VM*(7.4*" \
    --query 'sort_by(Images, &CreationDate)[].Name' --output text
  ```
  (adjust the product-code filter for BYOL vs PAYG / Intel vs ARM if you want
  to narrow it — see `fgt_asg/main.tf`'s `local.product_code` for the mapping).
  Pick a version from what's actually returned, not from memory or the docs.

  **Simpler alternative that sidesteps this whole problem**: the AMI lookup
  does a wildcard/prefix match on `fortios_version` (`"FortiGate-VM*(${var.fgt_version}*"`)
  combined with `most_recent = true`, so a **partial version like `"7.4"`**
  (major.minor only, no patch number) matches every `7.4.x` build and
  Terraform picks the newest one automatically — it self-heals as new patch
  builds get published and old ones get deprecated, instead of going stale.
  Only use a full three-part version (`"7.4.11"`) when the customer needs a
  *specific pinned patch* (e.g. matching a known-good version elsewhere in
  their fleet, or avoiding a patch with a regression) — recommend the partial
  form as the default for lab/test, and mention the tradeoff (pinned = fully
  reproducible but can go stale; partial = always current but can drift
  between `terraform apply` runs). The same wildcard behavior applies to
  `fortimanager_os_version`/`fortianalyzer_os_version` in Phase 2 — same
  `(${var...}*)` pattern in their AMI filters.
- `fortigate_gui_port` — default `443`.

### 4. Licensing values

From Phase 1 Section 1's answers, fill in the actual values now:
- Perpetual files → `asg_license_directory` value
- **Whenever perpetual files are NOT in use (FortiFlex or PAYG) — explicitly
  set `asg_license_directory = null` in the tfvars file, don't just leave it
  unset.** Verified the hard way via a real `terraform apply` failure:
  `variables.tf` defaults this to `""` (empty string), not `null`, but the
  downloaded `fgt_asg` module (`main.tf` local `lic_folder`/`lic_file_set`)
  only treats a literal `null` as "no license directory" — an empty string
  fails that check and falls through to `fileset("", "*")`, which lists every
  file in the `autoscale_template` working directory (`.tf` files,
  `terraform.tfstate`, `.tftpl` config templates) and tries to upload them to
  S3 as if they were license files, failing with `Call to function "filemd5"
  failed: open /provider.tf: no such file or directory` (and similarly for
  every other file in the directory). This is a bug in the external module,
  not something fixable in this repo's own `.tf` files — the tfvars-level
  workaround (`asg_license_directory = null`) avoids it entirely.
- FortiFlex → `fortiflex_username`, `fortiflex_password`, `fortiflex_sn_list`,
  `fortiflex_configid_list` — ask the customer to confirm the actual vCPU
  requirement from the FortiFlex portal's real config ID definition before
  picking `fgt_instance_type` in Section 3. Don't infer it from the config
  ID's name string (e.g. don't assume `Standard_Autoscale_FGT_4vcpu` means 4
  vCPUs just because the name says so) — the name is a label, not an
  enforced constraint.
- Capacity tier from Phase 1 → concrete `asg_byol_asg_min_size` /
  `max_size` / `desired_size` and `asg_ondemand_asg_min_size` / `max_size` /
  `desired_size`
- `primary_scalein_protection` — from Phase 1 Section 7

### 5. FortiManager integration

**Only if Phase 1 Section 6 said yes.**

- `enable_fortimanager_integration = true`
- `fortimanager_ip` — **use the private IP only if Phase 1 Section 4 Question
  B selected the TGW-connected dedicated-ENI sub-option; otherwise use the
  public IP** (`terraform output fortimanager_public_ip` after Phase 2's
  apply, or from the SSH session used to grab the serial number below). The
  private form is `<vpc_cidr_management base>.<fortimanager_host_ip>` (e.g.
  `10.3.0.10`) — only reachable from the FortiGate when that ENI path exists.
- `fortimanager_sn` — **only available after FortiManager is actually deployed
  and running** — get it from the FortiManager GUI/CLI (`get system status`) or
  System Settings > Dashboard. If FortiManager hasn't been deployed yet, tell the
  customer to come back and fill this in after Phase 2's `terraform apply`
  finishes. If you have the SSH keypair's private key available locally (check
  `~/.ssh/<keypair-name>.pem` or `.key`) and Phase 2's `terraform apply` already
  ran, you can fetch this yourself instead of asking the customer to log in
  manually: `ssh -i ~/.ssh/<keypair>.pem admin@<fortimanager_public_ip> "get
  system status"` (default password is the instance ID on first boot, but SSH
  key auth bypasses that). FortiManager can take a few minutes after
  `terraform apply` completes before SSH responds — poll with retries rather
  than giving up after one timeout.
- `fortimanager_vrf_select` — `0` (global VRF) unless
  `enable_dedicated_management_eni = true`, then usually `1`.

### 6. Everything else

**Verified by actually running `terraform plan` — split into two groups, don't
treat them the same:**

- **Truly optional (have a real default in `variables.tf`, safe to omit
  entirely)**: `asg_module_prefix` (`""`), `endpoint_name_az1`/`az2`/`az3`
  (`""`), `modify_existing_route_tables` (`true`), `fgt_instance_type` and
  `fortios_version` (both default `""`, but you always set these explicitly in
  Section 3 anyway).
- **Required — no default, must be written even though the value is almost
  always the same**: `allow_cross_zone_load_balancing` (`true`),
  `gwlb_health_check_port` (`8008`), `gwlb_health_check_interval` (`60`),
  `gwlb_healthy_threshold` (`5`), `asg_health_check_grace_period` (`700`).
  Write all five into the tfvars file with these recommended values — don't
  skip them as "just defaults," `terraform plan` will fail with "No value for
  required variable" if you do. Only skip asking the customer about them (the
  values are rarely worth customizing), not
  skip *writing* them.

**Removed as dead code**: `autoscale_template` used to also declare a
required, no-default `acl` variable (copy-pasted from `existing_vpc_resources`,
where it genuinely controls Linux spoke instance visibility). Confirmed via
grep across this template's own `.tf` files and the entire downloaded module
tree — nothing referenced `var.acl` anywhere in `autoscale_template`. It's
been deleted from `variables.tf`, `terraform.tfvars.example`, and `tfvars.ui`.
Don't ask about or write `acl` for `autoscale_template` going forward.

### 7. Review and write

Per Ground Rule 13: copy `terraform/autoscale_template/terraform.tfvars.example`
to `terraform/autoscale_template/terraform.tfvars` (checking Ground Rule 2
first), then edit only the variables this phase's dialogue actually decided —
leave every comment, section header, and unrelated variable from the example
file untouched. Show the customer a summary of exactly which values you
changed from the example (not the whole file), confirm, then save.

---

## Phase 4 — Deploy

**Pre-flight: diff-check, don't just trust that Phase 3's "auto-fill" actually
matched.** Before running anything, actually compare the two written files —
`aws_region`, `availability_zone_1`/`2`/`3`, `cp`, `env`, `vpc_cidr_inspection`,
and (if applicable) `attach_to_tgw_name` must be byte-identical between
`existing_vpc_resources/terraform.tfvars` and
`autoscale_template/terraform.tfvars` (the old `vpc_cidr_inspection` vs.
`vpc_cidr_ns_inspection` footgun is gone now — both templates use the same
name). A quick `grep` of both files for these keys and eyeballing the values
takes seconds and catches a copy-paste slip before it burns 10+ minutes of
`apply` time discovering it as "no matching VPC found."

Walk the customer through, **one template at a time, in order**:

```bash
cd terraform/existing_vpc_resources   # skip if using pre-tagged VPCs
terraform init
terraform plan     # review what will be created before applying
terraform apply    # type "yes" to confirm
```

Then:

```bash
cd ../autoscale_template
terraform init
terraform plan
terraform apply
```

Before running `terraform apply` on `autoscale_template`, remind the customer to
double check:
- BYOL license files are in place (if using perpetual files), or the PAYG
  Marketplace subscription is accepted (if using on-demand capacity)
- `cp`/`env` really do match between both tfvars files

After `apply` succeeds, point them at the verification steps in the docs rather
than repeating them all here:
- [existing_vpc_resources verification](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_2_existing_vpc_resources/#step-9-verify-deployment)
- [autoscale_template verification](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_3_autoscale_template/#step-18-verify-deployment)
- [autoscale_template troubleshooting](https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/5_templates/5_3_autoscale_template/#troubleshooting) if anything looks wrong

**If Phase 1's licensing capacity used the "deploy idle" shape**
(`asg_byol_asg_min_size = 0`, `desired_size = 0`), nothing launches
automatically — remind the customer how to actually bring FortiGates up when
they're ready, either via the AWS Console (EC2 > Auto Scaling Groups > find
the BYOL ASG, name pattern `{cp}-{env}-{asg_module_prefix}-byol` > Edit
desired/min capacity) or the CLI:
```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name-from-terraform-output-or-console> \
  --min-size 1 --desired-capacity 1
```
Get the exact ASG name from `terraform output fortigate_autoscale_group_name`
in `autoscale_template` if unsure.

Remind them how to tear it down when done, **in the correct order** (autoscale_template
first, then existing_vpc_resources — the inspection VPC's TGW attachment must be
destroyed before the TGW itself):

```bash
cd terraform/autoscale_template && terraform destroy
cd ../existing_vpc_resources && terraform destroy
```

---

## Fast path (optional shortcut)

If the customer just wants a quick, cheap, working test deployment and doesn't
want to answer every question above, offer the **Minimal** shortcut: no TGW/
spokes (Phase 0), no management isolation/FortiManager/FortiAnalyzer/jump box
(Phase 1 Sections 4–6), EIP egress, 1-arm firewall mode, perpetual-license BYOL
with dev/test capacity, no PAYG burst. Ask only for: `aws_region`, two AZ
letters, `cp`, `env`, `keypair`, their public IP (for
`management_cidr_sg`/`vpc_cidr_sg`), and `fortigate_asg_password`. Still show
the final tfvars content for confirmation before writing.
