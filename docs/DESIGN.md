# Lab design

Small but complete: every node kind and relationship kind of the reference architecture must appear at least once, in code the engines have never seen, so their output can be checked against hand-written ground truth. All names are neutral (domain: equipment leasing), nothing from the reference organisation.

## Repositories (siblings under `~/repos/devos/`)

| Repository | Mirrors | Content |
|---|---|---|
| `lab-core` | `MyCompany.Core.*` shared packages | NuGet packages: `Lab.Core.Workflow.EventFlow` (flow aggregate, flow events, an `EventFlowAnalyzer` that reads BPMN and returns the tasks, actions and status of a flow), `Lab.Core.Transform.Bpmn` (loads `.bpmn` + `*.ProcessMetaData.json`), plugin interfaces `IHandleServiceTask`, `IHandleUserTaskCommand`, `IHandleAction`, `IHandleNewFlow`, `Lab.Core.MessageHubs` (SignalR helper `SendToAll`/`SendToSpecifiedUsers`), and typed clients for the Pricing API (`Lab.Core.Clients.Pricing`) |
| `lab-pricing` | Rating Service + its client | `Pricing.Api` (ASP.NET Core, controllers and minimal APIs, EF Core on PostgreSQL), `Pricing.Client` (typed client over the API, published as NuGet from this repository, so the source is known to federation) |
| `lab-intake` | Intake domain | small worker publishing `lease-applications-v1` and `lease-application-enrichment-v1` to Kafka (MassTransit rider, Avro) |
| `lab-leasing` | the main backend (`MyProject`) | modular monolith: `Leasing.Host` (`/v1` controllers, SignalR hub, Entra-style JWT policies), `Leasing.AppServices` (MediatR handlers, Flow Engine plugins, MassTransit consumers on RabbitMQ locally and Azure Service Bus by configuration, Kafka rider consumers and producers with topics from options), `Leasing.Pricing` module (uses `Pricing.Client` from the feed, Polly), Marten event store and documents on PostgreSQL with inline and async projections, Elasticsearch read models, processes in `ConfigFiles/FlowEngine/Process/*.bpmn` + metadata, Aspire AppHost, `docker-compose`, `terraform/*.tf`, GitHub Actions |
| `lab-web` | `MyProject.Web` | Angular (latest), standalone components, lazy routes, services with `HttpClient` to `/v1` (base URL from environments), SignalR client receiving pushes, an interceptor adding the token |

Feed: GitHub Packages for `lab-core` and `Pricing.Client`; `lab-leasing` restores with `NuGetPackageSourceCredentials_*` (also exercises the private-feed rule of the engine). One consumer pins an older `Pricing.Client` version on purpose, to test version mismatch in federation.

## Acceptance checklist (from the reference graph)

| Reference relationship | Lab instance | Expected output |
|---|---|---|
| `REFERENCES` (project) | `Leasing.Host → Leasing.AppServices → Leasing.Pricing` | project records, `projectReferences` |
| `USES` (package) | `Lab.Core.*`, `Pricing.Client`, MassTransit, Marten | `packages`, `usedPackageApi`, federation `implemented_by_package` |
| `CALLS_HTTP` FE → backend | `lab-web` services → `/v1/leases`, `/v1/quotes` | Angular `http.call` → federation link to `lab-leasing` `http.endpoint` |
| `CALLS_HTTP` backend → service | `Leasing.Pricing` → `Pricing.Client` → `Pricing.Api` | package call site → client source `http.call` → `Pricing.Api` endpoint (federation trace) |
| `PUBLISHES_TO` / `CONSUMES_FROM` Kafka | `lab-intake` → `lease-applications-v1` → `Leasing.AppServices` consumer; `Leasing` → `leasing-contracts-v1` (no consumer in the lab) | `messaging.*` with `transport: kafka`, topic destination; cross-repo link; unresolved with reason for the outbound topic |
| `CARRIED_BY` / `HANDLES` / `SENDS` bus | `PendingNoticeAddedToOutbox`, `CreditCheckResponse` over RabbitMQ / Azure Service Bus | `messaging.*` with `transports: [rabbitmq, azure-service-bus]`, queue destinations |
| `EXECUTES` / `TRIGGERS` / `SPAWNS` workflow | `Application`, `Assessment`, `Lease`, `Quote` processes; child flows by events | `workflow.process/node/flow`, `workflow.handler` for every service and user task, `dispatches_to` links |
| plugins `IHandle*` | one plugin per task | `workflow.handler` by convention file naming `Lab.Core.*` symbols |
| `WRITES_TO` event store / documents | Marten `Append`, documents, projections | `eventstore.append`, `eventstore.projection`, `data.table` |
| `INDEXES_IN` / `READS_FROM` Elasticsearch | read-model index and search | `search.index` |
| `PUSHES_TO` SignalR | projection built → `SendToAll` → Angular `.on(...)` | `realtime.send` → federation `pushes_to` → `realtime.subscribe` |
| MediatR | controller `Send(command)` → handler | `inprocess.send` → `dispatches_to` → `inprocess.handler` |
| `AUTHENTICATES_WITH`, policies | JWT bearer + policies on controllers | `ext.dotnet.authorization` on endpoints |
| environments, cloud resources | `appsettings.{Local,Docker,Dev}.json`, `terraform/*.tf` | `config.key` (no values), `infra.resource` |
| `SIMULATES` | WireMock test server for Pricing | observation in the test project, excluded from production traces by project role |

Ground truth for each repository is written from its source before the first engine run, committed, and its commit recorded (same rule as eShop).

## Order

1. `lab-core` and `lab-pricing` (packages first, they are dependencies). 2. `lab-intake`. 3. `lab-leasing`. 4. `lab-web`. 5. Ground truth per repository. 6. `system.yml` for federation in this repository.
