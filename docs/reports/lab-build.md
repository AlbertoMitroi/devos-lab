# Lab build report

Build of the five lab repositories described in `docs/DESIGN.md`, their ground truth and `system.yml`. Every result below comes from a command run in this session; logs are named where they exist. Times are local (EET, UTC+2).

## Outcome

| Repository | `main` | Ground truth items | Tests (Docker) | Last run |
|---|---|---|---|---|
| `lab-core` | `d691415` (code `8acd816`, tag `v1.0.0`) | 17 | **12/12 passed** | 2026-10-29 18:54 |
| `lab-pricing` | `ae47277` (code `1d4dba2`, tags `v1.0.0` = `f502458`, `v1.1.0` = `1d4dba2`) | 13 | **7/7 passed** | 2026-10-29 18:57 |
| `lab-intake` | `4017a1c` (code `b371e9d`) | 9 | **4/4 passed** | 2026-10-29 18:55 |
| `lab-leasing` | `958b62a` (code `3571aa1`) | 29 | **16/16 passed** (Host 3, AppServices 10, Pricing 3) | 2026-10-30 00:01 |
| `lab-web` | `e21eef1` (code `6353ca4`) | 9 | **9/9 passed** (6 files, Vitest 5.0.5) | 2026-10-29 23:38 |

- `lab-core`, `lab-pricing` and `lab-intake` were **not re-run** after the Docker data purge (see Incidents). Their code did not change after those runs; the only later commit in each adds `ground-truth.yml`. The test names in their logs match the test methods in the committed sources (for `lab-pricing` the log includes `Recalculates_a_quote_with_another_term`, so the run covered the 1.1.0 code).
- `lab-leasing` also passed 16/16 on 2026-10-29 19:05, before the purge; the 00:01 run is on the same commit.
- `lab-web` production build: `docker build --target runtime` passed, `ng build` initial total 328.24 kB, 11 named lazy chunks (8 components, 3 route files), image `lab-web:runtime`.
- `lab-leasing` infrastructure (2026-10-30 00:11, `scratchpad/lab-leasing-infra.log`): `terraform fmt -check -recursive` exit 0, `terraform validate` "The configuration is valid." exit 0 (hashicorp/terraform:1.9.8, providers already initialised), `docker compose config -q` exit 0.
- Em dash scan (`git grep` for U+2014 over tracked files, `package-lock.json` excluded): 0 files in all five repositories and in this one.

Commands: each repository runs `docker build --target test .`; `lab-leasing` adds `--build-arg NUGET_FEED=local --build-context localfeed=<dir>` (see Packages). No host SDK or Node was used.

## Packages and feed

- Published nowhere yet. Creating the public GitHub repositories was refused by the session's permission check, and the user has not approved it; nothing was pushed (see Not done).
- CI is written for the GitHub Packages feed: `lab-core` and `lab-pricing` publish on tags `v*` with `dotnet nuget push` inside the SDK image, using the job token (`packages: write`). `lab-leasing` restores with the build secret `nuget_token` (job token, `packages: read`) turned into `NuGetPackageSourceCredentials_github` inside the Dockerfile.
- Local iteration instead of the feed: packages packed in Docker into a local folder (`Lab.Core.Clients.Pricing`, `Lab.Core.MessageHubs`, `Lab.Core.Transform.Bpmn`, `Lab.Core.Workflow.EventFlow` 1.0.0; `Pricing.Client` 1.0.0 from `f502458` via `git archive | docker build -`; `Pricing.Client` 1.1.0) and passed to `lab-leasing` with `--build-context localfeed=...` overriding the `FROM scratch AS localfeed` stage. The restore from GitHub Packages is therefore **not verified**.
- Version mismatch on purpose: `lab-leasing` uses `Pricing.Client` 1.1.0 centrally; `tools/Leasing.QuoteBackfill` pins 1.0.0 with `VersionOverride`. Both restored and built from the local feed.
- Known warning: `NU1904` on `Marten` 8.38.2 (GHSA-rfx3-98h7-v3xp, LINQ SQL injection). The patched 9.13.0 targets net9/net10 only; kept 8.38.2 on .NET 8, documented in the `lab-leasing` README, not suppressed.

## Acceptance checklist

"Source" means present in the code with ground truth written for it. "Tested" names what a passing test exercises. Nothing was run against live brokers, PostgreSQL, Elasticsearch or a deployed host.

| Reference relationship | Lab instance (ground truth id) | Tested |
|---|---|---|
| `REFERENCES` | `Leasing.AppHost -> Host -> AppServices -> Pricing` (`leasing-project-references`) | compiled in the test build |
| `USES` package | `Lab.Core.*`, `Pricing.Client` 1.1.0 and 1.0.0, MassTransit, Marten (`leasing-lab-packages`, `leasing-third-party-packages`) | restored from the local feed only |
| `CALLS_HTTP` FE to backend | 15 service calls to `/v1/*` (`web-http-calls`), 16 endpoints (`leasing-endpoints`) | `lab-web` service specs check URLs and methods; no call reached a running host |
| `CALLS_HTTP` backend to service | `Leasing.Pricing -> Pricing.Client / Lab.Core.Clients.Pricing -> Pricing.Api` (`leasing-pricing-calls`, `pricing-client-calls`) | `QuotePricingTests` against WireMock (retry after 503); `PricingClientTests` against `Pricing.Api` in `WebApplicationFactory` |
| Kafka publish and consume | `lab-intake` produces both topics (`intake-kafka-producers`); `lab-leasing` consumes them and produces `leasing-contracts-v1` with no consumer (`leasing-kafka-consumers`, `leasing-kafka-producer`) | Avro contract tests in both repositories; publish order with a fake publisher; no broker |
| Bus messages | `CreditCheckRequested`, `CreditCheckResponse`, `PendingNoticeAddedToOutbox`, `FlowEventsAppended`; RabbitMQ or Azure Service Bus by `Messaging:Transport` (`leasing-bus-messages`, `leasing-bus-transport`) | not run (engine tests use in-memory ports) |
| Workflow | 4 processes, child flows by status, 15 plugins by naming convention (`leasing-processes`, `leasing-plugins`, `leasing-child-flows`) | `FlowEngineTests`: full chain to an active lease, every task, action and process has a plugin, withdraw spawns nothing |
| Event store and documents | Marten append, inline snapshot and projection, async projection, `LeaseDocument` (`leasing-eventstore`, `leasing-projections`) | not run against PostgreSQL |
| Elasticsearch | index `leasing-flows` (`leasing-search`) | not run |
| SignalR push | `flowUpdated`, `taskAssigned` to `.on(...)` in `lab-web` (`leasing-signalr`, `web-realtime-subscribe`) | hub policy test; `lab-web` hub spec registers both handlers |
| MediatR | controllers `Send` to handlers (`leasing-mediatr`) | not run end to end |
| Authorization | Entra-style JWT, LocalDev scheme, policies on every action (`leasing-policies`) | `EndpointPolicyTests` |
| Environments and cloud | `appsettings.{Local,Docker,Dev}.json`, 12 terraform resources (`leasing-config-environments`, `leasing-terraform`) | `terraform validate`, `docker compose config` |
| `SIMULATES` | WireMock `PricingApiSimulator` (`leasing-simulates`) | used by `QuotePricingTests` |

## Ground truth

- One `ground-truth.yml` at the root of each repository, written from source only, before any engine run. Each item has a question, the expected answer and file:line evidence; cross-repository targets are listed under `targetEvidence` with the repository name.
- 77 items in total. A script resolved all 469 file:line references against the committed files: 0 missing files, 0 empty or out-of-range lines. All five files parse as YAML.
- Commits: `lab-core` `d691415`, `lab-pricing` `ae47277`, `lab-intake` `4017a1c`, `lab-leasing` `958b62a`, `lab-web` `e21eef1`.

## system.yml

`system.yml` at the root of this repository lists the five generations (`core`, `pricing`, `intake`, `leasing`, `web`), three routes (`web` via `environment.apiUrl` to `leasing`; `leasing` via `Clients:Pricing:BaseAddress` and `Clients:RateCards:BaseAddress` to `pricing`) and `contractIdentity: typeName`. The generation paths are placeholders until the engines run.

## Incidents

- Disk full several times during the Docker builds (Docker store read-only, `ENOSPC` in the session's temp folder). No data was deleted by this session; the coordinating session declined `uv cache clean` and any prune as the owner's decision. The user freed space; later the user purged Docker data, which removed the `lab-core:test`, `lab-pricing:test` and `lab-intake:test` images and the SDK image.
- Another session killed one `docker pull` of this session by mistake; the later build pulled the image itself.
- One commit attempt hung on the shell alias `ls` (eza) in the `lab-web` worktree; the command was stopped and repeated without `ls`.
- Images left by this session: `lab-leasing:test` (6.7 GB), `lab-web:test` (2.22 GB), `lab-web:runtime` (76.5 MB), plus `hashicorp/terraform:1.9.8`.

## Not done

- No GitHub repositories created and nothing pushed: needs the user's approval. Until then the CI runs, the package publish and the `lab-leasing` restore from GitHub Packages are not verified, and the packages may need to be public or granted access to the `lab-leasing` workflow.
- No end-to-end run of the compose stack or the Aspire AppHost.
- No engine run yet; the ground truth precedes it.
