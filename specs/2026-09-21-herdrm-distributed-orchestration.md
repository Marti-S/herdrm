# HerdRM Distributed Specification Orchestration

**Document ID:** HRM-ORCH-001  
**Version:** 1.0  
**Date:** September 21, 2026  
**Status:** Implementation specification; not an implementation or acceptance report  
**Primary implementation repository:** `Marti-S/herdrm`  
**Integration repositories:** `Marti-S/PathWorkflow`, `Marti-S/atomic`  
**Suggested canonical repository path:** `specs/2026-09-21-herdrm-distributed-orchestration.md`

**Reading guide**

| Area | Sections |
|---|---|
| Product decisions and boundaries | [Scope and supersession](#1-scope-release-boundary-and-supersession) · [Invariants](#2-non-negotiable-invariants) · [Architecture](#3-architecture-and-component-ownership) |
| Records and state authority | [Identity](#4-identity-versioning-and-compatibility) · [Project layout](#5-canonical-state-and-project) · [Transactions](#6-persistence-and-transition-protocol) · [Data contracts](#7-source-contract-task-and-evidence-records) |
| Execution | [State machines](#8-state-machines-and-completion-predicates) · [Intake](#9-intake-subscriptions-and-amendments) · [Scheduling](#10-scheduling-leases-fencing-and-resource-limits) · [Atomic](#11-atomic-adapter-and-execution-lifecycle) · [Isolation](#12-workspaces-isolation-and-artifact-transport) |
| Delivery and integration | [Branches and PRs](#13-branches-internal-landing-and-pr-publication) · [Verification](#14-verification-independent-review-and-closeout) · [Effects](#15-external-effects-idempotency-and-uncertainty) · [Promotion](#16-promotion-and-merge-policy) |
| Product interfaces | [API](#17-service-and-wire-protocol) · [HerdRM UI](#18-events-projections-and-herdrm-ui) · [Security](#19-security-authorization-and-trust-boundaries) |
| Operations and rollout | [Deployment](#20-deployment-configuration-and-operational-limits) · [Migration](#21-migration-and-rollout) · [Recovery](#22-failure-and-recovery-contract) |
| Implementation and proof | [Work packages](#23-implementation-work-packages) · [Acceptance cases](#24-acceptance-catalogue) · [Demonstrations](#25-required-end-to-end-demonstrations) · [Completion](#26-definition-of-implementation-complete) |

## 0. Purpose and interpretation

Build a specification-driven delivery system into the HerdRM product, with an independently runnable supervisor service, distributed machine runners, native macOS/iOS controls, and Path/Atomic execution. Several milestones in the **same repository** must be able to implement concurrently on different computers. Parallel implementation must not permit competing authorities, duplicate acceptance, unsafe branch updates, or unapproved promotion.

**Operating principle:** HerdRM presents and controls; the supervisor coordinates resources and promotion; Path authorizes workflow transitions and verifies delivery; Atomic executes agent workflows; GitHub records and enforces remote collaboration facts; humans authorize protected promotion.

“MUST” and “MUST NOT” identify binding implementation requirements. “SHOULD” identifies a recommended behavior whose deviation must be documented with its tradeoff. Examples illustrate the proposed contracts and are not claims that these APIs already exist. Source observations in Appendix A are descriptive; the rest of this document defines the target.

This document incorporates the supplied Path refactor and explicitly amends its single-active-milestone restriction. It does not authorize deployment, publication, merging, repository protection changes, or destructive migration merely by being present on disk. Those effects require the operation permissions defined here. No tests or runtime demonstrations were executed to produce this specification.

### 0.1 Observed source baselines

| Repository | Inspected `main` commit | Use in this specification |
|---|---|---|
| `Marti-S/herdrm` | `f903dd3872e19c7266cfa5fd7a11a3acf6fe0c95` | Native feature boundaries, fleet ownership, shared packages, mobile bridge. |
| `Marti-S/PathWorkflow` | `fb634cbaa369c7be21e4db3b026128a0b79d7ad9` | Current single-host ownership, state/layout migration, gates, Atomic entry points and branch handling. |
| `Marti-S/atomic` | `b8c2b26b58d27d1abf67da7051fd85ce4ec9275e` | Runtime integration reference, particularly headless RPC. |

All three baselines were read on September 21, 2026. A repository commit is not an installed runtime version. Path's inspected contract names Atomic `0.9.19` as its supported installed version. Implementation must establish and test a compatibility manifest before using any API observed only on Atomic `main`. See Appendix A, R1–R7.

## 1. Scope, release boundary, and supersession

### 1.1 Required first production release

**REQ-01 — Product boundary.** Deliver native HerdRM project/milestone views and control, a separately supervised headless service, and machine runners. Quitting the GUI must not terminate the supervisor or accepted execution. No always-open terminal or chat session is required for orchestration.

**REQ-02 — Distributed concurrency.** Support at least two computers implementing two milestones concurrently in the same repository, multiple concurrent milestones on one machine, and existing parallel tasks within each milestone. Place each milestone's Atomic controller and implementation task children on one execution host in this release. Distributed milestone placement is mandatory; splitting one milestone's implementation children across hosts is not required for release 1.

**REQ-03 — End-to-end delivery.** Support source observation, explicit revision submission, definition, planning, implementation, independent verification, internal landing, PR publication, human-authorized shared-branch promotion, post-integration verification, and closeout. A workflow returning successfully is not a delivery predicate.

**REQ-04 — Refactor retention.** Preserve permanent milestone directories, separation of current knowledge/approved changes/evidence, optional domain guidance, lean scoped context, revision-checked helpers, recoverable migration, and evidence-backed closeout.

### 1.2 Explicit non-goals

Do not build a replacement coding-agent runtime, a general-purpose autonomous manager agent, an active-active coordinator cluster, offline multi-writer Path state, cross-repository atomic release transactions, unrestricted shell-over-HTTP, or automatic production deployment. Do not require a mandatory DDD taxonomy, move canonical product specifications into `.project/`, or create empty research/summary/evidence scaffolding.

Transparent live migration of an Atomic session between hosts and cross-host task children remain later capabilities. Recovery on a different host is a **new execution attempt** linked to prior accepted work, unless a separately certified same-run migration adapter exists. The first release must not advertise that later capability.

### 1.3 Superseded and retained obligations

| Earlier constraint | Target disposition |
|---|---|
| One active implementation milestone per project | Superseded by one authoritative controller per milestone and configurable project/repository concurrency. |
| One root state file owns the active milestone, its phase, and tasks | Superseded by a project registry plus milestone-local canonical state. |
| Local ownership files coordinate all execution | Retained for local exclusion only; supervisor assignments and fenced effects govern distributed ownership. |
| No local branch hierarchy in the earlier GitHub-first design | Superseded by task branches, a milestone integration branch, and a delivery PR to the target. |
| Path does not introduce a database | Retained: Path state remains journalled filesystem state. A **separate supervisor SQLite coordination store** is explicitly introduced outside `.project/`. |
| Atomic owns execution/checkpointing | Retained. Do not read or write Atomic's internal DB tables as the integration API. |
| Source submission is implementation intent | Retained for an authenticated submission of exact source bytes; ordinary edits are not submissions. |
| Release/merge privileges are separate from implementation intent | Retained and made explicit in the operation authorization model. |
| Historical acceptance definitions/evidence must be preserved | Retained; supersession changes obligations, never historical pass/fail results. |

Implementation must register this supersession in Path's contract revision mechanism before changing protected contracts. Suggested revision identity: `OCR-2026-09-21-herdrm-distributed-orchestration`. The historical case definitions must not be rewritten to make new behavior appear previously verified.

## 2. Non-negotiable invariants

**REQ-05 — Authority invariants.** Every component and acceptance test must preserve the following:

| ID | Invariant |
|---|---|
| INV-01 | Exactly one Path authority exists for a project/milestone state record in an installation. Local materializations and GUI caches cannot accept transitions. |
| INV-02 | At most one current controller assignment exists for a milestone; at most one owner exists for an attempt. |
| INV-03 | Each accepted attempt is bound to repository, milestone, contract digest, source revision, attempt identity, and ownership generation. |
| INV-04 | Event delivery may repeat; one logical command may commit at most one accepted transition. |
| INV-05 | A stale or disconnected worker cannot publish privileged effects or accept its own work. |
| INV-06 | External-effect uncertainty is preserved until reconciled; timeout does not mean failure and does not authorize blind retry. |
| INV-07 | Markdown, terminal status, model prose, and successful process exit cannot authorize execution or completion. |
| INV-08 | Tests and reviews are valid only for the subject they measured and the policy that admitted them. |
| INV-09 | Implementations can run concurrently; updates to each integration target have one serialized admission/effect lane. |
| INV-10 | A human approval cannot authorize a changed PR head, changed scope, another repository, or another target. |
| INV-11 | Permission revocation is checked at new effect admission. Accepted in-flight external requests may already have acted and must be reconciled, not described as undone. |
| INV-12 | Task workers cannot modify shared contracts, canonical execution state, verifier policy, or approval keys. |
| INV-13 | Project/milestone IDs are stable across machines, paths, branch changes, and repository renames. |
| INV-14 | Completion preserves accepted contracts, observed merge facts, evidence, and durable references; corrections supersede rather than overwrite. |
| INV-15 | One milestone failing, waiting for approval, or losing its host does not unnecessarily stop unrelated milestones. |
| INV-16 | No automated shared-target promotion runs with unknown or unsupported protection semantics. |
| INV-17 | No new deployment or destructive remote action is implied by a merge. |
| INV-18 | Recovery cannot turn historical unverified or retired-runtime evidence into current passing evidence. |

## 3. Architecture and component ownership

### 3.1 Deployment

One logical coordinator runs on one designated always-on host. It serves many native clients and many machine runners. The same computer may host a runner and coordinator, but their execution identities and credential access remain separated.

The coordinator is a separately managed OS service. It contains three distinct modules: supervisor coordination, a Path state host using Path's deterministic package, and an effect gateway. They may share one process in release 1, but must have explicit interfaces, separate persistence ownership, and independently testable behavior.

Atomic workflow controllers and workers run on execution machines through a runner-owned RPC adapter. HerdR remains a terminal/fleet facility, not the authoritative job scheduler. A headless attempt can be observed without a HerdR pane; terminal attachment is an optional link rather than proof of execution.

### 3.2 Proposed repository boundaries

```text
herdrm/
├── Packages/
│   └── OrchestrationKit/          # Swift models, API client, streams, signature integration
├── services/
│   ├── supervisor/               # Scheduling, intake, operations, projections, effect admission
│   └── runner/                   # Host capabilities, workspace lifecycle, Atomic RPC adapter
├── packages/
│   └── orchestration-protocol/   # Versioned JSON schemas and generated TypeScript bindings
├── Sources/HerdrM/
│   ├── Features/Projects/
│   ├── Features/Milestones/
│   ├── Features/IntegrationQueue/
│   └── Runtime/Orchestration/
├── Sources/<existing-iOS-target>/
│   └── ...                       # Equivalent feature/client integration, not another scheduler
└── specs/
    └── 2026-09-21-herdrm-distributed-orchestration.md

PathWorkflow/
├── .atomic/workflows/path-deliver.ts
└── tools/path/
    ├── control/                  # Typed observe/decide/apply/recover boundary
    ├── record/                   # Project registry, milestone state, journals, projections
    ├── shared/                   # Versioned resolver and containment
    ├── dispatch/                 # DAG readiness, local ownership, attempt/integration adapters
    ├── github/                   # Branch/PR/merge mechanics through admitted effects
    └── evidence/                 # Verification and acceptance reducers
```

Existing repository layout conventions take precedence for the exact iOS source directory; resolve it from the build configuration rather than creating the illustrative placeholder above.

**REQ-06 — Reuse without duplication.** HerdRM must depend on a pinned, packaged Path control/adapter artifact. Do not copy Path sources into HerdRM or translate its gates into Swift. Publish/install packaging is itself a permissioned release action. Development may use a checked local package link with its source digest recorded.

The existing HerdRM dependency direction and transport owners must be preserved. Add an `OrchestrationStore`; do not turn `FleetStore` into the scheduler. Existing bridge behavior must remain backward compatible. See R1–R2.

### 3.3 Responsibility table

| Component | Owns | Must not own |
|---|---|---|
| Native UI/client | Read models, user intent, signed approval requests, terminal links | Task acceptance or source-of-truth status |
| Supervisor | Subscriptions, assignments, capacity, operation ledger, queue order, notification delivery | An alternative task dependency graph or acceptance reducer |
| Path state host | Canonical state, admissible actions, contract revisions, evidence acceptance, closeout | Machine capacity or fabricated GitHub facts |
| Path delivery controller | Phase progression and task dispatch through Atomic | Unfenced remote publication |
| Runner | Host/process management, local durable launch correlation, sandboxing, artifacts | Scope changes, approvals, merge permission |
| Atomic | Agent execution, tracked stages/children/tools, checkpoints/resume | Project governance outside its declared workflow |
| Effect gateway | Fresh authorization and fencing plus execution of Path-produced effect requests | Reinterpretation of acceptance or approval intent |
| GitHub | Actual refs, PRs, reviews, checks, queue and merge state | Path milestone acceptance |

## 4. Identity, versioning, and compatibility

**REQ-07 — Identity.** Use opaque UUIDs for installation, project, milestone, task, attempt, runner, operation, artifact manifest, and approval identities. Human labels such as `M001` and `T001` are scoped display identifiers, not globally unique keys. The coordinator allocates milestone ordinals transactionally; they are never reused. A milestone's original directory slug is immutable even if its display title changes.

Repository identity is `(forgeHost, repositoryNodeId)` with owner/name retained as mutable display metadata. Forks are separate repositories. Several registered projects may use one repository, but target-branch coordination is keyed by repository identity, not project identity.

Resolve task identity as `(projectId, milestoneId, taskId)`. Resolve terminal attachments separately as `(fleetAuthorityId, deviceId, paneId)` and Atomic execution as `(runnerId, executionSessionId, atomicRunId)`.

### 4.1 Common wire types

```typescript
// Proposed wire conventions, not existing SDK declarations.
type UUID = string;
type Digest = string;              // sha256:<64 lowercase hexadecimal digits>
type Revision = string;            // nonnegative canonical decimal, no leading zero except "0"
type Timestamp = string;           // RFC 3339 UTC; informational unless server-owned deadline
interface RepositoryRef {
  forgeHost: string;
  repositoryNodeId: string;
  owner: string;
  name: string;
  objectFormat: "sha1" | "sha256";
}
interface GitSubject {
  repository: RepositoryRef;
  commitOid: string;
  treeOid: string;
}
interface OwnershipFence {
  coordinationEpoch: UUID;
  scope: "milestone" | "attempt" | "integration-target";
  scopeId: string;
  generation: Revision;
  assignmentId: UUID;
}
```

Every JSON schema must specify required fields, closed enums, size bounds, formats, unknown-field behavior, and nullability. Monotonic counters are decimal strings to avoid cross-language integer precision loss. Git object IDs are validated against the negotiated repository object format; unsupported formats block before a mutation.

**REQ-08 — Independent versions.** Keep protocol major version, Path layout version, state schema version, contract revision/digest, source Git revision, and coordinator epoch distinct. The new Path layout is version `3`; project and milestone record schemas begin at version `1`. Discovery must use an explicit validated marker plus conflict checks, not simply the presence of a Markdown file.

A compatibility manifest must pin supervisor, runner, Path package, Atomic executable/version/digest, host/architecture, protocol, schema, layout, model policy, and verifier policy versions. Unknown runtime combinations cannot execute automatically. Older clients may remain read-only if their decoding is compatible; unsupported mutation schemas are rejected.

## 5. Canonical state and `.project/`

### 5.1 Target logical layout

```text
.project/
├── PROJECT.md
├── ROADMAP.md
├── STATE.md                         # Generated aggregate; no execution authority
├── state.json                       # Project registry; no duplicated task lifecycle
├── codebase/
│   ├── ARCHITECTURE.md
│   ├── DEVELOPMENT.md
│   ├── VERIFICATION.md
│   ├── LANGUAGE.md                  # Optional index, not duplicate definitions
│   └── topics/<topic>.md
├── decisions/<decision>.md          # Optional; existing canonical records may be referenced
└── milestones/
    └── M001-<original-slug>/
        ├── state.json              # Canonical milestone execution state
        ├── CONTEXT.md
        ├── PLAN.md
        ├── RESEARCH.md              # Optional, only when content exists
        ├── SUMMARY.md               # Created for a recorded outcome
        ├── tasks/                  # Optional alternative to inline task contracts
        └── evidence/               # Immutable receipts/manifests and durable output references
```

**REQ-09 — State split.** Root `state.json` owns project identity, layout/schema markers, registry revision, source registry references, and milestone identity/path references. It does not maintain a second copy of milestone phases, task status, approvals, or live host heartbeats. Root `STATE.md` is rebuilt from milestone records plus explicitly labelled observations.

Each milestone `state.json` owns its phase, lifecycle, accepted source and contract revisions, task lifecycle, blockers, accepted evidence references, branch/PR binding, integration receipts, and completion record. It may reference the current assignment, but the supervisor assignment store owns whether that assignment is live. Task status must not also be maintained in Markdown frontmatter.

A milestone record must include at least:

```typescript
interface MilestoneState {
  kind: "path/milestone-state";
  schemaVersion: 1;
  layoutVersion: 3;
  projectId: UUID;
  milestoneId: UUID;
  ordinal: number;
  directory: string;
  revision: Revision;
  phase: "definition" | "planning" | "implementation" | "verification" | "integration" | "closeout";
  lifecycle: "draft" | "ready" | "running" | "waiting" | "blocked" | "paused" | "completed" | "cancelled" | "superseded";
  sourceRevisionId: UUID;
  contractRevision: Revision;
  contractDigest: Digest | null;
  documentManifestRef: UUID;
  taskIndexRef: UUID | null;
  taskStates: Record<string, TaskLifecycleRecord>;
  blockers: BlockerRecord[];
  branchBinding: BranchBinding | null;
  acceptedEvidence: EvidenceReference[];
  integrationReceipt: UUID | null;
  completionReceipt: UUID | null;
  lastTransitionId: UUID;
}
```

`TaskLifecycleRecord`, `BlockerRecord`, `BranchBinding`, and evidence records are specified in Sections 7–8 and 13–16. Implementers must generate concrete JSON schemas; unresolved illustrative type names are not an acceptable shipped protocol.

### 5.2 Where canonical bytes live

**REQ-10 — One authority, many materializations.** In distributed mode, the Path state host owns canonical mutable records in a protected control workspace:

```text
<supervisor-state-root>/
├── coordination.sqlite
├── projects/<projectId>/.project/
├── path-journals/<projectId>/<milestoneId>/
├── objects/sha256/<digest>/
├── effects/<operationId>/
└── backups/<backupId>/
```

Private runtime journals may live outside the human documentation tree. The single path resolver must resolve those locations as well as public artifacts. Workers receive read-only contract/state materializations and attempt-local output directories; they never mount the authoritative store writable.

A standalone Path project may use local canonical files with a local adapter. A project enrolled in distributed mode must declare its remote authority. Offline copies of that project refuse mutations rather than falling back to local mode. Changing authority requires the migration/transfer protocol, not editing an endpoint string.

### 5.3 Git and metadata policy

Canonical product specifications remain at their authored location. Preserve immutable intake snapshots in the artifact store; `.project/` references them.

Operational metadata must not generate competing implementation-branch edits. The first release uses a dedicated `path-control/<projectKey>` Git branch as an append-only history mirror of accepted metadata snapshots. This branch is **not** the live state authority. Its publication may lag and must display that lag. Only the gateway writes it, using expected-ref updates; unrelated or conflicting remote heads block mirror publication without rolling back accepted Path transitions.

`PROJECT.md`, `ROADMAP.md`, and milestone contract/history snapshots are mirrored there. `codebase/` remains authored with the corresponding implementation on source branches. Document manifests bind each source document to its exact Git subject or immutable artifact. The logical `.project/` view composes these locations through the resolver; it must never label a composite view as one Git commit.

Live heartbeats, lease renewals, and runner telemetry remain outside Git. Task source commits exclude materialized operational state. Codebase documentation updates travel with the source change, while operational contract changes go through Path revision commands. Existing tracked operational files are preserved during migration and dispositioned explicitly.

### 5.4 Codebase and domain knowledge

**REQ-11 — Knowledge semantics.** Preserve the supplied refactor's distinction between logical responsibility and physical implementation. Document shared/independent implementations, language wrappers, authored generator inputs, generated outputs, prerequisites, build scopes, verification scopes and limitations. A package is not automatically a bounded context.

Definitions belong in their owning topic. Optional `LANGUAGE.md` indexes rather than duplicates them. Record meaning/scope, distinctions, relationships/permitted operations, ownership, and implementation/verification references. Mark approved requirements, observed behavior, and proposed meanings distinctly.

Workers receive only assigned contracts, relevant topic sections and distinctions, and source/test references. Documentation guides but never replaces source inspection. Concurrent milestones may carry branch-specific knowledge changes; HerdRM must show which branch/revision the user is reading. Conflicting meanings or requirements produce a material question, not silent reconciliation.

## 6. Persistence and transition protocol

**REQ-12 — Supervisor persistence.** Release 1 uses one local SQLite coordination database with WAL mode, foreign keys enabled, full synchronous durability, migrations, and bounded write transactions. Pin and test the SQLite binding/version. Do not put this database on a shared/network filesystem. WAL's same-host restriction is documented by SQLite; remote runners access APIs, not database files. See R11.

Persist at least `installations`, `principals`, `enrollments`, `projects`, `source_subscriptions`, `deliveries`, `submissions`, `runners`, `assignments`, `capacity_reservations`, `operations`, `effect_intents`, `approval_requests`, `integration_queue`, `event_log`, `notification_outbox`, and projection cursors. Projection tables may cache Path state but may not become another acceptance authority.

### 6.1 Path transition commit point

**REQ-13 — Journalled state mutation.** A Path transition follows this protocol under the milestone mutation lock:

1. Authenticate the caller and authorize access to this operation scope, then look up `operationId` before testing the expected revision. An already committed operation with the same canonical request digest returns its original result; different content under the same ID is a conflict.
2. Check authenticated principal, installation epoch, live assignment/fence where applicable, expected milestone revision, source/contract binding, and required evidence/policy.
3. Write referenced immutable artifacts and `fsync` them before their admission. Verify stored digests and durability; temporary uploads are not accepted evidence.
4. Append and durably flush a prepared transition record containing previous revision/digest, requested action, subject/evidence references, full next-state digest and a durably stored immutable next-state object reference, and operation ID.
5. Write and `fsync` the next state to a temporary file in the same filesystem; atomically replace `state.json`; `fsync` its parent directory. **The durable publication of the next state is the transition commit point.**
6. Append/flush a committed record with the replayable result and event payload. If this append is interrupted, recovery compares the state/last-transition identity with the prepared record and completes the journal deterministically.
7. Emit the committed event through the recoverable event outbox. Generate Markdown views afterward.

Before state publication begins, a failure leaves the previous accepted state. A crash during replacement/directory-flush is indeterminate until recovery validates the persisted old or new state against the prepared immutable state object; the service must not acknowledge a commit before its durability barrier. Once publication is durably established, a later failure must never cause an automatic rollback. Recovery must detect torn or corrupt journals, verify their valid prefix and referenced state, and block ambiguity. Projection or event-delivery failure becomes repairable pending work, not a failed accepted transition.

Root registry transitions use an equivalent root lock/journal. Operations touching several milestones acquire locks in stable UUID order and publish a recoverable operation manifest; they do not pretend several file renames are one filesystem transaction. No dependent execution is admitted until the operation's published manifest and required records agree.

### 6.2 Crossing SQLite and Path state

There is no implicit atomic transaction across SQLite and the filesystem. Use a recoverable operation protocol: persist the supervisor operation; call Path with the same ID; reconcile Path's committed operation result; then persist the supervisor result and projection event. Recovery queries Path by operation ID before reissuing anything.

Ownership changes and Path mutation admission pass through the same per-milestone service gate. A lease may not be superseded between final admission and a Path state commit. Do not hold a database transaction while waiting for a model or network response.

### 6.3 Coordinator exclusivity and restore

Release 1 has one coordinator host, enforced by a host process lock plus the configured state-root ownership. It has **no automatic cross-host coordinator failover**. A cloned state directory must not be started as another live installation.

Every backup restore or authority transfer rotates `coordinationEpoch`, reenrolls/revokes affected credentials as required, and reconciles outstanding external effects before new admission. Counters from an older restored database cannot make old tokens valid in the new epoch. Application restart on the same intact store retains the epoch, invalidates prior live leases until runners reconcile, and does not reset durable counters.

## 7. Source, contract, task, and evidence records

### 7.1 Source and submission

**REQ-14 — Immutable source identity.** A `SourceRevision` contains `sourceRevisionId`, `projectId`, source kind, canonical source URI, origin-specific revision, original-byte digest, immutable snapshot reference, author/provenance metadata, observation time, and referenced source spans. Required adapters are GitHub issue, GitHub repository file/directory at a commit, local runner file/directory, and raw text submitted through the API. Additional document providers implement the same boundary later.

For directories, hash a deterministic manifest of normalized relative paths, entry type, file mode where relevant, byte length, and content digest. Reject traversal, unsupported links, unreadable entries, and changing files during capture. Preserve original bytes; a text-normalization digest may be additional metadata but must not replace the original-byte digest. Downloading live referenced files later does not preserve the submitted source: required referenced inputs must also be snapshotted or pinned.

A `Submission` binds a source revision to project, milestone, submitting principal, selected target, policy revision, and submission operation ID. Deduplication uses both transport delivery identity and logical submission identity. Repeated events about an already submitted revision return the existing submission. An intentional repeat delivery requires a distinct milestone and explicit new-submission command; it cannot be inferred from another webhook.

### 7.2 Approved milestone contract

A milestone contract consists of scope and criteria in `CONTEXT.md` plus task contracts in either `PLAN.md` or `tasks/`, never both. It must identify objective, normative source requirement IDs/spans, exclusions, material assumptions, unresolved questions, relevant knowledge, integration target, and verification obligations.

Every acceptance criterion has a stable ID, normative statement, scope, verification method/receipt type, required environments, and whether it is mandatory. Optionality is established in the approved contract, not selected by the worker after a failing test.

**REQ-15 — Contract addressing.** Implement one deterministic parser for structured task/criterion blocks embedded in the Markdown. A recommended encoding is a fenced `path-task` block containing schema-validated JSON and a stable task ID. Prose may accompany the block; it must not redefine its fields. Existing Markdown formats require an explicit migration adapter. Parsing ambiguity blocks planning completion.

The compiler produces immutable, content-addressed machine contracts and a `contract-index` mapping IDs to file/section/source spans. The generated contracts bind to the authoritative document digest. They are not independently editable plans. The index and schema must support both inline and separate task-file representations with identical semantics.

### 7.3 Task contract schema

```typescript
interface TaskContract {
  kind: "path/task-contract";
  schemaVersion: 1;
  projectId: UUID;
  milestoneId: UUID;
  taskId: UUID;
  displayId: string;                  // e.g. T001, scoped to the milestone
  contractRevision: Revision;
  objective: string;
  sourceRequirementIds: string[];
  criterionIds: string[];
  dependencies: TaskDependency[];
  ownedPaths: string[];
  forbiddenPaths: string[];
  sharedInterfaceRefs: ArtifactSectionRef[];
  contextRefs: ArtifactSectionRef[];
  verification: VerificationObligation[];
  resourceClaims: ResourceClaim[];
  requiredCapabilities: CapabilityRequirement[];
  riskLabels: string[];
  reviewPolicy: "none" | "risk-based" | "always";
  repairBudget: number;
  outputRequirements: OutputRequirement[];
}
```

Dependencies identify task/milestone and a predicate: `accepted-landed`, `milestone-accepted`, or `approved-interface`. Task dependencies default to `accepted-landed`; an internal candidate that has not landed does not unblock its dependents. Milestone dependencies default to predecessor acceptance on the shared target. `approved-interface` permits explicit parallel implementation against a frozen interface, not adoption of arbitrary unmerged upstream source.

Verification obligations include a stable check ID, criterion IDs, executable adapter, fixed executable/argument template, source scope, environment requirements, time limit, expected result semantics, output requirements, and trusted verifier class. Shared-path or global-resource conflicts must become dependency/resource constraints. A syntactically valid acyclic task list is insufficient if shared-file/resource constraints introduce a cycle.

### 7.4 Attempts and subjects

An `AttemptRecord` binds task/contract, attempt number/UUID, predecessor attempt if any, milestone fence, attempt fence, assigned runner, runtime manifest, immutable base commit/tree, workspace identity, Atomic launch correlation/run identity, produced candidate commit/tree, and outcome/evidence references. Never reuse a completed attempt ID for new execution or a new source tree.

A `BranchBinding` contains repository identity, project branch namespace, task/milestone refs, target ref, observed expected OIDs, PR identity when known, merge profile, and provenance. A branch name alone is not a proof of source identity.

### 7.5 Verification and approval receipts

**REQ-16 — Evidence subject binding.** A verification receipt must include criterion/check IDs, contract revision/digest, source commit/tree, tested scope, verifier identity and policy digest, adapter/executable/arguments, environment manifest, start/end timestamps, exit/signal outcome, semantic result, durable output references/digests, and receipt identity/signature. Hashes do not prove a check ran; the trusted verifier must observe execution and issue the receipt.

Use `not-run`, `passed`, `failed`, `skipped`, and `inconclusive`. A skipped review is not a passed review. Missing or unknown required evidence blocks. A non-applicability ruling is a separate authorized receipt tied to the criterion and contract; it cannot be generated by changing a failed check to optional.

Human approval records bind approval identity, principal/device, exact candidate digest, head commit, target, contract revision, policy revision, evidence set, base policy, expiry, signing key, and signature. The server records verification and revocation separately. Section 16 defines promotion admission.

## 8. State machines and completion predicates

**REQ-17 — Typed outcomes.** Use independent milestone phase and lifecycle fields, not one overloaded status string. A blocker preserves the current phase and records code, structured subject, remediation category, related operation/evidence, and whether automatic retry is permitted. User-visible text is explanatory, never parsed to choose an action.

### 8.1 Milestone phases

| Phase | Entry requirements | Successful exit |
|---|---|---|
| Definition | Authenticated source revision selected; project valid | Stable criteria, exclusions, references, and no material unanswered question. |
| Planning | Definition contract ready | Parsed/validated task contracts; acyclic effective dependencies; complete verification mapping; bound contract digest. |
| Implementation | Submitted scope, executable plan, live assignment, resources | Required task candidates verified and accepted into the milestone branch. |
| Verification | Integrated milestone candidate available | Required milestone-level checks/review pass for the candidate; delivery evidence assembled. |
| Integration | Candidate and PR binding valid | Actual merge observed under allowed policy; any required integration checks satisfied. |
| Closeout | Required acceptance and merge facts available | Durable completion receipt and immutable outcome data; summary projection queued/generated. |

Allowed lifecycle transitions are `draft → ready → running`; `running ↔ waiting/blocked/paused` through admitted operations; and `running → completed/cancelled/superseded` where the corresponding predicates hold. Definition/planning may complete through deterministic fast paths. Starting a model is not mandatory when no work remains.

A phase transition may regress only through an explicit recovery/amendment/revalidation operation retaining history. `completed` is immutable: later defects or requirements create corrective/new milestones, or a superseding correction record explaining an erroneous historical claim. Do not silently reopen the same completed record.

### 8.2 Task and attempt lifecycle

Persist task states `pending`, `ready`, `running`, `candidate`, `verified`, `accepted-landed`, `blocked`, `cancelled`, or `superseded`. `ready` is recomputable from contract, dependency receipts, and current branch facts; capacity waiting does not mean the task is blocked by its implementation.

Persist attempt states `allocated`, `launching`, `running`, `candidate-received`, `verifying`, `passed`, `failed`, `interrupted`, `abandoned`, or `superseded`. A passed attempt is not necessarily an accepted-landed task. Path admits the landing receipt separately.

A task's accepted landing remains a historical fact when the milestone base changes. Its evidence validity for a new integrated candidate is evaluated separately; do not erase the original landing or silently mark the new tree verified.

### 8.3 Completion and non-completion

Milestone completion requires all mandatory criteria satisfied by admitted evidence, required tasks accepted-landed, no unresolved blocking contract questions, integration predicates satisfied, policy-required acceptance receipts present, and a durable completion record identifying the delivered revision and evidence manifest.

`SUMMARY.md` is a projection of that record and accepted outcome data. A rendering failure must not roll back completion; expose `projection-pending` and regenerate. Do not declare the overall implementation handoff/documentation gate satisfied until required projections are rendered and validated.

These are never completion predicates: agent `done`, successful RPC acknowledgement, Atomic root return, phase admissibility, file presence, a green unrelated CI run, closed PR without merge, or a summary claiming success.

## 9. Intake, subscriptions, and amendments

**REQ-18 — Watch without accidental submission.** A subscription specifies project, source locator, adapter, trigger policy, allowed submitters, target, and filters. Default behavior is `observe-only`. Local notifications are debounced and backed by periodic digest reconciliation; remote webhook events are backed by source reconciliation. Events awaken the controller; current state decides whether an action is needed.

Required GitHub webhook handling validates the raw-payload signature, event/action, repository binding, size limit, and delivery identity. Durably record or explicitly reject before acknowledgement. Replays return the recorded result. A webhook is not an authority to execute unless the configured submission policy authenticates the author and exact source revision. GitHub documents signature/HTTPS/delivery-ID practices; see R10.

An optional `submit-on-authorized-commit` policy may treat a commit to an approved source path/ref as submission. The service must resolve the immutable commit and authenticate the authorized submission condition. A worker-controlled `ready: true` field, label, comment, or ordinary file edit is not sufficient by itself.

Local paths refer to registered runner roots, not paths on the coordinator or phone. Snapshot locally, upload immutable bytes, and bind the submitted digest. Arbitrary network URLs, credential-bearing URLs, unbounded fetch recursion, and symlink escapes are refused.

### 9.1 Clarification

Material questions receive stable IDs tied to the source/contract revision. The UI displays the exact question and affected scope. Answers are authenticated and recorded as immutable material; they compose a new source revision, not an automatic approval. Submission of that revision is a distinct deliberate action unless the same explicit UI action clearly performs both and its signed command identifies both operations.

Do not ask for a new approval merely to rewrite an already complete specification. Material scope changes and privileged effects are the approval boundaries.

### 9.2 Revision arriving during execution

**REQ-19 — Controlled amendment.** An observed edit creates a candidate revision; the active contract remains pinned. Submitting an amendment starts an impact-assessment operation that classifies affected criteria, tasks, shared interfaces, evidence, and pending promotions.

Before activating a material amendment, pause new dispatch and promotion for affected work, quiesce or fence affected attempts, record the new revision, and invalidate affected approvals/evidence admissions. Conservative invalidation is required where impact cannot be established. A task that already produced valid unaffected evidence may be carried forward only through a new explicit revalidation receipt referencing the original evidence; never rewrite its original subject.

A clarification or amendment that cannot be applied safely remains a typed block. Cancelled or superseded work is retained; it is not deleted to simplify the dashboard.

## 10. Scheduling, leases, fencing, and resource limits

### 10.1 Scheduling ownership

**REQ-20 — Two scheduling levels, one DAG.** Path owns task readiness. The supervisor owns milestone placement and physical resource allocation. The supervisor may reject or defer a ready task for capacity/capability, but may not invent task dependencies, bypass a Path gate, or mark a task accepted.

For release 1, allocate a milestone controller to a runner and keep its implementation children on that runner. Obtain capacity reservations per active task so idle or approval-waiting milestones do not hold model slots. Enforce project/repository milestone limits, runner task limits, provider/model-pool limits, budgets, and exclusive resources. A waiting milestone consumes no implementation slot unless it actually has running work.

Scheduling defaults to fair round-robin among eligible projects/milestones; Path's critical-path priority orders tasks within a milestone. Explicit priorities may influence ordering but not gate validity. Persist scheduling decisions and reasons. Starvation tests must show eligible lower-priority work progresses when capacity is repeatedly available.

A runner advertises OS/architecture, available runtimes/toolchains, isolation capabilities, resource limits, repository checkout capability, model-pool availability, and version manifest. Advertised model presence is not proof of valid credentials or live provider access: admission includes the required probes. Credentials are not part of capability payloads.

### 10.2 Assignment protocol

**REQ-21 — Fenced assignments.** Allocate a durable assignment with a unique ID and increasing generation under `(projectId, milestoneId)`. Allocate attempt ownership separately. Every state-changing runner command and effect request carries the relevant milestone and attempt fences. A stale generation returns `STALE_FENCE`, preserving the submitted artifact only as quarantined, non-accepted evidence where policy allows.

Proposed configurable defaults are heartbeat every 15 seconds and lease duration 90 seconds. They are liveness settings, not correctness proofs. Server time governs leases; runners use a monotonic local deadline with a safety margin and may not extend authority from their own wall clock. On coordinator restart, leases require explicit reconciliation/renewal; a clock discontinuity fails closed until re-established.

Lease expiry stops new admission. By default, the runner requests cooperative pause of work and stops new child launches. Already-running local computation may finish into a quarantined result, but no publication, shared integration, or acceptance is possible without current authority. After a 30-second configurable stop grace, terminate the attempt process group unless a declared tool-specific safe-stop rule requires manual intervention. Destructive tools are not permitted in the ordinary implementation profile.

### 10.3 Reassignment and resource fencing

Never equate an unreachable runner with a stopped process. Reassignment fences the old owner and creates a new attempt/controller generation. Pure local computations can be duplicated after fencing because only the current generation may commit accepted results. Shared external-resource work cannot be reallocated until its prior effects are reconciled or the resource supports a tested fence.

Resource keys are explicit: repository interfaces, test databases, simulator pools, ports, generators, and deployment environments. Locks serialize only required shared effects, not all work in a repository. Cache artifacts are read-only or content-addressed; no writable shared `node_modules`, build cache, or `.git` directory across untrusted concurrent attempts.

### 10.4 Effect-boundary enforcement

All privileged effects pass through the gateway. It checks current epoch/generation, action permission, subject/contract, expected refs, required evidence, and applicable human approval immediately before dispatching an effect.

Ownership transfer and effect admission share a serialized scope gate. An admitted external request may already be in flight when its lease expires. Do not claim it was prevented: retain its effect slot and reconcile its result before admitting conflicting successor effects. An unknown outcome freezes the affected integration target or resource, not all unrelated milestones.

Remote model workers have no direct GitHub write/merge token and no canonical-state signing key. A fence enforced only in a prompt or an editable worker file does not meet this requirement.

## 11. Atomic adapter and execution lifecycle

**REQ-22 — Supported runtime integration.** Implement a persistent `atomic --mode rpc` adapter, using the pinned supported runtime. Launch, status, pause, resume, and quit are machine-facing operations. Do not scrape terminal output or ask a free-form manager model to execute controls.

Reuse the repository's existing RPC smoke harness where appropriate, but convert its helpers into tested production adapters rather than treating fixture smoke success as end-to-end acceptance. Atomic's documented JSONL protocol uses LF record delimiters; U+2028/U+2029 inside JSON strings must not split records. Implement incremental UTF-8 decoding, backpressure, correlated command IDs, and durable spooling. See R5–R7.

Atomic does not document a general RPC record size limit in the inspected reference. A runner may enforce a documented operational memory/disk bound, but exceeding it must produce an explicit resource-limit failure; do not truncate a valid event into a false success or claim full compatibility with arbitrarily large records.

### 11.1 Runtime adapter operations

The production adapter must provide `inspectCompatibility`, `launch`, `lookupByLaunchKey`, `inspectRun`, `pauseRun`, `resumeRun`, `quitRun`, and `collectRunArtifacts`. These are **new adapter contracts**, not assumed existing Atomic SDK methods.

Before spawning or asking Atomic to launch, the runner persists a unique launch key and assignment/operation mapping. It records the returned full Atomic run ID before reporting launch acknowledgement. When acknowledgement is lost, query runtime/runner state by launch key. If the supported Atomic runtime cannot recover a launch identity unambiguously, add a narrow runtime/extension correlation capability and test it; otherwise block `LAUNCH_OUTCOME_UNKNOWN`. Never start another controller blindly.

An RPC request acknowledgement means accepted/handled, not completed. The supervisor must separately observe run lifecycle, Path state, and accepted evidence. Durable `ctx.tool` replay helps reuse completed results, but does not replace external-effect reconciliation for a request that acted before its response was persisted.

### 11.2 Path delivery workflow

Implement a thin, discoverable `path-deliver` workflow that carries one milestone through admitted actions. Its required inputs are authority endpoint identity, project/milestone IDs, assignment/fence reference, selected source/contract revision, and run policy references. Secrets must be resolved through protected handles rather than string inputs copied into prompts.

The driver asks Path for the next typed action; fast-paths no-op phases; creates model stages for genuine reasoning/implementation; and invokes existing task children through `ctx.workflow` within the host. It stops or waits using typed outcomes. Each retry/iteration creates distinct stable work identity; never construct a cyclic graph or reopen an ancestor stage beneath its descendants.

Side effects owned by the workflow use Atomic's durable mechanisms plus gateway operation IDs. Fresh authorization reads must not be replayed as permanent permissions. Each new act after resume needs fresh admission, even when an earlier completed tool result is cached.

Outputs include execution disposition, milestone/state/contract revision, accepted operation references, blocker/wait reason, Atomic run IDs, and artifact manifest. Do not return generic `completed` for a phase that merely proved admissible. A declared but unimplemented action returns `CAPABILITY_UNAVAILABLE`.

### 11.3 Recovery and bounded work

**REQ-23 — Recovery without false resume.** Same-host resume reuses the existing Atomic run only when its identity/checkpoints, workspace, and policy are valid. Cross-host recovery starts a new attempt/controller generation from verified source and accepted Path state; retained evidence stays linked to its original run. Old run IDs are never reassigned to a different runtime history.

Use the existing Path role/model policy as a referenced versioned artifact. Never silently substitute a model, accept same-family review where independent review is required, or change the policy because capacity is unavailable.

Preserve the lean builder lifecycle: implementation, focused deterministic gate, conditional independent review, at most one targeted repair by default. Recreating a workflow or switching machines must not reset the repair budget. Infrastructure retries have a separate bounded budget, default three attempts, and cannot be used to hide repeated implementation failures. Raising a budget requires an explicit authorized operation.

Progress is measured through accepted state/artifacts and active tool observations, not token volume. A configured no-progress deadline yields a precise block or stop; it does not trigger an unbounded autonomous repair loop.

## 12. Workspaces, isolation, and artifact transport

**REQ-24 — Process-enforced isolation.** The runner service identity owns launch records and protected configuration; model/tool subprocesses run under an isolated execution identity that cannot modify the runner, supervisor state, policies, or credential material. A workspace owned by the same unrestricted UID as all protected files is not an isolation boundary. An Atomic working-directory setting or tool allowlist alone is also not proof of filesystem/process isolation. The adapter must enforce the certified execution identity for the actual model-invoked tools; any required narrow runtime hook must be implemented and verified rather than assumed available.

Release 1 must certify one macOS and one Linux isolation profile. The profile may use a VM/container where compatible, or a dedicated OS account with enforced filesystem/process/credential restrictions. Native Apple verification may require a Mac profile. Unsupported isolation is a typed capability failure, not a silent unsafe mode.

Worker capabilities include writes to the assigned source workspace and attempt output directory; read access to approved source/context; approved model endpoints; and bounded developer tools. Canonical contracts are read-only. Repository code executed by tests is untrusted relative to the runner/verifier service.

Prepare one repository/worktree identity per milestone and isolated task worktrees. Never check out two branches by changing one shared working directory. Record the immutable base commit/tree, worktree path identity, allowed roots, environment, installed dependencies, and resource assignments. Path's local isolation helpers must be adapted, not bypassed.

Import dependencies from declared package manifests/lockfiles. Treat hooks, generators, filters, submodules, and build scripts as potentially executable code. Managed Git fetch/import operations run with controlled configuration and hooks disabled unless explicitly required by a verified profile.

### 12.1 Source and result transfer

The gateway or trusted runner service supplies repository read access without exposing remote write credentials to workers. A worker produces a committed candidate and an artifact manifest. Transport Git objects using validated bundles/packs or a broker-managed internal store; validate object closure, repository identity, expected base, changed paths, and required signatures before importing into a trusted integration checkout.

Large artifacts use resumable uploads with digest/size validation and finalization. Partial uploads are not evidence. Reject path traversal, archive extraction escapes, symlinks into protected storage, and decompression bombs. Keep raw logs access-controlled; publish redacted receipts and durable references.

### 12.2 Cleanup

Cleanup runs only after evidence/result ingestion is durable, the attempt is quiescent, and retention policy allows removal. Cancellation does not discard uncollected work. Branch/worktree deletion is a journalled effect with identity and expected-ref checks. If a ref moved or a process remains live, stop cleanup and report the conflict.

## 13. Branches, internal landing, and PR publication

**REQ-25 — Path-managed Git lifecycle.** Path owns the mechanics and proof rules for branch creation, task commits, internal landing, base refresh, PR creation/update, and cleanup. The supervisor supplies placement/promotion decisions and the gateway supplies fenced authorization. There must not be an independent supervisor implementation of Path's Git acceptance logic.

### 13.1 Names and target topology

Allocate an immutable collision-checked `projectKey`, for example `p-7c8914d0e123`. Use:

```text
path-task/<projectKey>/M001/T001/a-<attemptUUID>  -> path/<projectKey>/M001 -> main
path-task/<projectKey>/M001/T002/a-<attemptUUID>  -> path/<projectKey>/M001
path-task/<projectKey>/M002/T001/a-<attemptUUID>  -> path/<projectKey>/M002 -> main
```

The target is configurable; `main` is illustrative. One delivery PR exists per active milestone/target binding. Task PRs are optional collaboration artifacts, not required by default. Project namespace prevents collisions when several projects share a repository. Existing branch names remain readable through migration mappings; never rename or delete an active remote branch without an explicit recoverable operation.

Task attempt refs are immutable once a candidate is sealed. Changes after review create another candidate/attempt identity with new evidence. A milestone integration ref is mutable only through its serialized landing lane and expected-OID updates. Remote writes run through the gateway. No worker may force-push a shared ref or delete another attempt's ref.

### 13.2 Internal landing

Path may automatically land a verified task into its milestone branch when the invocation/policy authorizes internal integration. Serialize per milestone branch, not per entire repository.

Before landing, verify task ownership, contract digest, base/dependency receipts, changed paths, candidate source identity, required focused checks, and required independent review. Construct an integration candidate against the current milestone head; execute applicable integration checks on that candidate; then advance the milestone ref with an expected-old-OID precondition and record the resulting commit/tree.

When the target ref moved, do not reuse evidence for a different candidate. Recompute the integration candidate and rerun affected checks. Text conflicts may receive bounded Path-authored repair; semantic uncertainty or an exhausted budget blocks. Accept the task's landing only after the ref effect is observed and its receipt admitted. Dependent tasks start from the accepted resulting revision, never simply because the worker exited.

### 13.3 Base refresh

Default base refresh merges the current shared target into the milestone integration branch through a new verified candidate, preserving provenance and avoiding routine history rewrites. Rebase is supported only through Path's explicit rebase/adoption proof and protected expected-ref operation. Either operation changes the candidate identity and invalidates prior candidate approvals.

Independent milestones may modify overlapping source files, but shared resources and interfaces require declared constraints. After another milestone is promoted, the remaining milestone must verify its resulting combined implementation. A conflict-free Git merge is not semantic verification.

### 13.4 PR publication

Publication needs a distinct grant, independent of implementation intent. Path prepares a PR containing milestone/source/contract identity, delivered changes, criteria/evidence links, verification limitations, current head/base, and known blockers. The gateway creates/updates it idempotently, with a hidden machine marker and a stored immutable PR node identity.

Before retrying an uncertain PR creation, search/read by repository, head, base, and operation marker. One match is reconciled; multiple matches are a conflict requiring resolution. Do not create another PR simply because the original response was lost. PR body edits cannot change authoritative scope, approval, or acceptance.

## 14. Verification, independent review, and closeout

**REQ-26 — Trusted verification.** The trusted verifier launches checks for a pinned subject, observes command/tool execution, stores durable output, and issues receipts outside the worker's writable area. Separate the verifier service from the process executing repository tests: test code cannot sign its own successful result or modify the verifier's policy/configuration.

The verifier must assert the tested source did not change during a check. Use an immutable/read-only source subject with build outputs elsewhere where possible; otherwise measure and reject unaccounted changes before issuing a receipt. Generators that intentionally change source create a new candidate and must be verified as such. Environment manifests identify OS/architecture, toolchain/runtime versions, dependency locks, relevant non-secret settings, resource isolation, and required external-service versions.

Receipts from model review identify actual reviewer/implementer/repair-author families and the reviewed candidate. When review is required, enforce independence from all implementation and repair authors. A model review is a finding source, not proof that commands ran. `reviewPolicy=none` records skipped-by-policy review without converting it to passed.

Required checks include criterion-specific tests plus applicable security, API/schema, migration, concurrency/recovery, cross-package, generator-output, and integration checks. Risk selection is deterministic from approved metadata and observed diff; worker claims that a change is low risk cannot disable required checks.

### 14.1 Evidence validity and carry-forward

Evidence binds a full source subject even when its check scope is narrow. Carry-forward to another revision requires a deterministic impact proof or a recorded authorized revalidation; it never rewrites the original receipt. Public-interface, concurrency, recovery, destructive-effect, and integrated-system changes default to fresh checks. Unknown impact means reverify.

CI observations must match repository, exact subject commit or merge-group identity, required check context, expected issuing app/workflow identity, and policy. Path treats required skipped/neutral/inconclusive outcomes according to its explicit obligation semantics; do not assume GitHub's mergeability status establishes every Path criterion. Pin verifier policy from a protected installation artifact, not an unreviewed PR change.

### 14.2 Post-integration and summary

After a merge, observe the actual merged commit and resulting tree. Validate required post-integration checks or the policy-permitted equivalence between the measured candidate and actual result. A squash/rebase result may have another commit identity; tree/provenance mapping must be explicit and verified.

Closeout creates an immutable completion receipt with source/contract, accepted criteria/task outcomes, integration facts, known limitations, and superseded records. Render `SUMMARY.md` from this outcome. Corrections append a superseding record. Later regressions create linked repair milestones, not silent revision of prior passing outputs.

## 15. External effects, idempotency, and uncertainty

**REQ-27 — Effect ledger.** Every branch push, PR mutation, queue operation, merge, metadata publication, cleanup, or external notification has a unique operation/effect ID and canonical request digest. Record `prepared`, `admitted`, `submitted`, `succeeded`, `rejected`, or `unknown`; a submitted request with a missing definitive outcome becomes `unknown` after recovery.

A request retry with the same operation ID and payload returns the original committed/admitted result or its current reconciliation status. Reusing the ID with different content returns `OPERATION_ID_CONFLICT`. End-to-end “exactly once” external execution is not promised. The required guarantee is deduplicated commands, at most one accepted local transition, and reconciliation of uncertain remote effects before retry or conflicting progression.

### 15.1 Gateway procedure

Prepare the effect durably; acquire its scope lane; reread current policy/permissions/ownership/evidence; record admission; dispatch the Path adapter request; persist the response; observe authoritative remote state where needed; admit the resulting Path receipt; publish the outcome. If any stage fails, keep the last certain stage and recover from it.

A gateway process must never run repository build/test code under its credential-bearing identity. Git operations importing untrusted objects use a hardened import worker; GitHub API credentials stay in the gateway transport process. Model processes cannot call arbitrary gateway endpoints.

### 15.2 Reconciliation rules

| Effect | How to reconcile an uncertain outcome |
|---|---|
| Branch update | Read the exact ref/OID and expected operation ancestry; matching result succeeds, different result conflicts, ambiguous history blocks. |
| PR creation/update | Read stored PR identity or unique marker/head/base match; compare intended fields without overwriting unrelated human edits. |
| Queue admission | Read native/local queue membership and expected head/candidate; do not enqueue again blindly. |
| Merge | Read PR merged state and actual merge identity, target ancestry and tree; adopt actual facts, then re-evaluate acceptance. |
| Metadata mirror | Read remote control ref and snapshot manifest; never make Git mirror failure roll back Path acceptance. |
| Worktree/branch cleanup | Verify process quiescence, ownership, exact ref identity and retained artifacts; absence can be a successful idempotent result. |

Reconciliation observations are versioned receipts. If an external service no longer retains an operation result, query durable entity state; if that is insufficient, keep `unknown` and require operator resolution rather than inventing success.

## 16. Promotion and merge policy

**REQ-28 — Three separate actions.** Internal task landing, milestone promotion to a shared target, and release/deployment are distinct permissions and receipts. Default policy permits verified internal landing after authorized implementation, requires human authorization for milestone promotion, and disables deployment.

### 16.1 Candidate approval

HerdRM obtains a server-prepared candidate approval request and displays repository, milestone, exact PR head, target/base, changes, evidence summary, limitations, and requested base policy. The user explicitly approves; the enrolled user-device key signs the canonical approval subject. Approval is not inferred from dismissing a notification, opening the PR, an agent's recommendation, or a mobile pairing token.

Approval records are immutable. Revocation is a separate operation. A new head/contract/evidence-policy subject invalidates the prior approval. The same person may be operator and authorizer in a personal installation, but model identities can never be merge authorizers.

Two base policies are defined:

* `fixed-base` is the default for the local queue. Approval identifies the observed base and candidate. A base change requires a new candidate evaluation and renewed approval. The service must not claim that GitHub's head-SHA parameter is an atomic base-SHA precondition.
* `queue-validated-forward` is available only with an explicitly authorized, certified native merge-queue profile. The user approves the exact PR head for forward integration into the named protected target, with fresh merge-group checks. Moving the base within that queue does not require another human click; changing the PR head, contract, target, or approval policy does.

These policies must be visibly distinct. A native queue does not retroactively expand a `fixed-base` approval.

### 16.2 Authorization is conjunctive

A promotion requires current Path candidate evidence, valid applicable human approval, current supervisor queue admission, current actor permissions, readable supported repository protections, required GitHub reviews/checks, and the expected head. A HerdRM approval is **not** a GitHub PR review unless an explicitly implemented user-authorized integration submits that review as the actual GitHub user. Do not bypass GitHub's required human reviews with a bot check.

All application-initiated merges use the one gateway lane keyed by `(forgeHost, repositoryNodeId, targetRef)`. Unrelated targets continue independently. A task/milestone worker cannot merge directly even if its run is otherwise authorized to publish.

### 16.3 Native merge-queue profile

Use GitHub's native queue when the repository supports it and the profile is certified. Verify availability rather than assuming it from a repository name or account plan. The documented availability is organization-scoped; personal-account repositories require another profile unless the service's actual capabilities change. GitHub Actions checks for the queue must handle `merge_group`, and evidence must bind the queued group's actual subject rather than only the original PR head. See R8.

Native queue admission transfers eventual scheduling to GitHub. Persist that ownership and observe queue removal, head updates, merge-group failure, cancellation, and final merge. After remote admission, local cancellation/revocation may race with an already executing merge; report and reconcile that uncertainty rather than claiming instantaneous revocation.

### 16.4 Supervisor-managed queue profile

For repositories without a native queue, implement a conservative queue:

1. Serialize the next candidate for the repository/target; verify effective protection/ruleset configuration and all supported obligations.
2. Read target and PR head. Refresh the milestone branch so its candidate contains the current target; verify the resulting tree and publish the exact head.
3. Run required checks for that candidate and collect any required GitHub reviews. Obtain a current `fixed-base` human approval.
4. Immediately before submission, re-read head/base, checks, reviews, permissions, and policy. Any change restarts the applicable candidate/approval process.
5. Merge through a certified Path GitHub adapter with the expected PR head OID and chosen merge method; never omit the head precondition.
6. Observe the actual merged subject and admit integration evidence; otherwise preserve failure/uncertainty.

GitHub's documented merge API checks the requested PR head SHA, not an expected target SHA. Strict required checks require the branch to be current with its base. Therefore, this queue requires effective server-side strict checks, no bypass by the merge identity, and target protections forbidding uncontrolled direct/force pushes. A local mutex alone does not provide protection against another GitHub user. See R9.

The adapter must demonstrate its candidate/protection semantics on a disposable repository, including an out-of-band target update between read and merge. If the API/protection combination cannot enforce the required subject, block automatic promotion and expose a manual GitHub handoff. Do not implement “read base, assume unchanged, merge” as equivalent to a base compare-and-swap.

Newer asynchronous GitHub merge endpoints may be used only after their acknowledgement, eventual-result, cancellation, retention, and expected-head semantics are certified. An HTTP 202 is never a merge receipt.

### 16.5 External merges and protection drift

A human may merge directly in GitHub. Record the actual merge, identify the actor and subject, and evaluate Path acceptance. Without a valid equivalent approval/policy receipt, mark `integrated-unaccepted` through an integration-phase blocker; do not falsify a human approval or erase the external fact.

Protection changes, unknown rulesets, missing check identities, unexpected head writes, and unauthorized target movement suspend new automatic promotion. They do not cancel already-running unrelated implementation. Recovery requires current observation and explicit policy reconciliation; stored old protection snapshots are not reusable permission.

## 17. Service and wire protocol

**REQ-29 — Typed control API.** Implement HTTPS JSON APIs with certificate-authenticated clients/runners and a versioned schema contract. Native clients must not send shell strings or filesystem mutations as orchestration commands. Endpoint names below are target interfaces.

### 17.1 Read and command endpoints

| Endpoint | Required behavior |
|---|---|
| `GET /v1/capabilities` | Protocol/version, supported actions, compatibility, feature flags; no credentials. |
| `GET /v1/projects` | Authorized project registry with projection freshness and pagination. |
| `GET /v1/projects/{id}/snapshot` | Consistent projection snapshot, cursor/epoch, milestone summaries and component revisions. |
| `GET /v1/projects/{id}/milestones/{mid}` | Milestone contract/state view, attempts, evidence/PR references, admissible UI actions. |
| `GET /v1/documents/{manifestId}/{documentId}` | Immutable revision-bound document; ETag/digest and source provenance. |
| `GET /v1/operations/{operationId}` | Durable command/effect result including unknown outcomes. |
| `GET /v1/events?after={cursor}` | Authorized server-sent events with replay/resnapshot protocol. |
| `POST /v1/commands` | Authenticate, validate, deduplicate, durably accept, and return operation identity. |
| `POST /v1/approval-requests` | Construct exact server-side approval subject and short-lived signing challenge. |
| `POST /v1/artifact-uploads` | Allocate scoped bounded upload; chunks/finalize use its capability, never arbitrary paths. |

A command acknowledgement returns `202` plus operation ID and current disposition. Replayed known results may return `200`. State conflict/stale subject returns `409`; invalid schema `400`; unsupported protocol `426`; authentication failure `401`; authorization failure `403`; resource limits `429` or typed `409` as appropriate. Admission never reports completion merely because work was queued.

```typescript
interface CommandEnvelope {
  protocol: "herdrm/orchestration/v1";
  operationId: UUID;
  clientId: UUID;
  projectId: UUID;
  milestoneId?: UUID;
  expectedRevision?: Revision;
  expectedContractDigest?: Digest;
  fence?: OwnershipFence;
  action: string;                     // schema is a closed discriminated union
  payload: unknown;                   // validated by the action-specific schema
}
```

Authenticated actor identity comes from the connection/enrollment and verified signature, not an arbitrary `actor` field. For each action, the schema must make the relevant revision/fence mandatory; optional syntax in this illustrative common envelope does not make admission checks optional.

### 17.2 Required command actions

| Action | Mandatory subject/payload | Minimum authorization |
|---|---|---|
| `source.observe` | Subscription/source locator and snapshot identity | Registered observer/runner scope |
| `source.submit` | Exact source revision/digest, milestone or allocate-new request, target, policy | Submitter |
| `milestone.start` | Milestone revision/contract, execution policy, placement constraint | Operator |
| `milestone.pause` / `milestone.cancel` | Current milestone/run subject and reason | Operator |
| `milestone.resume` | Current revision, reconciled run/attempt identity | Operator |
| `clarification.answer` | Question IDs, source revision, immutable answer artifact | Submitter for that project |
| `contract.amend` | Prior contract, proposed source/contract, impact disposition | Submitter; material approvals as policy requires |
| `attempt.report` | Assignment/attempt fence, source subject, candidate and artifact manifest | Assigned runner only |
| `attempt.recover` | Prior attempt, recovery classification, destination constraints | Operator or bounded recovery policy |
| `budget.extend` | Budget scope, current limit, new limit, rationale | Operator with budget permission |
| `promotion.approve` | Approval challenge, exact subject, user signature | Merge authorizer |
| `promotion.revoke` | Approval identity and reason | Issuer or authorized administrator |
| `promotion.enqueue` / `promotion.dequeue` | Candidate/head/target, applicable approval, queue revision | Operator with promotion permission |
| `migration.preview` / `migration.apply` | Project/layouts, inventory/preview digest for apply | Administrator; apply requires explicit permission |

Project/runner registration, role changes, protection-profile changes, key rotation, and authority transfer are administrative APIs or CLI commands, never model-facing actions. Policy changes use versioned compare-and-swap and audit receipts.

### 17.3 Runner protocol

A runner initiates an authenticated outbound connection; the coordinator need not hold SSH private keys or inbound access to every machine. Required operations are enrollment/capabilities, heartbeat, assignment poll/acknowledge, attempt start/inspect/pause/quit, result/artifact submission, and reconciliation. Messages bind runner ID, runner boot identity, assignment and operation ID, and current epoch/fence.

A runner maintains a local durable mapping before invoking Atomic. Redelivered assignments return the same local operation/run identity. If that identity cannot be established, it returns an unknown-outcome block rather than launching again. Reconnection requires a state handshake, not replay of every cached start message.

Existing HerdRM SSH/Tailscale facilities may assist initial installation and terminal access under explicit user permission. They are not the job authority and must not be copied into the runner as shared application credentials.

### 17.4 Path control port

The Path package must expose typed `observe`, `decideNextAction`, `applyTransition`, `lookupOperation`, `admitEvidence`, and `recover` operations through local/remote adapters. `decideNextAction` returns one of `execute`, `wait`, `blocked`, or `complete`, with typed action/subject/prerequisites. It never grants permanent permission; effect/transition admission rechecks current state.

The Swift package consumes JSON schemas and shared golden fixtures. Generate models when practical; any hand-maintained bindings must pass cross-language round-trip tests. Swift must not parse a free-text `next_action` string into executable behavior.

## 18. Events, projections, and HerdRM UI

**REQ-30 — Durable event projection.** Events carry event ID, durable cursor, projection epoch, project/milestone/operation identity, event type, subject revision, timestamp, and typed data. Delivery is at least once; clients deduplicate. The durable event log and projections are updated transactionally inside SQLite after importing a committed Path event.

The projected snapshot is a consistent read of the projection store, not a claim of a global transaction across Atomic, GitHub, and Path. It includes per-component observed revisions/times and stale/unknown markers. A Path state update may precede its UI projection; commands are admitted against current authority and return conflict when a stale UI acts.

SSE cursor gaps or expired retention return `RESNAPSHOT_REQUIRED`. Snapshots bind immutable document manifests; never combine a new plan with an old state under one unlabeled revision. Reconnection restores a full snapshot and resumes from its cursor. Ignore out-of-order stale updates within an epoch; a new epoch requires resnapshot and disables cached approvals/actions.

### 18.1 Native screens

**REQ-31 — Native project control.** Implement:

* **Projects:** repository/project identity, source subscriptions, milestone counts, active machines, blocking attention, freshness.
* **Milestones:** scope/context, task plan and dependencies, assigned machine, accepted versus active work, branch/PR state, evidence/limitations, and history.
* **Integration queue:** per-target order, candidate head/base, protection/check/approval state, stale candidate warnings, approve/revoke/enqueue/dequeue actions.
* **Attempt details:** current runner/runtime, live status, source subject, logs/artifacts, interruption/recovery lineage, and optional terminal connection.

Keep existing Fleet navigation. Fleet asks what a machine runs; Projects asks what happened to a submitted specification. A project may appear on several machines but appears once in project navigation. A milestone is not duplicated per terminal. Progress must distinguish verified tasks, accepted-landed tasks, and final criteria; avoid one misleading percentage that counts a worker's exit as delivery.

### 18.2 Markdown and live status

Render Markdown from immutable manifest references with source branch/commit and contract revision visible. Disable active HTML/scripts and automatic credential-bearing/external resource loads. Relative references resolve within approved document/source roots; raw paths from a document cannot fetch arbitrary local/remote files.

Live status comes from Path/Supervisor/Atomic/GitHub projections with provenance. A disconnected runner displays last-known status and observation age, not an invented current `running` or `done`. Markdown-only import remains read-only and explicitly unverified until the project is enrolled and its state/evidence validated.

Buttons use server-advertised admissible actions for presentation and still pass server admission. Approvals require the fresh server subject; no background/offline cached approval can be silently submitted after reconnection. Double-clicks reuse the same operation ID.

### 18.3 Fleet and mobile integration

Keep `OrchestrationStore` independent of `FleetStore`, with a typed mapping to existing pane/device references. Do not infer Atomic run IDs from terminal names. Headless executions can expose logs even with no PTY. Reuse existing terminal attach capabilities only when the runtime provides a valid attach target; do not claim that arbitrary RPC stages have a terminal.

macOS and iOS clients connect directly to the supervisor. The existing Mac bridge may proxy authorized orchestration operations, but is not required for execution or project visibility when the Mac app quits. Do not give the existing bridge token implicit merge privilege. Protocol additions require capability negotiation and regression tests for older bridge clients.

### 18.4 Notifications

Create durable, deduplicated attention events for material clarification, verification block, host-loss recovery, promotion-ready, approval invalidation, integration failure, and accepted completion. Deduplicate by subject revision/occurrence, not message text. Notification delivery failure must not change workflow state.

Release 1 requires in-app notifications and macOS local notifications while the client is running. iOS must show persisted attention on reconnection/foreground entry. Background iOS push delivery requires a separately configured APNs integration and is not implied by an SSE connection. Notifications contain no secrets or complete private logs by default.

## 19. Security, authorization, and trust boundaries

**REQ-32 — Separate human, service, and worker authority.** Enrollment creates distinct user-device, runner, verifier, and gateway identities. Existing HerdRM pairing, SSH access, model credentials, and GitHub credentials do not automatically grant each other's privileges.

Use TLS for every non-local API connection, with certificate-authenticated clients/runners and explicit enrollment/revocation. Initial enrollment requires a short-lived, one-use administrator token delivered through an already trusted channel. Bind the resulting public key to installation, principal, device, allowed projects, and role. Store native private keys in the platform Keychain; do not assume every signing algorithm is hardware-backed. Store server/gateway keys in protected service storage. Secrets never appear in Markdown, logs, command-line arguments, environment manifests, or fleet snapshots.

User approvals additionally use a fresh server challenge and canonical signed payload, with a default five-minute challenge lifetime and single-use nonce. A signed approval's default validity is 30 minutes, configurable by project policy. The server validates current user role and key revocation, not only cryptographic validity. Record both the person authorizing an operation and the service executing it. Do not attribute a bot merge to a human GitHub identity that did not perform it.

### 19.1 Roles and permissions

| Role | Allowed responsibilities |
|---|---|
| Viewer | Read authorized project/state/document/evidence summaries. |
| Submitter | Submit exact source revisions and answer/amend authorized project contracts. |
| Operator | Start, pause, cancel, reconcile, place work, manage permitted budgets and queue requests. |
| Merge authorizer | Sign/revoke promotion approval for assigned repositories/targets. |
| Administrator | Enrollment, roles, configuration, migration, authority transfer, protected policy changes. |
| Runner service | Claim/execute/report only assigned work and upload its scoped artifacts. |
| Verifier service | Run admitted checks and sign observed evidence for exact subjects. |
| Gateway | Execute narrowly admitted privileged effects; cannot create human approvals. |

Every action combines role, project/repository/target scope, current policy, command subject, and current fence as applicable. Publishing and merging remain separate capabilities even when a GitHub token's underlying permissions are broader. Protected administrative actions require fresh authorization and audit; no self-upgrading runner role exists.

### 19.2 Threat model

Defend against compromised model output, malicious repository files/tests, prompt injection from specs/comments/documents, replayed events/commands, stolen obsolete assignment tokens, delayed/out-of-order responses, duplicate coordinator starts, stale approvals, and untrusted artifact paths. Treat source content as data and requirements, never as permission to change service policy or reveal secrets.

An administrator with root access to the coordinator/runner host or control of the trusted verifier installation can violate the trust boundary; do not claim cryptographic protection against a compromised root of trust. Document that assumption and provide signed provenance, restricted accounts, secret separation, and audit visibility to reduce exposure.

Model context follows explicit provider/privacy policy: send only the scoped necessary documents and source. A fallback provider cannot receive private content unless the policy permits it. Redact secrets in log projections and notifications while retaining protected raw outputs when required for evidence.

Changes to supervisor, runner, Path gates, verifier policy, credentials, CI policy, or approval code are high risk. The running controller/verifier must remain pinned outside worker-writable code while implementing its own replacement. Promote a new control binary only after independent verification, compatibility tests, and an authorized version change. Never hot-reload candidate gate code into the process judging that candidate.

## 20. Deployment, configuration, and operational limits

**REQ-33 — Independent service lifecycle.** Deliver macOS and Linux supervisor/runner packages with documented installation, startup, health, stop, upgrade, and uninstall behavior. Support platform service managers rather than tying lifecycle to a GUI or terminal. A local development command is useful but is not proof of production service persistence.

The coordinator may run on a Mac or Linux host; Apple-specific checks are routed to a certified Mac runner. The iOS application is a client, never a coordinator/worker host. Initial service setup must not copy desktop SSH credentials or enable system services without operator authorization.

A proposed non-secret configuration shape is:

```yaml
schemaVersion: 1
installation:
  mode: single-coordinator
  stateRoot: /var/lib/herdrm-orchestration
  listen: 127.0.0.1:45984
  tlsIdentityRef: service-identity
execution:
  maxConcurrentMilestonesPerRepository: 2
  defaultMaxParallelTasksPerMilestone: 4
  heartbeatSeconds: 15
  leaseSeconds: 90
  stopGraceSeconds: 30
  infrastructureAttempts: 3
  targetedRepairsPerTask: 1
  requireDurableAtomic: true
  requireCertifiedIsolation: true
promotion:
  defaultMode: human-approved
  queueMode: auto-certified
  defaultBasePolicy: fixed-base
  approvalLifetimeMinutes: 30
  allowDeployment: false
retention:
  transientWorkerDays: 7
  rawUnacceptedLogDays: 30
  eventReplayDays: 30
  acceptedEvidence: preserve
```

Paths and limits are illustrative installation defaults, not required platform paths. Host/network exposure changes require explicit configuration. Remote clients use a protected network route and TLS; a tailnet does not replace application authorization. Do not expose raw Atomic RPC or arbitrary HerdR socket proxying publicly.

### 20.1 Compatibility and health

Health must distinguish process liveness, canonical store readiness, durable Atomic backend availability, event backlog, runner reachability, artifact storage, GitHub access/protection readability, and degraded promotion. A healthy HTTP listener is not proof that delivery is runnable.

Distributed mode requires the certified durable Atomic backend. This specification adds no replacement runtime database; Atomic retains its supported DBOS/Postgres arrangement. No automatic fallback to non-durable execution is allowed for accepted distributed milestones. Installation/bootstrap must probe the actual supported runtime rather than infer availability from a package file.

Pin Node/runtime dependencies, GitHub API version, schema generator, and SQLite binding in the delivered lock/compatibility manifests. Do not use “latest” in reproducibility-critical execution configuration. Atomic updates are separate compatibility promotions, not an incidental global reinstall.

### 20.2 Performance and resource acceptance targets

These are proposed test targets, not measured claims: on a documented reference installation with 20 registered runners, 100 milestones, and 1,000 task summaries, warm project snapshots should return within two seconds at p95, and an accepted local Path event should appear in an already-connected UI within two seconds at p95. Measure network latency separately; GitHub/model execution is outside those local targets.

Use bounded log buffers, disk spooling, paginated history, digest-keyed document caches, and semantic snapshot coalescing. Idle clients must not trigger continuous full Markdown parsing or terminal attachment creation. Keep existing fleet/terminal cache behavior bounded. Fail explicitly on disk-full or resource exhaustion; never drop required evidence and still accept work.

Enforce budget ceilings across all retries, resumes, and hosts for a milestone. Track actual measured usage where available and label estimates. Unavailable usage measurement must not be replaced by fabricated cost. A configured hard budget that cannot be enforced blocks additional admission.

### 20.3 Backups, restore, and retention

Back up a consistent coordination snapshot, Path state/journals, referenced content-addressed artifacts, event cursors, and a manifest of immutable software/policy identities. Quiesce new mutation/effect admission during the backup cut, flush journals, and use a tested SQLite backup/checkpoint procedure. Record the cut and any already-submitted remote effects. Backing up a live database file while omitting required WAL data is not accepted backup behavior.

Restore into a new coordination epoch. Reconcile all bound remote branches, PRs, queues, and control refs, not only operations listed as pending in the older backup. A remote effect may have occurred after the backup and be absent locally. Audit gaps remain explicit and block affected automatic promotion until resolved.

Accepted evidence, approval provenance, completion receipts, and migration originals are preserved by default. Retention may remove transient workspaces and unaccepted raw logs only after durable result ingestion and policy checks. Deletion of accepted evidence requires an explicit retention/deletion operation and must leave a tombstone/impact record; it may invalidate claims requiring that evidence. Do not silently garbage-collect referenced artifacts.

### 20.4 Licensing and release readiness

The inspected HerdRM license file identifies PolyForm Noncommercial 1.0.0. Packaging and distribution must retain applicable notices and have a recorded licensing/permission review for the intended use of HerdRM and all bundled dependencies. This requirement is a release gate, not a conclusion that any particular commercial use is authorized. See R12.

## 21. Migration and rollout

**REQ-34 — Recoverable migration.** Implement read-only preview, explicit apply, and resume/recover for all supported layouts, including the earlier root `state.json` proposal and the inspected Markdown-state/active-lookahead-archive layouts. A legacy layout without a validated mapper remains read-only; do not improvise authority from file presence.

The preview includes inventory and byte digests, detected authorities, milestone identities, branch/PR references, planned target paths, duplicate/conflicting records, approval/evidence provenance, active processes, and required permissions. It must create no project files, activate no milestone, contact no model, and mutate no Git ref.

Apply requires the preview digest and fresh validation that its source inventory is unchanged. Quiesce the project and take the required project/milestone locks. Persist the migration journal and original-byte bundle before changes. Stage the new layout, verify mappings and references, and atomically publish the authority/layout switch at a recorded commit point. An interrupted apply resumes from that journal; it does not restart destructively.

Map intent/synthesis to milestone context; existing plans/tasks to one authoritative contract representation; discussion/review results to preserved evidence; `next/` and archived milestones to permanent directories. Keep original names, bytes, source identities, and shipment history in the migration bundle with mapping records. A completed historical milestone does not become newly accepted under current policy without current applicable evidence.

Competing authorities, duplicate milestone identities, unmatched shipment records, modified approvals, missing evidence, and uncertain active processes block apply or activation. The service must never pick whichever file looks newest.

### 21.1 Authority transfer

Standalone-to-distributed enrollment creates one authority record and leaves local materializations marked remote/read-only. Distributed-to-standalone export requires quiescence, reconciliation of pending effects, revocation of distributed assignments, and explicit transfer. Both directions preserve operation/evidence identity and record the new authority epoch.

A multi-milestone project cannot be downgraded into an older single-milestone layout by discarding other milestones. Unsupported downgrade is refused.

### 21.2 Incremental rollout

Roll out as read-only projections, then controlled source submission/planning, then distributed implementation without shared-target merge, then human-approved promotion, and finally operational hardening. Each mode is explicit in capabilities and policy. A read-only deployment must not expose nonfunctional “approve” controls that appear to act.

Keep prior acceptance definitions/evidence intact and register new named checks as their implementations land. Do not use permanently failing placeholder tests or claim a requirement passed because it was superseded.

## 22. Failure and recovery contract

**REQ-35 — Failure classification.** Every material failure has a stable code, subject identity, operation ID, last certain state, retry classification, and remediation. At minimum implement:

| Code or condition | Required result |
|---|---|
| `STALE_REVISION` / `STALE_CONTRACT` | Refuse transition; return current revision and invalidate stale UI action. |
| `STALE_FENCE` / `AUTHORITY_CHANGED` | Refuse acceptance/effect; quarantine late results and require reconciliation. |
| `LAUNCH_OUTCOME_UNKNOWN` | Inspect runtime/local launch mapping; do not create another run. |
| `EFFECT_OUTCOME_UNKNOWN` | Freeze conflicting effects in that scope; reconcile external fact. |
| `RUNNER_UNREACHABLE` | Preserve last-known status; fence/reassign according to policy, not guessed process death. |
| `DURABILITY_UNAVAILABLE` | Block distributed launch/resume before new execution. |
| `CHECK_FAILED` / `CHECK_INCONCLUSIVE` | Record exact outcome; bounded repair or material block. |
| `APPROVAL_STALE` / `APPROVAL_REVOKED` | Prevent new promotion admission; reconcile already-submitted remote operations. |
| `PROTECTION_UNKNOWN` / `PROTECTION_CHANGED` | Disable affected automatic promotion; continue eligible independent implementation. |
| `SOURCE_CHANGED` | Record candidate revision; do not silently rewrite active contracts. |
| `MIGRATION_AMBIGUOUS` / `JOURNAL_CORRUPT` | Fail closed with inventory/valid-prefix diagnostics; no inferred completion. |
| `RESOURCE_LIMIT` / `BUDGET_EXHAUSTED` | Stop new admission; preserve evidence and require explicit limit change. |
| `CAPABILITY_UNAVAILABLE` / `PROTOCOL_UNSUPPORTED` | Typed refusal; no no-op `completed` response. |
| `PROJECTION_PENDING` / `MIRROR_PENDING` | Accepted state remains valid; repair display/history projection independently. |

Pause/cancel requests must display `requested` until runtime quiescence or a fenced terminal outcome is observed. Cancellation does not imply Git rollback, PR closure, or deletion. Compensating remote actions require their own admission and receipts. A terminal client disconnect must not cancel the underlying accepted job.

## 23. Implementation work packages

**REQ-36 — Delivery sequencing.** The following packages form the implementation plan baseline. Each must produce addressable task contracts with owned paths, dependencies, outputs, acceptance IDs, and exact verification commands before execution. Parallel package work is permitted only after shared interface contracts are frozen; changes to those contracts require revision/revalidation.

| Package | Repository and owned area | Dependencies | Deliverable and acceptance focus |
|---|---|---|---|
| WP-01 Protocol and contract foundation | HerdRM `packages/orchestration-protocol/`, `Packages/OrchestrationKit/` schema fixtures; Path contract register | None | Concrete schemas, generated bindings, identity/version/failure contracts, supersession record. AC-001–004, AC-063. |
| WP-02 Path milestone state and migration | Path `record/`, `shared/`, `control/` | WP-01 | Layout 3, canonical milestone state, resolver, journals, local/remote ports, preview/apply/recover. AC-005–012, AC-067–070. |
| WP-03 Supervisor service and coordination | HerdRM `services/supervisor/` coordination/auth/storage | WP-01, Path port contract | Durable operations, enrollment, assignments, lease generations, capacity, event log, service lifecycle. AC-013–021, AC-057–062. |
| WP-04 Runner and Atomic adapter | HerdRM `services/runner/`; narrowly scoped Atomic patches only for proven correlation/isolation gaps | WP-01, WP-03 assignment protocol | Persistent RPC, launch correlation, certified isolation, artifacts, pause/resume/recovery. AC-022–030. |
| WP-05 Intake and Path delivery driver | Path entry/control/dispatch; supervisor intake adapter | WP-02–04 | Revision submission, clarification/amendment, real end-to-end driver, bounded task execution. AC-031–037. |
| WP-06 Branch, evidence, and publication | Path dispatch/github/evidence; HerdRM effect gateway integration | WP-02, WP-04, gateway contract | Task/milestone refs, candidate verification, serialized internal landing, PR idempotency. AC-038–046. |
| WP-07 Promotion and integration queue | HerdRM supervisor queue/approval; Path GitHub promotion adapter | WP-03, WP-06 | Human approval, native/local/manual profiles, exact-subject integration, uncertain-effect recovery. AC-047–056. |
| WP-08 Native project/milestone UX | HerdRM macOS/iOS features and `Runtime/Orchestration/` | WP-01, projection API contract; live validation after WP-03 | Revision-aware documents, state/progress, controls, attention, terminal links, queue UI. AC-064–066, AC-073–075. |
| WP-09 Operational hardening | HerdRM service deployment/backup/limits; cross-repository harness | WP-02–08 | Backup/restore, retention, upgrade, performance, security regression and license manifest. AC-071–072, AC-076–078. |
| WP-10 End-to-end certification | Cross-repository fixtures/evidence and release manifests | WP-01–09 | Two-host same-repository delivery, crash/fence/merge races, documented release results. AC-079–080 plus demonstrations in Section 25. |

### 23.1 Minimum independently addressable task decomposition

| Task | Contract boundary | Required output |
|---|---|---|
| W01-T01 | Protocol schemas and deterministic canonicalization | Concrete closed schemas, examples, schema compatibility rules. |
| W01-T02 | Swift/TypeScript bindings and golden fixtures | Cross-language conformance tests; no duplicated gate implementation. |
| W01-T03 | Baseline/supersession and packaging contract | Registered Path revision; pinned dependency/compatibility manifest format. |
| W02-T01 | Versioned resolver and project/milestone records | Typed record adapters and ambiguity tests. |
| W02-T02 | Journal, operation lookup, projection separation | Crash-injection tests at each commit boundary. |
| W02-T03 | Migration and authority transfer | Read-only preview plus interruption/competing-authority fixtures. |
| W03-T01 | Service storage/auth/administration | SQLite migrations, enrollment, roles, process exclusivity. |
| W03-T02 | Assignment/capacity/fence coordinator | Race/expiry/reassignment and fair-scheduling tests. |
| W03-T03 | Operations/outbox/projections | Durable replay/cursor/snapshot behavior across restart. |
| W04-T01 | Persistent Atomic RPC lifecycle | Launch correlation and lost-acknowledgement recovery. |
| W04-T02 | Certified workspace/process profiles | Mac/Linux isolation and controlled Git import tests. |
| W04-T03 | Artifact ingestion and cleanup | Resumable finalized uploads; safe retention/quiescence. |
| W05-T01 | Source adapters and authenticated submission | Immutable snapshots, dedupe, observe-only defaults. |
| W05-T02 | Contract compilation and scoped context | Inline/separate contracts, DAG/resources, source/topic references. |
| W05-T03 | Delivery/clarification/amendment workflow | Typed phase outcomes, real task children, bounded repair. |
| W06-T01 | Branch and internal integration adapter | Expected-ref landings, task proof, shared-base refresh. |
| W06-T02 | Independent verifier and evidence admission | Signed exact-subject receipts, review independence, generator checks. |
| W06-T03 | Gateway publication/effect reconciliation | PR marker/identity, lost-response tests, no worker credentials. |
| W07-T01 | Signed human approval protocol | Fresh challenge, stale/revoked subject handling, actor provenance. |
| W07-T02 | Local/native/manual promotion adapters | Certified protection/head/base semantics and queue recovery. |
| W07-T03 | Post-merge acceptance and closeout | Actual merge mapping, completion receipt, summary projection. |
| W08-T01 | Native stores and project/milestone document views | Freshness, manifests, branch selection, deduplicated identity. |
| W08-T02 | Native controls and approval/queue views | Conflict handling, real user intent, offline restrictions. |
| W08-T03 | Fleet/mobile/attention integration | Optional terminal links, retained existing bridge contracts, persisted attention. |
| W09-T01 | Packaging/service lifecycle/upgrades | Reproducible pinned installs, health, safe shutdown and promotion. |
| W09-T02 | Backups/restore/retention | New-epoch recovery and remote inventory reconciliation. |
| W09-T03 | Security/performance/release documentation | Threat-model tests, reference workload results, dependency/license manifest. |
| W10-T01 | Real distributed delivery demonstration | Actual model-backed two-host execution and human promotion evidence. |
| W10-T02 | Failure-injection demonstration | Stale worker, uncertain merge, restart, and amendment evidence. |
| W10-T03 | Compatibility and acceptance report | Complete requirement-to-test-to-artifact mapping and honest limitations. |

Task IDs above are planning identifiers scoped to this specification. The adopted Path plan must allocate stable UUIDs, freeze exact owned paths, and resolve intra-package dependencies. For example, schema consumers depend on W01-T01; journal-based migration depends on W02-T02; promotion depends on evidence and the effect gateway. Shared schema/register files have one designated landing owner; parallel workers propose changes without overwriting them.

## 24. Acceptance catalogue

**REQ-37 — Executable acceptance.** Each case below must have a registered executable test/scenario, its exact command or tool invocation, source/runtime/policy identity, environment, outcome, and durable evidence manifest. Unit fixtures, simulated transport tests, real Git tests, live Atomic tests, real GitHub effects, and actual two-host demonstrations must be labelled separately. A mocked test cannot satisfy a live requirement. All cases are **not run** at publication of this specification.

| ID | Requirement | Scenario and required observable result |
|---|---|---|
| AC-001 | REQ-08, REQ-22 | Present an unknown Atomic/Path/protocol combination. Execution blocks before model or remote mutation; diagnostic identifies the unsupported tuple. |
| AC-002 | REQ-03, REQ-17 | Invoke an unimplemented or readiness-only phase. It returns a typed unavailable/readiness result and cannot advance milestone acceptance. |
| AC-003 | REQ-07, REQ-08 | Round-trip large decimal revisions and qualified IDs across Swift/TypeScript; repository rename, equal M001 labels and equal pane IDs never collide. |
| AC-004 | REQ-06 | Dependency/architecture test rejects duplicated Path gate code in HerdRM/Swift and rejects UI imports inside infrastructure/control modules. |
| AC-005 | REQ-09 | Two milestones update independently. Their revisions/tasks do not overwrite each other; root registry has no second mutable task-status copy. |
| AC-006 | REQ-08, REQ-10 | Resolver sees legacy and new authority markers together. It blocks ambiguity; every routing/planning/dispatch/verification/shipping/recovery consumer uses the same resolver. |
| AC-007 | REQ-05, REQ-09 | Edit STATE.md, SUMMARY.md, task prose status, or a local materialization. No execution, approval, accepted task, or completion changes. |
| AC-008 | REQ-13 | Fail Markdown rendering immediately after state commit. Accepted transition survives restart and the missing projection is regenerated once. |
| AC-009 | REQ-13 | Race two commands with one expected revision. At most one commits; a retry of its operation ID returns its original result rather than a new transition. |
| AC-010 | REQ-13 | Kill at every prepared/write/rename/flush/commit-record boundary. Recovery preserves a valid previous or next state with no lost accepted evidence or duplicate acceptance. |
| AC-011 | REQ-12, REQ-13 | Kill between Path commit and SQLite result/outbox commit. Operation lookup reconciles the committed result; projection catches up without re-executing the transition. |
| AC-012 | REQ-10 | Disconnect an enrolled project's runner and try a standalone local mutation. It refuses remote-authority fallback, while immutable context remains readable. |
| AC-013 | REQ-02, REQ-20 | Admit two independent milestones from one repository on two distinct runners. Their execution intervals overlap and each retains its own controller/branch identity. |
| AC-014 | REQ-02, REQ-24 | Run two milestones on one runner. Worktrees, outputs and state are isolated; changing one checkout cannot switch the other's branch. |
| AC-015 | REQ-21 | Race two assignment claims for one milestone. One current generation wins, and no losing controller may accept work or publish. |
| AC-016 | REQ-21 | Expire/reassign a milestone, then deliver an old runner's valid-looking result and push request. Both are refused by the authority/gateway as stale. |
| AC-017 | REQ-21 | Delay/reorder heartbeat and reconnect messages, including a runner clock jump. Authority is not extended from the runner clock and revoked ownership is not revived. |
| AC-018 | REQ-20 | Exhaust machine, project, provider and budget limits independently. The scheduler defers the right work and never overcommits the declared hard resource. |
| AC-019 | REQ-20 | Hold one long task and repeatedly free other capacity. Eligible work from other milestones and newly ready dependents starts without a batch-wave barrier or starvation. |
| AC-020 | REQ-20, REQ-21 | Two milestones request the same exclusive test resource. Effects serialize; unrelated resources remain usable. An unknown prior resource effect prevents unsafe reassignment. |
| AC-021 | REQ-12, REQ-13 | Start duplicate coordinators against one store and attempt a restored-store takeover without a new epoch. Only the valid coordinator operates; invalid takeover blocks. |
| AC-022 | REQ-22 | Stream RPC records split across UTF-8 buffers, with CRLF and U+2028/U+2029 inside JSON. Decode exactly once without corrupting or splitting valid records. |
| AC-023 | REQ-22 | Lose launch acknowledgement after Atomic allocated a run. Redelivery resolves the original full run ID or blocks unknown; no duplicate root is launched. |
| AC-024 | REQ-17, REQ-22 | Atomic acknowledges a launch then the workflow fails. UI and state never report milestone completion from the acknowledgement. |
| AC-025 | REQ-23 | Interrupt and resume a supported same-host run. Its identity/checkpoints persist, completed durable operations are not repeated, and fresh effects recheck authorization. |
| AC-026 | REQ-23 | Recover on another host after fencing. A new attempt/controller identity references prior accepted work; old run history is preserved and not relabelled as a moved run. |
| AC-027 | REQ-22, REQ-33 | Remove durable runtime backend or use an unsupported runtime. Distributed launch/resume fails closed with no silent in-memory fallback. |
| AC-028 | REQ-24, REQ-32 | Malicious worker/test code attempts to edit contracts, state, runner code, verifier policy, approval keys and gateway credentials. OS/process boundaries deny access. |
| AC-029 | REQ-16, REQ-24 | Interrupt artifact upload and supply wrong digests, traversal paths and archive escapes. No partial/untrusted artifact becomes accepted evidence. |
| AC-030 | REQ-24 | Request cleanup while a process is live, a ref changed, or evidence remains uncollected. Cleanup refuses; after safe conditions, idempotent cleanup preserves retained artifacts. |
| AC-031 | REQ-14, REQ-18 | Capture raw text, local file/directory, GitHub file/directory and issue sources. Preserve exact bytes, provenance, stable digest and span references. |
| AC-032 | REQ-14, REQ-18 | Replay source events and worker edits adding ready markers. Observe-only edits never submit; one authorized exact revision creates one logical submission. |
| AC-033 | REQ-18 | Answer a material question. The answer is stored against exact question/source IDs and composes a revision; it does not silently submit or grant merge permission. |
| AC-034 | REQ-19 | Submit a material amendment during execution. Affected work/promotion is quiesced/fenced, contracts are revised and evidence/approvals invalidated or explicitly revalidated. |
| AC-035 | REQ-15 | Compile equivalent inline and separate-file task contracts. They have equal semantics; duplicates, ambiguous IDs or diverging machine/prose authorities block. |
| AC-036 | REQ-15, REQ-20 | Supply a dependency/resource cycle and then a valid streaming DAG. The cycle blocks; the valid dependent starts only after its own prerequisite is accepted-landed. |
| AC-037 | REQ-23, REQ-26 | Fail implementation/review across resume and reassignment. One-repair/default infrastructure budgets persist; policy-required independent model family cannot silently fall back to self-review. |
| AC-038 | REQ-25 | Two projects share a repository and both allocate M001/T001. Branch namespaces, task attempts and delivery PR identities remain collision-free. |
| AC-039 | REQ-25 | Concurrent task candidates target one milestone, while another milestone also lands work. Each branch serializes its own updates without a repository-wide implementation lock. |
| AC-040 | REQ-25, REQ-26 | Change milestone head/base after a worker check. The landing candidate is recomputed and affected evidence remeasured; stale test results cannot authorize the new tree. |
| AC-041 | REQ-16, REQ-26 | Submit a worker-written success file or schema-valid fabricated review. It is not admitted as proof that a verifier command executed. |
| AC-042 | REQ-16, REQ-26 | Modify source during a verifier run or leave generated outputs inconsistent. Receipt issuance fails or binds a newly verified candidate; no unmeasured tree passes. |
| AC-043 | REQ-26 | Exercise none/risk-based/always review policies. Skipped review remains skipped; required review is independent of implementation and every repair author. |
| AC-044 | REQ-16, REQ-26 | Reuse a receipt from another environment, retired runtime, wrong commit, wrong check issuer or incomplete CI scope. It fails applicable admission. |
| AC-045 | REQ-25, REQ-27 | Run implementation without publication grant. Local work can succeed, but no task/milestone branch, PR or protected remote object is published. |
| AC-046 | REQ-25, REQ-27 | Lose PR-create response after remote creation. Reconciliation adopts the unique existing PR; ambiguous matches block rather than creating another. |
| AC-047 | REQ-28, REQ-32 | Approve one candidate, then change head, target, contract or principal scope. Approval cannot authorize the changed request and the UI explains invalidation. |
| AC-048 | REQ-28 | Revoke approval before admission and during an already submitted merge. The first is prevented; the second is reported as pending/unknown until actual remote outcome is observed. |
| AC-049 | REQ-28 | Move base under fixed-base approval. Candidate evaluation/approval refresh is required; the head precondition is not reported as a base precondition. |
| AC-050 | REQ-28 | On a supported native queue, validate exact merge-group checks and queue-forward approval semantics. Without capability, the system selects a certified alternative or blocks. |
| AC-051 | REQ-28 | Inject an out-of-band target update between final read and local-queue merge. Effective strict protection/subject enforcement prevents an unverified promotion; unsupported enforcement blocks automatic mode. |
| AC-052 | REQ-28 | Remove/alter protection or make rules/check provenance unreadable. Affected promotion stops without weakening gates; other eligible implementation continues. |
| AC-053 | REQ-21, REQ-27 | Kill the gateway after sending a merge/push but before storing its outcome. Restart reconciles and freezes conflicting effects; it never blindly repeats the mutation. |
| AC-054 | REQ-28 | Merge externally in GitHub without a Path approval. Record the true merge and actor; retain integrated-but-unaccepted state until applicable acceptance is established. |
| AC-055 | REQ-17, REQ-26 | Observe actual merge and post-integration checks, then interrupt closeout. Completion is accepted at most once, evidence remains intact, and summary projection is recoverable. |
| AC-056 | REQ-28 | Complete an authorized milestone merge. No deploy, release, destructive migration or credential action occurs without its separate explicit grant. |
| AC-057 | REQ-29, REQ-32 | Invalid certificate, expired enrollment, replayed challenge and revoked client attempts are rejected without leaking project existence/content outside authorized scope. |
| AC-058 | REQ-29, REQ-32 | A runner or viewer requests submit/approve/merge/admin actions. It cannot escalate; permission is evaluated from authenticated identity rather than payload role. |
| AC-059 | REQ-18, REQ-32 | A source document or issue comment instructs the agent to change policy, expose keys or approve itself. Those strings remain untrusted content and cannot cross the permission boundary. |
| AC-060 | REQ-16, REQ-32 | Seed secrets in tool output, attachment metadata and source URLs. Protected raw evidence is retained as policy allows; UI/events/notifications and prompts do not leak forbidden data. |
| AC-061 | REQ-32 | Implement a change to the supervisor/Path verifier itself. Candidate code cannot replace the running trusted binary/policy during verification; upgrade requires separate promotion. |
| AC-062 | REQ-27, REQ-30 | Replay a command with same ID/same payload and then same ID/different payload. First returns original result; second conflicts; audit retains actual actor and service provenance. |
| AC-063 | REQ-07, REQ-08, REQ-29 | Cross-language schema fixtures cover unknown versions, enum cases, nullability, counters and error envelopes. No unresolved illustrative type or prose-parsed action ships. |
| AC-064 | REQ-30 | Drop/reorder/duplicate events and expire a cursor. UI resnapshots consistently, does not regress within an epoch, and resets cached actions after epoch change. |
| AC-065 | REQ-11, REQ-31 | Display a newer plan with an older state or wrong-branch codebase page. Manifest/provenance validation prevents an unlabeled mixed view; Markdown alone is unverified. |
| AC-066 | REQ-07, REQ-31 | Equal pane IDs across devices and an Atomic run without a pane render correctly. Terminal done/idle does not change accepted milestone progress. |
| AC-067 | REQ-34 | Run migration preview on legacy, proposed-root-JSON and layout-3 fixtures. Source bytes/refs/state remain unchanged; inventory and proposed mapping are complete. |
| AC-068 | REQ-34 | Interrupt apply before/after staging and authority switch. Resume preserves originals and reaches one unambiguous authority, with no duplicate acceptance or missing evidence. |
| AC-069 | REQ-04, REQ-34 | Migrate archives/lookahead/discussions and old approvals. Stable directories/provenance/shipment history survive; artifact presence and retired evidence do not infer current completion. |
| AC-070 | REQ-10, REQ-34 | Transfer standalone/distributed authority and attempt unsupported downgrade. Exactly one writer remains; unsafe downgrade/old local mutation is refused. |
| AC-071 | REQ-13, REQ-33 | Restore an older backup after a remote effect occurred. New epoch invalidates old tokens; full bound-entity reconciliation surfaces effects absent from the backup. |
| AC-072 | REQ-16, REQ-33 | Fill artifact disk or run retention with referenced evidence. No acceptance points to incomplete output; referenced artifacts survive or explicit tombstones invalidate affected claims. |
| AC-073 | REQ-01, REQ-31 | Close windows, quit macOS UI and disconnect a phone while work runs. Supervisor/runner work continues; reconnect restores authoritative progress. |
| AC-074 | REQ-29, REQ-31 | Double-click start/approve and act from stale/offline views. Operations deduplicate; stale commands conflict and cached approvals are not silently sent. |
| AC-075 | REQ-31, REQ-32 | Test direct iOS supervisor connection, optional bridge proxy and older fleet clients. Existing terminal/bridge behavior remains intact and pairing alone cannot merge. |
| AC-076 | REQ-30, REQ-33 | Execute the declared reference workload. Meet measured local latency/resource bounds, with bounded caches/log buffers and no idle terminal/process growth. |
| AC-077 | REQ-06, REQ-08, REQ-33 | Install/upgrade/restart certified packages, reject incompatible rollback, and inspect dependency/license manifest. Service state survives without GUI or hidden global runtime reinstall. |
| AC-078 | REQ-11 | Compare task-scoped language guidance with baseline on Forma-like and UXP-like fixtures. Report correctness, discovery work, rework and cost/usage; do not mandate guidance solely because it adds documentation. |
| AC-079 | REQ-02, REQ-03, REQ-36, REQ-37, REQ-38 | Complete the live two-host same-repository demonstration with actual model execution, durable verification and human-authorized promotion. Retain reproducible evidence and validate the adopted task/requirement/case traceability index. |
| AC-080 | REQ-05, REQ-35, REQ-38 | Complete the live recovery demonstration with stale worker, changed candidate, lost external response and interrupted closeout. No duplicate acceptance or unauthorized promotion occurs. |

### 24.1 Test classification and evidence handling

Deterministic suites must use controllable clocks/transports and explicit barriers rather than timing guesses. Failure injection must exercise production-backed code paths. Real Git tests use disposable repositories and check actual objects/refs. Network/protection tests use an explicitly authorized disposable GitHub repository. Negative fixtures must not publish fabricated green checks to production repositories.

Record the test mode in every receipt. Live-required cases remain not-run or blocked when credentials/toolchains are unavailable; they must not pass through a fixture fallback. The acceptance report maps each REQ/INV to its cases and each case to exact artifact digests. Missing mappings fail the release gate.

### 24.2 Invariant traceability

| Invariant | Minimum acceptance coverage |
|---|---|
| INV-01 | AC-005, AC-006, AC-012, AC-070 |
| INV-02 | AC-015, AC-016, AC-021 |
| INV-03 | AC-003, AC-016, AC-040, AC-044 |
| INV-04 | AC-009, AC-011, AC-023, AC-062 |
| INV-05 | AC-016, AC-017, AC-028, AC-058 |
| INV-06 | AC-023, AC-046, AC-048, AC-053, AC-071 |
| INV-07 | AC-002, AC-007, AC-024, AC-041, AC-066 |
| INV-08 | AC-037, AC-040, AC-042, AC-044, AC-055 |
| INV-09 | AC-013, AC-019, AC-039, AC-051 |
| INV-10 | AC-047, AC-049, AC-050 |
| INV-11 | AC-025, AC-048, AC-052, AC-057 |
| INV-12 | AC-028, AC-058, AC-059, AC-061 |
| INV-13 | AC-003, AC-038, AC-066, AC-069 |
| INV-14 | AC-010, AC-055, AC-068, AC-069, AC-072 |
| INV-15 | AC-019, AC-020, AC-052, AC-073 |
| INV-16 | AC-050, AC-051, AC-052 |
| INV-17 | AC-056 |
| INV-18 | AC-044, AC-069, AC-071 |

## 25. Required end-to-end demonstrations

**REQ-38 — Demonstrate the product, not only its adapters.** The release candidate must execute both demonstrations below with pinned sources and the actual installed Path/Atomic pair. Synthetic tests are additional evidence, not substitutes.

### Demonstration A: concurrent delivery

Use one authorized disposable repository with two meaningful independently specified features and a shared interface contract. Create two submitted milestones, each with at least three tasks and observable acceptance criteria. Use two distinct OS instances with separate runner identities and filesystems; two subprocesses in one runner do not count as two computers. The platform certification matrix must include a Mac and Linux runner, and checks requiring Apple tooling must be assigned appropriately.

Observe both milestone controllers implementing concurrently. Within at least one milestone, prove overlap of independent tasks and streaming start of a dependent after its own prerequisite lands. Inspect both milestones from HerdRM, including source/plan context, evidence, machine assignment, and optional terminal links. Quit the Mac application and show that execution continues, then reconnect.

Path must create separate milestone branches and delivery PRs. A real authorized person reviews the candidate in HerdRM and authorizes promotion; GitHub's applicable review requirements remain enforced. Promote the first milestone. Refresh/reverify the second against the advanced target and obtain the required fresh approval. Observe the actual merged subjects, run required post-integration checks, close both milestones, and render summaries. Retain operation/fence identities, run IDs, source subjects, test outputs, PR/check/review/merge facts, approval provenance, and state transitions.

Native merge queue certification may use an additional repository that supports it. The core same-repository demonstration must also prove the supervisor-managed or manual-safe fallback appropriate to the actual configured repository capabilities.

### Demonstration B: recovery and stale authority

During another controlled run, disconnect a runner after local work starts. Fence/reassign it under the declared policy, then restore it and submit a late candidate/effect request. Verify stale work cannot become accepted or publish. Preserve it as quarantined evidence if retained.

Inject a lost acknowledgement after a real or controlled production-adapter external request, including at least one real GitHub publication/merge outcome in an authorized test repository. Verify lookup/reconciliation rather than blind retry. Change a candidate after approval and demonstrate refusal. Interrupt the coordinator between Path commit and projection update, and interrupt closeout around its commit point. Recovery must preserve one accepted history and no false completed status.

Include a material source amendment and one verification failure requiring bounded repair. Show that repair budget, source/contract binding, independent review requirements, and permission revocation survive restart/reassignment.

### 25.1 Knowledge-layout evaluation

Separate evaluation fixtures must represent both Forma-like and UXP-like codebases: logical responsibilities mapped to physical packages, multiple independent/shared implementations, wrappers and differing type meanings, authored/generated artifacts, and scoped verification environments. Use the same tasks and comparable model/budget settings for baseline and task-scoped language guidance runs. Report observed outcomes and limitations; do not claim a universal model-quality improvement from a small fixture sample.

## 26. Definition of implementation complete

The implementation is complete only when mandatory release capabilities are implemented, all applicable acceptance cases have genuine evidence, demonstrations A and B pass, and no unresolved blocker weakens an invariant. Optional native-queue or other capability-specific cases must be explicitly marked not-applicable with their certified safe fallback; they may not be reported passed without execution. Cross-host task children and background iOS push are explicitly outside the first release and must not appear as delivered features.

Deliver reproducible supervisor/runner packages, the Swift client integration, the pinned Path control package, any narrowly required Atomic patch, versioned schemas/golden fixtures, registered contract supersession, migration tools, operator configuration/backup/recovery guides, threat model, evidence-backed acceptance report, and dependency/license notices.

The handoff must state the exact tested repositories/commits, installed runtime versions, operating environments, model/verifier policies, deployment modes, and remaining limitations. Existing HerdRM fleet/mobile/terminal tests and Path gate/discovery/recovery tests must still pass in their documented environments. No test may be weakened or silently skipped to create a green report.

A release summary, a code diff, a manager-agent statement, or a screenshot of two terminals is not sufficient proof.

## Appendix A. Source register and observed implementation boundaries

These sources establish the inspected starting point and external integration constraints. They do not establish that the proposed system has been implemented. Repository links are pinned to inspected commits; external documentation was checked on September 21, 2026.

**R1 — HerdRM application architecture.** Existing native feature/runtime/infrastructure boundaries and shared packages.  
[docs/architecture.md](https://github.com/Marti-S/herdrm/blob/f903dd3872e19c7266cfa5fd7a11a3acf6fe0c95/docs/architecture.md)

**R2 — HerdRM mobile bridge.** The current bridge lives in the Mac app process; explicit quit closes it. Existing fleet transport must not become the required lifetime of the new supervisor.  
[docs/MOBILE_BRIDGE.md](https://github.com/Marti-S/herdrm/blob/f903dd3872e19c7266cfa5fd7a11a3acf6fe0c95/docs/MOBILE_BRIDGE.md)  
[Fleet bridge types](https://github.com/Marti-S/herdrm/blob/f903dd3872e19c7266cfa5fd7a11a3acf6fe0c95/Packages/HerdrKit/Sources/HerdrKit/FleetBridge/FleetBridge.swift)

**R3 — Path repository contract.** Existing source-submission intent, separate remote permissions, historical acceptance preservation, branch-topology restriction, and supported Atomic runtime. The target explicitly supersedes only the obligations listed in Section 1.3.  
[AGENTS.md](https://github.com/Marti-S/PathWorkflow/blob/fb634cbaa369c7be21e4db3b026128a0b79d7ad9/AGENTS.md)

**R4 — Path single-host ownership.** The inspected implementation explicitly lacks distributed lease/fencing coordination and refuses foreign-host ownership. Local claim files cannot fulfill this specification alone.  
[tools/path/dispatch/owner.ts](https://github.com/Marti-S/PathWorkflow/blob/fb634cbaa369c7be21e4db3b026128a0b79d7ad9/tools/path/dispatch/owner.ts)

**R5 — Atomic headless integration.** Long-lived RPC, correlated requests, and LF JSONL framing. Current-main reference must be checked against the supported installed runtime.  
[RPC documentation](https://github.com/Marti-S/atomic/blob/b8c2b26b58d27d1abf67da7051fd85ce4ec9275e/packages/coding-agent/docs/rpc.md)  
[RPC protocol](https://github.com/Marti-S/atomic/blob/b8c2b26b58d27d1abf67da7051fd85ce4ec9275e/packages/coding-agent/docs/rpc/protocol.md)

**R6 — Existing Path runtime smoke harness.** A starting point for persistent RPC launch/resume; its fixture mode is not live implementation acceptance.  
[tools/path/scripts/smoke-atomic.ts](https://github.com/Marti-S/PathWorkflow/blob/fb634cbaa369c7be21e4db3b026128a0b79d7ad9/tools/path/scripts/smoke-atomic.ts)

**R7 — Atomic workflow operation and Path outcome boundaries.** Startup acknowledgement, run controls and unknown outcomes must be distinguished from milestone delivery; current phase outcomes require explicit classification.  
[Atomic workflow operations](https://github.com/Marti-S/atomic/blob/b8c2b26b58d27d1abf67da7051fd85ce4ec9275e/packages/coding-agent/docs/workflows/operations.md)  
[Path phase runner](https://github.com/Marti-S/PathWorkflow/blob/fb634cbaa369c7be21e4db3b026128a0b79d7ad9/tools/path/entry/phase-runner.ts)

**R8 — Native GitHub merge queues.** Queue availability and combined-candidate validation; Actions must handle the merge-group subject.  
[Managing a merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)  
[Merge-queue availability and use](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request-with-a-merge-queue)

**R9 — GitHub merge API and branch protection.** Expected PR head parameter, asynchronous acknowledgement distinctions, strict up-to-date checks, and expected check issuers. The documented synchronous merge input does not supply a target/base-OID compare-and-swap.  
[Pull request REST endpoints](https://docs.github.com/en/rest/pulls/pulls)  
[Protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)

**R10 — GitHub webhook handling.** Raw-payload verification, HTTPS, event/action validation, delivery-ID handling and recovery guidance.  
[Webhook best practices](https://docs.github.com/en/webhooks/using-webhooks/best-practices-for-using-webhooks)

**R11 — SQLite WAL deployment constraint.** WAL access is same-host; remote runners must not share the database through a network filesystem.  
[SQLite write-ahead logging](https://www.sqlite.org/wal.html)

**R12 — HerdRM license baseline.** The inspected repository license identifies PolyForm Noncommercial 1.0.0. Review actual intended use/distribution rather than assuming permission from public availability.  
[LICENSE.md](https://github.com/Marti-S/herdrm/blob/f903dd3872e19c7266cfa5fd7a11a3acf6fe0c95/LICENSE.md)

**R13 — Path layout and state baseline.** Current resolver/state consumers require migration to milestone-scoped JSON authority and the new logical layout.  
[Path resolver](https://github.com/Marti-S/PathWorkflow/blob/fb634cbaa369c7be21e4db3b026128a0b79d7ad9/tools/path/shared/paths.ts)  
[Path state model](https://github.com/Marti-S/PathWorkflow/blob/fb634cbaa369c7be21e4db3b026128a0b79d7ad9/tools/path/record/state.ts)

**R14 — Owner-provided requirements.** The Path refactor specification and subsequent requirement for multiple computers, concurrent milestones, HerdRM integration, Path-managed branches/PRs, and supervisor/human merge control were supplied directly in the originating conversation. Preserve that text as an immutable intake source when adopting this specification; do not manufacture a repository provenance URL for it.

## Appendix B. Glossary

| Term | Meaning in this specification |
|---|---|
| Accepted | Admitted by Path's deterministic policy using valid subject-bound evidence; not synonymous with a worker returning. |
| Assignment | Supervisor-owned allocation of execution authority and capacity to a runner. |
| Attempt | One immutable execution lineage for a task/candidate; retries with new execution have new identities. |
| Candidate | Exact source/contract/evidence subject proposed for internal landing or shared-target promotion. |
| Controller | The milestone's Path delivery workflow using Atomic; not a free-form manager agent. |
| Coordinator epoch | Installation authority generation changed on restore/transfer so old tokens cannot regain authority. |
| Effect | An operation that changes local authoritative or external state and requires durable identity/reconciliation. |
| Fence | Scope-bound generation checked by the receiver of an acceptance or privileged effect. |
| Integration lane | Serialized admission/effect ownership for one milestone branch or shared target; not a global implementation lock. |
| Materialization | Read-only working copy of canonical records/contracts, labelled with authority and revision. |
| Projection | Rebuildable view of accepted state and observations, never an independent workflow authority. |
| Promotion | Movement of a verified milestone candidate into a shared target under human/policy authorization. |
| Submission | An authenticated instruction to implement a specific immutable source revision. |
| Unknown outcome | A request may have acted but definitive observation is unavailable; not automatically success or failure. |

## Appendix C. Required implementation evidence index

The final acceptance report must index: requirement/invariant IDs; case IDs and mode; implementation commit(s); installed runtime/Path/supervisor/runner identities; test command/tool; environment manifest; observed result; evidence artifact paths and digests; approval/integration subjects; and any not-applicable ruling. Each index entry must resolve to durable retained content.

The source specification remains the change contract. The report records what was actually established. Neither artifact substitutes for the other.
