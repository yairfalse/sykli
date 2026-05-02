# GitHub-native Sykli

Sykli can receive GitHub webhooks on a node in your own mesh, run the repository's execution graph locally, and report per-task Checks API state back to GitHub. This keeps execution local-first: GitHub sends events to hardware you control, and Sykli never operates a hosted control plane.

## 1. Label One Mesh Node

Choose the node that can receive HTTPS traffic and give it the receiver label:

```bash
export SYKLI_LABELS=webhook_receiver
```

Only the node holding this role starts the webhook listener. Other mesh nodes stay idle for GitHub intake.

## 2. Create A GitHub App

Create a GitHub App in your account or organization:

- Homepage URL: your project or internal docs URL.
- Webhook URL: `https://<your-endpoint>/webhook`.
- Webhook secret: generate a long random value.
- Repository permissions:
  - Checks: Read and write
  - Contents: Read-only
  - Metadata: Read-only
  - Pull requests: Read-only
- Subscribe to events:
  - Push
  - Pull request
  - Check run

Install the App on the repositories you want Sykli to observe.

## 3. Configure The Receiver

Set these environment variables on the receiver node:

```bash
export SYKLI_GITHUB_APP_ID=123456
export SYKLI_GITHUB_APP_PRIVATE_KEY=/path/to/github-app-private-key.pem
export SYKLI_GITHUB_WEBHOOK_SECRET='generated-webhook-secret'
export SYKLI_GITHUB_RECEIVER_PORT=8617
```

`SYKLI_GITHUB_APP_PRIVATE_KEY` can be either a file path or the PEM text itself.

## 4. Expose The Endpoint

GitHub must reach your receiver over HTTPS. Use the exposure method you operate:

- Tailscale Funnel
- Cloudflare Tunnel
- A public IP with TLS termination
- A short-lived development tunnel such as ngrok

Route external HTTPS traffic to:

```text
http://127.0.0.1:8617/webhook
```

Health checks are available at:

```text
GET /healthz
```

The endpoint returns `200` only on the node holding `webhook_receiver`; other nodes return `503`.

## 5. Verify The Loop

Start the Sykli node with the environment above, then trigger a push or PR update on a repository where the App is installed.

Expected result:

1. GitHub delivers the webhook to your receiver.
2. Sykli verifies `X-Hub-Signature-256`.
3. Sykli rejects duplicate `X-GitHub-Delivery` IDs.
4. Sykli exchanges the App JWT for an installation token.
5. Sykli creates a Check Suite.
6. Sykli clones the repository at the webhook head SHA with the installation token.
7. Sykli detects the `sykli.{go,rs,ts,exs,py}` file and builds the task graph.
8. Sykli creates one Check Run per task at `queued`.
9. Sykli runs the graph locally and transitions each Check Run through `in_progress` to its terminal conclusion.

You can inspect the queued suite with GitHub CLI:

```bash
gh api /repos/OWNER/REPO/check-suites --jq '.check_suites[] | {id, status, head_sha}'
```

Inspect the per-task runs with:

```bash
gh api /repos/OWNER/REPO/commits/HEAD/check-runs --jq '.check_runs[] | {name, status, conclusion}'
```

Task failures render the last task output lines in the Check Run summary. Infrastructure failures use the same `failure` conclusion as command failures, but the summary calls out the infrastructure failure explicitly.

## Occurrences

The receiver and dispatcher emit these GitHub-native occurrences:

- `ci.github.webhook.received`
- `ci.github.run.dispatched`
- `ci.github.check_suite.opened`
- `ci.github.run.source_acquired`
- `ci.github.run.source_failed`
- `ci.github.check_run.created`
- `ci.github.check_run.transitioned`
- `ci.github.check_run.transition_failed`
- `ci.github.check_suite.concluded`

These are regular Sykli occurrences and can be consumed through the same occurrence stream as local runs.
