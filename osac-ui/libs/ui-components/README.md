# `@osac/ui-components` Ownership Guide

This package is for shared, reusable UI building blocks used across multiple app areas.

## Put components here when

- The component is reused by two or more features/pages.
- The component is feature-agnostic (no page routing or feature-specific business logic).
- The component API can stay stable as a small shared contract.

## Keep components in `apps/app-frontend` when

- The component is tied to a single route/feature flow.
- It depends on page-local behavior, route assumptions, or feature-specific orchestration.
- It is still evolving quickly and not yet reused.

## Practical examples

- Shared candidates: shell toggles, status labels, generic topology/placeholder building blocks.
- App-local candidates: route-level page composition, feature wizards, flow-specific drawer/content logic.

When an app-local component becomes reused across multiple domains, promote it into this package as a PascalCase file under `src/` (e.g. `VmStatusLabel.tsx` + `VmStatusLabel.css`). Import via the wildcard export: `@osac/ui-components/VmStatusLabel`.
