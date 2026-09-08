# Overland modernization: continuation plan

Updated 2026-09-06 after recovering OpenCode session `ses_f9756628cffeIT7Bxhdfl3MZ8D`.
The prior plan overstated completion and included publication steps the owner subsequently revoked.

## Release boundary

All work stays on local `backup/overhaul-2026-09-03`. Do not commit, push, merge remote PRs,
or comment on/close GitHub issues until the owner explicitly approves after their simulator trial.
The fork has issues disabled and no open PRs. Upstream issues/PRs remain open; local fixes do not close them.

## Scope and order

1. Recover feedback and audit existing modifications. **Done.** Preserve SwiftUI, Objective-C core,
   native grouped forms, iOS 17 support, and gated iOS 26 glass.
2. Finish the four trial corrections. **Implemented.** Separate controls from the tab bar;
   inset black speedometer border with white edge; remove unrelated warning badge;
   make slider values observable, editable and adjustable in single-unit increments.
3. Finish the trip map/timeline and cohesive Server/Trip Settings navigation. **Implemented.**
   Preserve stable point IDs while scrubbing; cap fetched history at 1,000 recent points.
4. Audit and repair networking, queue transactions, trip state and location-source lifecycle.
   **Implemented and regression-tested.** Details in `AUDIT.md`.
5. Apply compatible custom-header behavior from upstream PR #190 and the three documentation PRs.
   **Implemented locally.** Retain authorship references in `AUDIT.md`; no remote merge claimed.
6. Build, run regression tests, use IDB for interaction checks, and install the final build for trial.
   **Complete.** Build and regression results are recorded in `AUDIT.md`. IDB checks passed
   before the final permission/settings restoration; the owner will check the final UI manually.
7. Owner trial, then explicit release approval. **Pending owner.**

## Boundaries

- Keep StoreKit 1 and the legacy Tip Jar. Do not migrate purchasing as part of tracking/network fixes.
- Keep HTTP endpoints and existing setup-link behavior. TLS validation remains enabled.
- Use CLLocationUpdate for Best accuracy with automatic pausing. Use the standard CLLocationManager
  source for custom/navigation accuracy or disabled pausing, because liveUpdates has no corresponding controls.
- Keep region delegates for pause/resume; no speculative CLMonitor migration.
- Simulator checks cannot establish real-device battery usage, background delivery reliability,
  WiFi entitlement behavior, or purchase fulfillment.
- Watch apps, Live Activities, MDM, iBeacon support, iCloud exports and localization are separate projects.
