# Releasing the Autoscale Simplified Template

This document describes how to prepare, review, and publish an immutable release
of this repository. Release preparation happens in a pull request. Tags and
GitHub Releases are created only after that pull request is approved and merged
into `main`.

## Version policy

Stable releases use annotated Git tags named `vMAJOR.MINOR.PATCH`. The root
`VERSION` file contains the same version without the `v` prefix.

- Increment `MAJOR` for incompatible variable or default changes, resource
  address or state changes, removed functionality, layout changes, or deployment
  behavior that requires consumer action.
- Increment `MINOR` for backward-compatible features.
- Increment `PATCH` for backward-compatible fixes and documentation corrections.
- Use a prerelease identifier such as `v2.1.0-rc.1` when a candidate needs wider
  testing before it is declared stable.

Published tags are immutable. Never move, reuse, or delete a published release
tag. If a release is defective, correct it in a new patch release.

The existing `v1.0.0`, `1.1.0`, and `pre-upgrade-toolset` tags are legacy
history and must remain unchanged. New stable tags must use the `v` prefix.

## Prepare the release pull request

1. Choose the version by reviewing all changes since the previous stable tag.
2. Add or update `VERSION` with the version without the `v` prefix.
3. Move applicable `CHANGELOG.md` entries from `[Unreleased]` into a section
   named for the version and release date.
4. Document features, breaking changes, migration steps, known issues, and the
   tested compatibility matrix.
5. Confirm all Git-hosted Terraform modules use immutable commit references.
6. Confirm each Terraform root has reviewed provider constraints and a committed
   `.terraform.lock.hcl`.
7. Confirm the README clone example names the intended release.

Do not claim compatibility based only on successful initialization or syntax
validation. Record versions demonstrated by a known-good deployment or a
non-production plan and deployment test.

## Required validation

Run formatting once from the repository root:

```bash
terraform fmt -check -recursive terraform
```

Then initialize without configuring a backend and validate each Terraform root:

```bash
for directory in \
  terraform/autoscale_template \
  terraform/existing_vpc_resources \
  terraform/green_inspection_stack
do
  terraform -chdir="$directory" init \
    -backend=false \
    -input=false \
    -lockfile=readonly
  terraform -chdir="$directory" validate
done
```

Also complete the following checks:

- Run non-production plans for Terraform or dependency changes and investigate
  every unexpected action before applying anything.
- Run the GitHub Pages workflow against the release branch and inspect the
  resulting workshop.
- Confirm the Terraform validation workflow passes.
- Review the complete branch diff and exclude unrelated working-tree changes.
- Inspect transitive module downloads. A top-level Git `ref` does not pin nested
  Git sources declared inside the selected upstream module.

The automated validation workflow must never run `terraform plan` or
`terraform apply` and must not receive cloud credentials.

## Review and merge

Provide the reviewer with:

- A summary of every file changed and why.
- The selected Terraform and provider versions.
- The immutable SHA selected for each upstream module repository.
- Formatting, initialization, validation, plan, and workshop-build results.
- Any compatibility changes or required migrations.
- The exact post-merge tag and release commands.

Do not create the release tag while review changes are still possible. Merge the
approved pull request first.

Before publication, configure a GitHub tag ruleset targeting `v*` that restricts
tag updates and deletions. Restrict tag creation only after confirming the
release-management team or automation has the necessary bypass permission.

## Publish after merge

Update the local `main` branch and verify that its checked-in version matches the
intended tag:

```bash
git switch main
git pull --ff-only
test "$(cat VERSION)" = "2.0.0"
```

Replace `2.0.0` in these examples with the approved version. Create and push an
annotated tag:

```bash
git tag -a v2.0.0 -m "Autoscale Simplified Template v2.0.0"
git push origin v2.0.0
```

Publish a GitHub Release only from the existing remote tag:

```bash
gh release create v2.0.0 \
  --verify-tag \
  --title "Autoscale Simplified Template v2.0.0" \
  --generate-notes
```

Review the generated notes and add the compatibility matrix, breaking changes,
migration guidance, known issues, and exact clone command.

## Verify the published release

Clone the tag into a temporary directory:

```bash
git clone \
  --branch v2.0.0 \
  --single-branch \
  --depth 1 \
  https://github.com/FortinetCloudCSE/Autoscale-Simplified-Template.git \
  /tmp/autoscale-v2-release-check
```

Confirm that:

- `VERSION`, the changelog section, and the Git tag agree.
- Provider lock files are present and honored.
- Git-hosted modules resolve to the documented immutable commits.
- The release contains the expected Terraform and workshop content.
- The README clone instructions work as written.

## Correcting a release problem

Before publication, add a corrective commit to the release branch and repeat all
checks. After publication, leave the original tag and release intact, document
the issue, prepare a patch release, and direct consumers to the corrected tag.
