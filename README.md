[<img src="https://raw.githubusercontent.com/ifc7/ifc/main/docs/logo.svg" alt="IFC7 Logo" width="80">](https://ifc7.dev)

# ifc7 push action

Push new [ifc7.dev](https://ifc7.dev) revisions for every owned interface in your project's `ifc.yaml` whose file has changed.

For each `own` entry with a `ref`, the action compares the file on disk with the latest revision on the hub. If they differ, it pushes a new **revision** (a draft). Releases are still published by a person in the hub.

See [docs/how-it-works.md](docs/how-it-works.md) for the details of each step.

To check pull requests against your organization's governance gates before they merge, use [`ifc7/ifc-action/lint`](docs/lint.md).

## Usage

```yaml
name: Push interfaces

on:
  push:
    branches: [main]
    paths:
      - ifc.yaml
      - api/**

permissions:
  contents: read
  id-token: write # lets the action authenticate to ifc7.dev with GitHub OIDC

concurrency:
  group: ifc7-push
  cancel-in-progress: false

jobs:
  push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ifc7/ifc-action@v1
        with:
          organization: acme # slug of the ifc7 organization that owns the interfaces
```

Run it on pushes to your default branch, not on pull requests, so drafts on the hub track merged code. The `concurrency` group stops two runs from pushing the same change twice.

## Authentication

The action exchanges the job's GitHub OIDC token for a short-lived token for one of the organization's **agents** (bot members). No secrets are stored in the repository. The job needs `permissions: id-token: write`.

Before the first run, an organization admin creates an agent with the `editor` role and adds a **GitHub trust** to it for the repository. The trust limits which refs (default `refs/heads/main`), events, environment and workflow may use the agent. Revisions pushed by the action are attributed to the agent.

- If several agents trust the same workflow, set `agent` to choose one.
- If the exchange fails, the job shows the hub's message. For a missing trust, the message names the condition that didn't match. See [exchange errors](docs/how-it-works.md#exchange-errors).
- To use an agent token you already have, pass it as `token` from a secret. `organization` isn't needed then.

### Other hubs

Set `hub-url`. The OIDC audience defaults to the hub's host. Override `audience` only if the hub expects a different value.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `organization` | | **Required** (unless `token` is set). Slug of the ifc7 organization whose agent the workflow acts as. |
| `agent` | | Name or ID of the agent. Only needed when several of the organization's agents trust the workflow. |
| `working-directory` | `.` | Directory containing `ifc.yaml`. |
| `ifc-version` | `latest` | Release of the `ifc` CLI to install: a tag such as `v0.0.2`, or `latest`. Needs `v0.0.2` or later. |
| `notes` | HEAD commit subject and short SHA | Revision notes, e.g. `Add billing endpoints (abc1234)`. |
| `hub-url` | `https://ifc7.dev` | Base URL of the ifc7 hub. |
| `audience` | host of `hub-url` | Audience requested for the GitHub OIDC token. |
| `token` | | An ifc7 access token (e.g. an `ifc_agt_` agent token) to use instead of GitHub OIDC. |

## Outputs

| Output | Description |
| --- | --- |
| `pushed` | JSON array of owned interface names that received a new revision. |
| `skipped` | JSON array of owned interface names that were skipped. |
| `result` | The full JSON result from `ifc push --json`. |

## Behavior

- **Unchanged interfaces** are left alone.
- **`own` entries without a `ref`** (not yet created on the hub) are skipped with a warning annotation on `ifc.yaml`. Create them once locally with `ifc push`, then commit the updated `ifc.yaml`.
- **Failures** fail the job. Interfaces pushed before the failure are still reported in the outputs and the job summary.
- The action runs `ifc fetch --owned`, `ifc commit` and `ifc push` against a fresh `.ifc/` directory and never commits to your repository.

## Requirements

- Linux or macOS runners, amd64 or arm64, with `bash`, `curl`, `jq`, `tar` and `git` (all preinstalled on GitHub-hosted runners).
- The action downloads the CLI's release binary from [ifc7/ifc releases](https://github.com/ifc7/ifc/releases) and checks it against the release's `checksums.txt`. Go isn't needed.

## Development

```bash
bash test/push_test.sh      # runs scripts/push.sh against stub ifc and curl binaries
bash test/lint_test.sh      # runs scripts/lint.sh against stub ifc and curl binaries
bash test/install_test.sh   # runs scripts/install.sh against a fake release
shellcheck scripts/*.sh test/*.sh
actionlint
```
