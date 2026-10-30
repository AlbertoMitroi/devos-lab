# lab

Design of the lab system used to validate `dotnet-intelligence`, `angular-intelligence` and `intelligence-federation` on the owner's architecture pattern (anonymized document: `../_shared/architecture/myproject-architecture.md`, local only). The lab repositories are siblings under `~/repos/devos/` and public on GitHub; they use neutral names only.

See [docs/DESIGN.md](docs/DESIGN.md).

## System generation

[`system.yml`](system.yml) describes the lab system for `intelligence-federation`: its five repositories, each with the
generation it publishes (`oci`), the routes between them and how messages are identified. The `system-context`
workflow ([`.github/workflows/system-context.yml`](.github/workflows/system-context.yml), script
[`scripts/system-context.sh`](scripts/system-context.sh)) pulls those generations, federates and verifies them, and
publishes the system generation to `ghcr.io/albertomitroi/context-systems` with the tags `lab-<inputs hash>` (immutable), `lab-main` and `lab.<repository>.<commit>` for every input (a working copy of a lab repository finds its system from its own commit). It runs
when a lab repository's `context` workflow reports a new generation (`repository_dispatch`, needs the secret
`DEVOS_LAB_DISPATCH_TOKEN` there) and by hand (`workflow_dispatch`). Layout and key:
devos-intelligence-federation `docs/PUBLISHING.md`.

Local dry run (Docker and jq; writes an OCI layout under `.system-context/oci` instead of pushing):

```bash
TARGET=ghcr.io/albertomitroi/context-systems scripts/system-context.sh
```

## License

MIT, see [LICENSE](LICENSE).
