# Abera Chatwoot release contract

This fork is the source of Abera-managed Chatwoot CE images. The maintained
branch `abera-4.16` starts at upstream Chatwoot `v4.16.2`, commit
`70e284a044f00326725f65f703162745371075ec`.

## Release

1. Merge reviewed application changes into `abera-4.16`.
2. Run the relevant Chatwoot tests for those changes.
3. Create a unique tag such as `abera-v4.16.2.1`.
4. Wait for `Abera Chatwoot CE image` to build and verify the ARM64 CE image.
5. Make the GHCR package public if this is its first publication.
6. Use the exact `image` digest from the `image.json` workflow artifact as the
   source of a new `abera-chatwoot-isolated` product version.

Never reuse or move a release tag. Tags identify source; deployment always uses
the resulting registry digest.

## Customer update

An application release does not require deleting a customer stack. The Abera
control plane must take and verify a backup, stop application traffic, run
Chatwoot's `db:chatwoot_prepare` with the target image, verify data,
credentials, health and the public probe, then activate the release. A failed
verification restores the previous image and, when required by migration
compatibility, the pre-update backup.

PostgreSQL data, Redis data, attachments and credentials must remain outside
the application image. Do not add customer configuration or secrets to this
repository or its GitHub Actions configuration.

## Upstream upgrades

Create a new maintained branch from a reviewed upstream release tag. Read the
upstream release notes and migrations, resolve Abera changes explicitly and
publish a new Abera tag. Do not merge upstream `develop` directly into the
active customer release branch.
