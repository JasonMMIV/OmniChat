# models.dev catalog snapshot

- Source: https://models.dev/api.json
- Extracted: 2026-10-23
- License: MIT (https://github.com/sst/models.dev/blob/dev/LICENSE)
- Generator: `dart run tool/build_model_catalog.dart`

This directory contains a pruned copy of the models.dev catalog used as the
default data layer for context windows and model capabilities (model catalog
plan, batch 1). Only the fields OmniChat consumes are kept; names,
descriptions, families, pricing and release metadata are discarded.

The snapshot is a build artifact. Do not edit `models_dev.json` by hand — rerun
the generator instead. The app refresh path downloads the same upstream file
at runtime and prunes it with the same rules.
