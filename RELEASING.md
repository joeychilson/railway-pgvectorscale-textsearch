# Releasing

This repository versions the Railway wrapper independently from PostgreSQL and
its extensions. Upstream versions are recorded in each release, not copied into
the wrapper version.

Use semantic versioning for the wrapper:

- Patch: compatible upstream and dependency updates or wrapper fixes.
- Minor: new, backward-compatible template behavior or configuration.
- Major: changes that require users to update configuration or migrate data.

To publish an image:

1. Merge the change and confirm `ci.yml` passes on `main`.
2. Create a GitHub release tagged `vX.Y.Z`.
3. Include the PostgreSQL, pgvectorscale, and pg_textsearch versions in the
   release notes.
4. Confirm `release.yml` publishes both current and legacy GHCR package names.
5. When starting a new major or minor line, update the public Railway
   template's source image to
   `ghcr.io/joeychilson/railway-pgvectorscale-textsearch:X.Y` only after that
   image has been published successfully.

Each release publishes immutable `X.Y.Z` and `sha-<commit>` tags and a moving
`X.Y` patch channel. No new `latest` tag is published. Railway templates should
reference `X.Y` when compatible patch updates should be automatic, or `X.Y.Z`
when the image must stay fixed.
Changing the public template affects future deployments only. Existing
Docker-image deployments keep their configured image tag.
