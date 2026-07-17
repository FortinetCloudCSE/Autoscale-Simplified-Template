# Versioning Work Handoff

## Status

- Working branch: `chore/add-release-versioning`
- Candidate release: `v2.0.0`
- Prepared: 2026-07-17
- No Terraform plan or apply was run, and no AWS credentials were used.

## Summary

This branch adds an immutable release process, Terraform validation automation,
provider lock files, top-level Git module pins, release documentation, and a
candidate `v2.0.0` version. It also canonically formats the existing Terraform
files required for the new formatting check.

The implementation initializes and validates successfully, and the workshop
build succeeds locally. Provider compatibility and one upstream transitive
module limitation still require maintainer review before merge and publication.

## Versioning and documentation

- `VERSION` identifies the candidate release as `2.0.0`.
- `CHANGELOG.md` records the candidate features, breaking changes, compatibility
  assumptions, and known issues.
- `RELEASING.md` defines Semantic Versioning rules, validation requirements,
  review expectations, tag creation, release publication, and correction of a
  defective release.
- `README.md` documents cloning an exact release tag and creating a normal local
  branch from the detached tag checkout.

`v2.0.0` was selected as the candidate major release because the repository has
changed substantially since `1.1.0`, including replacement of the former
`terraform/unified_template` root with `terraform/autoscale_template`.

## Automation

### Pull-request validation

`.github/workflows/terraform-validate.yml` runs on pull requests, pushes to
`main`, and manual dispatch. It:

- Uses Terraform 1.14.7.
- Checks canonical formatting.
- Initializes with no backend and `-lockfile=readonly`.
- Validates all three deployable roots.
- Does not run `terraform plan` or `terraform apply`.
- Does not receive cloud credentials.

The three roots are:

- `terraform/autoscale_template`
- `terraform/existing_vpc_resources`
- `terraform/green_inspection_stack`

### Release publication

`.github/workflows/release.yml` reacts to tags matching `v*.*.*`. It:

- Confirms the tag matches `VERSION`.
- Confirms the changelog has a matching version section.
- Checks formatting and validates all Terraform roots.
- Builds the workshop.
- Creates the GitHub Release only after every preceding job succeeds.
- Marks versions containing a prerelease suffix as prereleases.
- Uses `gh release create --verify-tag`, so it will not silently create a tag.

The release workflow is intentionally tag-triggered. The release tag must be
created only after review and merge into `main`.

### Workshop build

The production Pages and release workflows now pin the tested workshop image:

```text
public.ecr.aws/k4n6m5h8/fortinet-hugo@sha256:d1800d7b20751e6b4d57d0c2c563ab92d291d167659b507ee8846611a0ccf43e
```

The manually selected development image remains unchanged.

## Terraform dependency baseline

All three roots provisionally require:

```hcl
required_version = ">= 1.14.7, < 2.0.0"
```

This conservative minimum reflects the CLI version actually validated during
this work. Older Terraform versions have not been tested. Maintainers can
broaden the range after demonstrating compatibility.

All roots constrain the AWS provider to `~> 5.0`. The lock files select these
exact versions:

| Terraform root | Locked providers |
| --- | --- |
| `autoscale_template` | AWS 5.100.0, Archive 2.8.0, Null 3.3.0, Random 3.9.0 |
| `existing_vpc_resources` | AWS 5.100.0, Random 3.9.0, Time 0.14.0 |
| `green_inspection_stack` | AWS 5.100.0, Archive 2.8.0, Null 3.3.0 |

Each root has its own committed-candidate `.terraform.lock.hcl`. The lock files
include official checksums for:

- Linux AMD64 and ARM64
- macOS AMD64 and ARM64
- Windows AMD64

The AWS 5.x baseline is provisional. Before constraints were added, a fresh
initialization selected AWS 6.55.0 in the two unconstrained roots, while the
green stack already constrained AWS to 5.x. AWS 5.100.0 was selected as the
conservative common baseline. A maintainer should run non-production plans to
confirm it before merge.

## Git module pins

All 26 top-level Git-hosted module sources now use immutable commit SHAs:

| Upstream repository | Commit | References |
| --- | --- | ---: |
| `fortinetdev/terraform-aws-cloud-modules` | `f8286c4d68d64c5253a7f05ef7a9861078c0fd05` | 2 |
| `40netse/terraform-modules` | `3c5c13341e17986e2c21ef3bce2dc2aba5af5b74` | 24 |

### Transitive-module limitation

The pinned `40netse/terraform-modules` composite modules declare nested module
sources that fetch the same upstream repository without a `ref`. Pinning the
top-level sources therefore does not make that dependency tree fully
reproducible.

Maintainers must choose one of these options before publication:

1. Fix the nested sources in the upstream module repository and pin the new
   upstream commit.
2. Vendor the required modules into this repository and use local paths.
3. Explicitly accept and document the residual risk for this release.

The first option is preferable if the upstream repository is actively
maintained. Vendoring provides the strongest local control but adds maintenance
overhead and significantly increases this pull request's scope.

## Mechanical Terraform formatting

`terraform fmt -recursive terraform` canonically formatted 16 existing files.
The changes are alignment, whitespace, and four legacy variable labels that
Terraform changed from unquoted to quoted form. All affected configurations
continued to validate afterward. No resource values or intended behavior were
changed by the formatting operation.

## Completed validation

The following checks succeeded:

- `terraform fmt -check -recursive terraform`
- `git diff --check`
- YAML parsing with `yq`
- YAML linting with `yamllint` for both new workflows
- Release metadata simulation for `v2.0.0`
- Pinned module initialization
- Provider lock generation for the supported platforms
- `terraform init -backend=false -input=false -lockfile=readonly` for all roots
- `terraform validate` for all roots
- Local production workshop container build, including generation of
  `index.html`

The initial workshop pull encountered an expired cached Public ECR token on the
development host. Retrying with an isolated anonymous Docker configuration
succeeded without modifying the developer's Docker credentials.

## Required maintainer review

Before merging, please:

- Confirm the repository policy that stable versions use
  `vMAJOR.MINOR.PATCH`, follow the Semantic Versioning rules in
  `RELEASING.md`, and are never moved or deleted after publication.
- Confirm `v2.0.0` is the intended release number.
- Finish the changelog compatibility matrix and release date, and verify the
  feature, breaking-change, migration, and known-issue entries are complete.
- Recheck the README clone example against the final version number.
- Run non-production plans for the applicable Terraform roots using the locked
  AWS 5.100.0 provider.
- Compare the selected CLI, provider, and module versions with a known-good
  deployment record if one is available. Otherwise, treat the non-production
  plans and deployment test as the required baseline evidence.
- Confirm that dependency pinning alone causes no unexpected infrastructure
  changes. Investigate every unexpected plan action before applying anything.
- Confirm whether Terraform versions older than 1.14.7 must remain supported;
  test before broadening the constraint.
- Choose how to handle the unpinned nested sources in
  `40netse/terraform-modules`.
- Review the 16-file formatting diff separately from functional changes.
- Push the branch and confirm the Terraform validation workflow passes in
  GitHub Actions.
- Manually run the Pages workflow against the branch and review the rendered
  workshop.
- Confirm the production workshop image digest should remain pinned.
- Stage files by explicit path rather than using `git add -A` while that
  unrelated deletion is present.
- Review the complete consolidated diff and prepare one pull request from
  `chore/add-release-versioning`.

## GitHub configuration and post-merge release

Before creating the tag, add a GitHub tag ruleset targeting `v*` that restricts
tag updates and deletions. Restrict creation only after confirming release
maintainers or automation have the necessary bypass access.

After approval and merge:

```bash
git switch main
git pull --ff-only
test "$(cat VERSION)" = "2.0.0"
git tag -a v2.0.0 -m "Autoscale Simplified Template v2.0.0"
git push origin v2.0.0
```

Leave the historical `v1.0.0`, `1.1.0`, and `pre-upgrade-toolset` tags
unchanged.

Pushing the tag starts the release workflow. Do not separately create another
tag or move the tag if the workflow fails. Rerun the workflow if the failure was
transient. If source changes are required, correct them in a new commit and
publish a new patch version rather than moving the existing remote tag.

Confirm the workflow publishes release notes containing the final features,
compatibility matrix, breaking changes, migration guidance, known issues, and
clone command.

Finally, verify the consumer path:

```bash
git clone \
  --branch v2.0.0 \
  --single-branch \
  --depth 1 \
  https://github.com/FortinetCloudCSE/Autoscale-Simplified-Template.git \
  /tmp/autoscale-v2-release-check
```

In that release clone, confirm:

- `VERSION`, `CHANGELOG.md`, and the checked-out tag all identify `v2.0.0`.
- Each root honors its committed provider lock file.
- Top-level Git modules resolve to the documented immutable commits.
- The accepted decision about nested `40netse` module sources is reflected in
  the release notes.
- The expected workshop content and versioned clone instructions are present.

## Ongoing maintenance after the first release

- Record user-visible changes under `[Unreleased]` as pull requests merge.
- Upgrade providers only through reviewed constraints and lock-file changes.
- Upgrade Git modules only through reviewed `ref` changes.
- Run non-production plans before accepting dependency upgrades.
- Publish a new immutable tag and GitHub Release for every stable version.
