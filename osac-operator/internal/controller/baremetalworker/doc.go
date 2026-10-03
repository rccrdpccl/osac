// Copyright (c) 2026 Red Hat Inc.
// SPDX-License-Identifier: Apache-2.0

// Package baremetalworker reconciles ClusterOrder bare-metal NodeSets through
// fulfillment BareMetalInstances and Assisted Service Agents.
//
// The package follows responsibility-based controller organization: related
// reconciliation methods and their helpers stay together in the same package.
// No file defines an independent controller or a separate persistence boundary.
//
// Entry points and controller/watch setup live in reconciler.go. Normal stage
// ordering lives in worker_reconcile.go: observe resources and persist repairs,
// observe InfraEnv UID evidence, run the input-free existing-worker lifecycle
// (retirement intent and failed-incarnation cleanup), resolve creation inputs for
// a due reservation or create, then converge teardown, Agents, NodePools and the
// worker summary. A missing pull secret, discovery ignition, disk image or
// instance type never starves retirement, cleanup, Agent binding, NodePool
// replicas or the summary: the prerequisite wait or error is merged into the
// final scheduling decision instead of returning early. A future retry deadline
// likewise contributes one bounded recheck rather than a global gate, and a
// stable order with no pending work relies on watches instead of a polling timer.
// Allocation planning starts from the authoritative order, not a cached parent.
// Finalizer addition, worker repair (including stale ignition), new reservations,
// a failed worker's retry Delete and each completed BMI create are return
// boundaries with a bounded requeue. A retry Delete error ends capacity work
// without changing its slot or attempting another action. Reservation persists all
// missing names without creating; a later invocation creates at most one BMI
// and persists its ID before returning. Other slots wait for a fresh invocation.
// A no-op reservation/status helper is not progress and does not force a requeue.
// A lost Create acknowledgement keeps the same reservation. A fresh invocation
// recovers by owned name or same-scope AlreadyExists; List omission is not absence.
// Name-based creation recovery rejects ambiguous, foreign and deleting candidates.
// Recorded deleting IDs and finalization recovery still remain observable.
// Finalization takes the identity-only recovery path in worker_teardown.go.
// Retry, scale-down and parent deletion share cleanup.go. Retirement intent is
// persisted before external cleanup. Cleanup reads the complete Agent namespace
// authoritatively, waits for owner-driven detach, deletes with UID/resourceVersion
// preconditions, and waits for Agent removal before requesting BMI deletion.
// Deleting metadata means wait; only BMI Get NotFound releases a recorded ID.
// Failed callers then initialize one retry checkpoint; retiring callers remove
// the exact slot. Unknown ID-less reservations recover by owned name or remain
// blocked, including during finalization. Bound-worker remediation is not owned
// here; archived-Cluster ownership lookup remains a production-deletion blocker.
//
// Resource operations are grouped by target:
//   - infraenv.go and image.go prepare discovery ignition and the disk image.
//   - bmi.go handles BMI lookup, creation, request construction and deletion.
//   - ownership.go validates authoritative tenant and resource identities.
//   - agent.go handles Agent convergence, binding and registration timeouts.
//   - correlation.go matches Agents to workers by binding or inventory MACs.
//   - nodepool.go converges requested NodeSet replica counts.
//
// Worker policy and persistence are grouped by lifecycle responsibility:
//   - worker_observation.go owns the single invocation-local resource snapshot:
//     it indexes scoped BMIs, memoizes recorded-ID fallback Gets (including
//     unknown results), and projects identity/phase once; agent_observation.go
//     interprets Agent snapshots. The snapshot is passed explicitly and is never
//     repaired after a mutation: a create, delete or bind ends the invocation and
//     the next one re-observes. No phase-projection or invalidation cache exists.
//   - worker_capacity.go reserves durable slots and fulfills their capacity.
//   - scaling.go selects retained/excess slots and initiates scale-down.
//   - retry.go handles failed workers, backoff and healthy-history reset.
//   - cleanup.go shares ownership-safe Agent/BMI cleanup evidence and actions.
//   - worker_teardown.go persists retirement, confirms cleanup and finalizes.
//   - worker_status.go owns one-shot optimistic status patches, conditions and
//     aggregates; a conflict abandons the invocation instead of merging stale
//     evidence into newer worker state.
//   - metrics.go owns metric registration and observations.
//
// The fulfillment.go, ignition.go and resolver.go adapters retain their existing
// boundaries. Tests are grouped by the behavior they exercise, with real API
// server/etcd persistence coverage in acceptance and shared doubles in fake.
// R03-E1–E5 drive public cleanup/retry/retirement with explicit completion and
// real Agent Delete preconditions; fulfillment and owner detach remain simulated.
// R02-E1/E2 drive public reconciles through real status and Agent binding
// conflicts: one rejected optimistic patch, no takeover, and a fresh invocation
// that respects the competing writer.
// R05-U1–U5 characterize the read budget, memoized fallback outcomes and
// independent per-order observation state; R05-E1–E3 drive public reconciles
// through real status persistence for interrupted binding recovery, demotion and
// protected history with blocked prerequisites, and no pre-bind Ready decision.
// R04-U1–U5 characterize prerequisite-free existing-worker progress, the
// ignition/image/instance-type input budget, shortest recheck-deadline selection,
// fairness across blocked and actionable workers, and error propagation;
// R04-E1–E3 drive public reconciles through real status persistence for
// retirement and cleanup with unavailable prerequisites, Agent binding past a
// pending retry, a summary written before the create gate, stale-ignition
// failure persistence with a blocked image, and bounded rechecks without
// delivered Agent/NodePool events.
// Sim-backed R03-C1 is explicitly skipped and its fixture removed; it is not a
// local completion gate. Unit/Envtest do not prove real fulfillment/provider
// cleanup or resolve the archived-Cluster and targeted-remediation gaps.
//
// Observation is not destructive authorization: List omission remains unknown
// until an authoritative Get confirms absence, and each BMI deletion performs
// a fresh ownership/existence check. Worker and Agent writes use one authoritative
// snapshot plus one optimistic patch; conflicts return to controller-runtime for
// a fresh invocation. Keep those boundaries explicit when adding helpers to any
// of these files.
package baremetalworker
