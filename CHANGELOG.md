# Changelog

Notable changes to the Autoscale Simplified Template are documented here. This
project uses [Semantic Versioning](https://semver.org/) for stable releases.

## [Unreleased]

- No changes yet.

## [2.0.0]

### Added

- Three-AZ deployment support.
- FortiOS upgrade toolset.
- Green inspection stack.
- Versioned release documentation and validation automation.

### Changed

- Added explicit Terraform and provider compatibility constraints to each
  deployable Terraform root.
- Locked provider selections for supported Linux, macOS, and Windows platforms.
- Pinned top-level Git-hosted Terraform modules to immutable commit SHAs.
- Pinned the production workshop build to the tested container-image digest.
- Compatibility changes since the previous stable release are being audited
  before the next version number is finalized.

### Fixed

- No entries yet.

### Breaking Changes

- The deployable `terraform/unified_template` root was replaced by
  `terraform/autoscale_template`. Automation and local workflows that refer to
  the old directory must be updated.
- Existing deployments must preserve and back up their Terraform state, update
  their working directory carefully, and review a non-production plan before
  applying this release. The Terraform roots and resource definitions have
  changed substantially since `1.1.0`.
- Terraform 1.14.7 or newer (but earlier than 2.0) and AWS provider 5.x are the
  conservative candidate constraints because those versions were validated
  during release preparation. Maintainers should test and broaden the Terraform
  range if older CLI versions must remain supported.

### Known Issues

- The pinned `40netse/terraform-modules` composite modules contain nested module
  sources that still follow that upstream repository's default branch. Full
  transitive pinning requires an upstream fix or vendoring those modules. This
  must be resolved or explicitly accepted before the release is published.
- AWS provider 5.100.0 is the conservative candidate baseline. A maintainer must
  confirm it with a non-production plan before publication.
