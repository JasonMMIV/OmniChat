# OpenCode catalog overlay snapshot

- Source: https://models.opencode.ai/api.json
- Extracted: 2026-11-04
- License: see the upstream source's terms
- Generator: `dart run tool/build_opencode_catalog.dart`

This directory contains a pruned copy of the OpenCode catalog used as an
overlay on top of the models.dev snapshot. Only the `opencode` and
`opencode-go` provider entries are kept; the runtime merge lets OpenCode's
Console/Zen/Go models win over models.dev while retaining models.dev-only
entries.

The snapshot is a build artifact. Do not edit `opencode.json` by hand — rerun
the generator instead. The app refresh path downloads the same upstream file
at runtime and prunes/filters it with the same rules.
