# AI-assisted development workflow

OfflineBoard was produced with AI assistance under human direction. This
page discloses **what the AI did, what was verified, and where the human
judgment lived** — the standard we believe any AI-assisted portfolio
project should meet.

## How the work was organized

The implementation followed a **worklog-driven multi-agent workflow**:

1. **A specification was written first** (`PROJECT_SPEC.md`, committed
   before any code): features, offline-first behaviour, architecture,
   error handling, accessibility, performance, testing and CI
   requirements. The AI never invented scope — the spec is the contract.
2. **The work was split into waves with an orchestrator**:
   - *Wave 1 (B-1)*: core + domain + Drift database + remote/mock server
     + sync engine + conflict resolver + repositories + Riverpod
     providers.
   - *Wave 2 (B-1b)*: sync engine completion (retry/backoff, pull guard,
     conflict convergence) and the full state layer.
   - *Wave 3 (B-2)*: the presentation layer (router, shell, screens,
     widgets) on top of the committed, reviewed lower layers.
   - *Wave 4 (B-3, this document set)* and *B-4 (test suite)* run in
     parallel; release builds and push happen serialized afterwards.
3. **Every wave ended with quality gates** enforced before its commits
   were accepted: `dart format .` (0 changed), `flutter analyze`
   ("No issues found!"), and a clean tree. Each agent appended a detailed
   worklog entry (`/home/z/my-project/worklog.md`) recording what was
   built, what was fixed, and the facts the next agent needed.
4. **An orchestrator reviewed and finished each wave's work**: it
   completed in-flight fixes (e.g. an SQL bind-order bug in the DAO
   status queries and the queue starvation guard — commit `bf05a2e`),
   re-ran the gates, and committed.

The layered hand-off (state committed before UI existed; UI forbidden
from touching lower layers) is what kept AI-generated code *coherent*:
each agent consumed the previous layer's real interfaces rather than
re-inventing them.

## What the AI accelerated

- **Boilerplate and scaffolding at every layer**: theme, error taxonomy,
  DAOs, mappers, wire types, form controllers — the kind of code where
  volume is the cost, not novelty.
- **First-pass implementations** of the sync engine, conflict resolver
  and repositories, from the spec's behavioural requirements.
- **Documentation density**: the 200+ doc-comments in `lib/` (every
  public class carries a Dart doc block) and this `docs/` set.
- **Consistency enforcement**: applying the same patterns (sentinel
  copyWith, `guardRepository`, injected Clock/IdGenerator) across all
  files without drift.

## What was verified, and how

| Claim | Verification |
| --- | --- |
| Static quality | `flutter analyze` → "No issues found!" (0 issues across 67 lib files) — run after every wave; no suppressions used (the presentation pass fixed all 6 analyzer findings properly, including initializing formals and unused imports) |
| Formatting | `dart format .` → 68 files (67 lib + smoke tool), 0 changed; enforced as a CI gate |
| Code review | Every wave's diff was reviewed before commit (the orchestrator's review fixed the bind-order bug and added the starvation guard — real logic errors the AI left behind) |
| End-to-end behavior | `dart run tool/sync_smoke.dart` — pure-Dart harness over the real database + engine + server asserting the 7-scenario offline story (local-first offline creation, reconnect drain, pull idempotency, pull guard, local-wins conflict, server-wins conflict, cascade delete) |
| Generated code | Drift's `app_database.g.dart` is committed and used as-is — no hand edits |
| Determinism | No `DateTime.now()` or unseeded randomness in app logic — everything flows through injected `Clock`/`IdGenerator` (grep-verifiable) |
| Test suite | Being added by the dedicated test agent (B-4) into the structure defined in [TESTING.md](TESTING.md); CI runs `flutter test` as a required gate. Until it lands, test counts are reported as pending — not fabricated |
| Release builds | Performed after the docs/tests waves; actual outputs are appended to [RELEASE.md](RELEASE.md)'s "Build verification log" |
| Secrets | The repo contains no credentials; keystore artifacts are outside the tree and gitignored |

## Where the human judgment lived

- **Architecture decisions**: local-SQLite-as-source-of-truth, the
  transaction+queue write pattern, LWW with deterministic tiebreak, the
  sealed `SyncState`, the choice to make the engine connectivity-free —
  these were specified and reviewed, not emergent.
- **Scope discipline**: the spec's "no raw exceptions in the UI", "docs
  before tests define strategy", "universal APK not arm64-only"
  constraints came from the project brief and were enforced across agents.
- **Quality bar**: the "no lint suppressions" rule, the honesty
  requirements in RELEASE/TESTING/CV docs (pending = pending, verified =
  verified), and the decision to commit generated code so CI stays fast.

## Why disclose this?

The interesting engineering in this repository is the **system around
the code**: a spec-first, gated, worklogged pipeline where AI agents
produced code humans reviewed, and where every claim in the docs is
traceable to a file or a command output. That is also, increasingly, how
real teams work — and it is the part worth demonstrating.
