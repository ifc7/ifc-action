# The lint action

`ifc7/ifc-action/lint` runs `ifc lint` on pull requests, so a change the hub would refuse fails the check before it merges. It reports each counted finding as an annotation on its line, each failed gate as an annotation on the interface's file, and a table in the job summary.

## Usage

```yaml
name: Lint interfaces

on:
  pull_request:
    paths:
      - ifc.yaml
      - api/**

permissions:
  contents: read
  id-token: write # lets the action read the interfaces' governance policy with GitHub OIDC

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ifc7/ifc-action/lint@v1
        with:
          organization: acme
```

By default the action evaluates the hub's **push** gates for every owned interface: the same gates, effective ruleset, waivers and baseline release the hub uses when the revision is pushed. It fails when a blocking gate fails. Advisory failures show as warnings and don't fail the job unless `strict: true`.

### Authentication for pull requests

The action reads each interface's effective policy and latest release, which needs a token. The default GitHub trust (`refs/heads/main`, push events) doesn't match a pull request, so an organization admin adds a second trust with the `read` profile:

```
POST /api/v0/organizations/{organizationId}/agents/{agentId}/github-trusts
{"repository": "acme/api", "refPattern": "refs/pull/*/merge", "allowedEvents": ["pull_request"], "profile": "read"}
```

Pull requests from forks get no OIDC token, so the hub's gates can't run there. Use the local mode below for those, or skip the job with `if: github.event.pull_request.head.repo.full_name == github.repository`.

### Checking a release

To check a release before publishing it, for example on a tag:

```yaml
      - uses: ifc7/ifc-action/lint@v1
        with:
          organization: acme
          gate: release
          release-version: ${{ github.ref_name }}
```

`breaking: requireMajor` gates compare with the highest release below `release-version`, as the hub does.

### Without the hub

With `gate: ""` the action needs no token. It lints with the built-in ruleset, or with `ruleset`, and fails only on the gates you set:

```yaml
      - uses: ifc7/ifc-action/lint@v1
        with:
          gate: ""
          ruleset: openlint.yaml   # may extend public ifc7 rulesets: https://ifc7.dev/r/{owner}/{slug}/v{n}
          fail-on: error
          baseline: api/v0.released.yaml
          breaking: block
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `organization` | | Slug of the ifc7 organization whose agent the workflow acts as. Needed with `gate` or `hub` unless `token` is set. |
| `agent` | | Name or ID of the agent, when several of the organization's agents trust the workflow. |
| `token` | | An ifc7 access token to use instead of GitHub OIDC. |
| `working-directory` | `.` | Directory containing `ifc.yaml`. |
| `interfaces` | every owned interface | Owned interface names or specification paths, separated by spaces or newlines. |
| `gate` | `push` | Evaluate the hub's gates for `push` or `release`. `""` skips them. |
| `hub` | `false` | With `gate: ""`, still lint with the hub's policy (ruleset, weights, waivers). |
| `release-version` | | The version being released. Required with `gate: release`. |
| `ruleset` | | A local OpenLint ruleset file. Only with `gate: ""` and `hub: false`. |
| `baseline` | the hub's release | A specification file to compare with, or `none`. |
| `baseline-version` | | The version of the `baseline` file, for `requireMajor`. |
| `fail-on` | | Also fail on an unwaived finding at this severity or above: `error`, `warn`, `info` or `hint`. |
| `min-score` | | Also fail when an interface scores below this. |
| `breaking` | | Also fail on breaking changes against the baseline: `block`, or `requireMajor` with `gate: release`. |
| `new-only` | `false` | With `fail-on`, count only findings that aren't in the baseline. |
| `strict` | `false` | Fail on advisory gates too. |
| `annotations` | `warn` | Lowest finding severity to annotate (`error`, `warn`, `info`, `hint`), or `none`. Gate failures are always annotated. |
| `ifc-version` | `latest` | Release of the `ifc` CLI to install. Needs `v0.0.3` or later. |
| `hub-url` | `https://ifc7.dev` | Base URL of the ifc7 hub. |
| `audience` | host of `hub-url` | Audience requested for the GitHub OIDC token. |

`fail-on`, `min-score`, `breaking` and `new-only` together add one blocking gate named `cli`, next to the hub's gates.

## Outputs

| Output | Description |
| --- | --- |
| `passed` | `"true"` when every interface was linted and no blocking gate failed (with `strict`, no gate at all). |
| `result` | The full JSON report from `ifc lint --json`. |

## How it works

1. Installs the CLI, as the push action does.
2. Authenticates when it needs the hub, exactly like the push action (see [Authenticating](how-it-works.md#2-authenticating)).
3. Runs `ifc lint --json` with the flags from the inputs in `working-directory`. See `ifc lint --help` for what each flag does.
4. Turns the report into annotations, the `passed` and `result` outputs and a job summary.

The job fails with exit status 2 when a gate blocks, and 1 when an interface couldn't be linted (for example an owned interface without a `ref` while the hub's gates are on).
