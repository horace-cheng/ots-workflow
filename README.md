# ots-workflow

Cloud Workflows orchestration layer for the OTS (Online Translation Service) pipeline. Manages the end-to-end translation pipeline across two tracks — **Fast Track** (automated, NMT-first) and **Literary Track** (human-in-the-loop) — triggered via Pub/Sub and executed as a sequence of Cloud Run Jobs.

## Architecture

```
Pub/Sub topic (ots-pipeline-trigger-{env})
    │
    └── Eventarc trigger
            │
            ▼
    ots-pipeline-router-{env}   ← inspects order.track_type via API
            │
    ┌───────┴───────┐
    ▼               ▼
Fast Track      Literary Track
```

### Fast Track (`ots-fast-track-{env}`)

Fully automated pipeline for standard translation orders.

| Step | Cloud Run Job | Description |
|------|--------------|-------------|
| 1 | `ots-ft-preprocess-{env}` | Segment source text, extract metadata |
| 2 | `ots-ft-nmt-{env}` | Machine translation via Gemini (Taiwanese → EN/JA/KO) |
| 3 | `ots-ft-qa-auto-{env}` | 4-layer auto QA: structure, semantic, terminology, LLM-as-judge |
| 4 | _(conditional)_ | Human QA review if `must_fix` flags exist — polls every 1h, times out after 24h |
| 5 | `ots-ft-deliver-{env}` | Package and deliver translation |

### Literary Track (`ots-literary-track-{env}`)

Human-in-the-loop pipeline for literary or high-complexity orders.

| Step | Description |
|------|-------------|
| 1 | Preprocess + NMT (AI draft) via `ots-lt-preprocess-nmt-{env}` |
| 2 | Notify admin to assign an editor |
| 3 | Poll for editor completion — 1h interval, 48h timeout |
| 4 | Notify admin to assign a proofreader |
| 5 | Poll for proofreading completion — 1h interval, 24h timeout |
| 6 | QA checklist via `ots-lt-qa-checklist-{env}` |
| 7 | Deliver via `ots-lt-deliver-{env}` |

### Router (`ots-pipeline-router-{env}`)

Sits between Eventarc and the two track workflows. Fetches the order from the API backend to determine `track_type`, then creates an execution on the appropriate workflow.

## GCP Resources

| Resource | Purpose |
|----------|---------|
| Cloud Workflows | Orchestrates each pipeline track |
| Eventarc | Bridges Pub/Sub messages to the router workflow |
| Pub/Sub `ots-pipeline-trigger-{env}` | Pipeline entry point — publish `{"order_id": "..."}` |
| Pub/Sub `ots-notify-{env}` | Outbound notification events |
| Pub/Sub `ots-pipeline-deadletter-{env}` | Dead-letter topic for failed trigger messages |
| Cloud Tasks `ots-notify-{env}` | Notification delivery queue |
| Cloud Tasks `ots-retry-{env}` | Pipeline step retry queue |
| Service Account `ots-workflow-{env}` | Workflow execution identity |

## Prerequisites

- GCP project `ots-translation` with billing enabled
- `gcloud` CLI authenticated with sufficient IAM permissions
- API backend (`ots-api-backend-{env}`) deployed to Cloud Run

## Setup

### 1. Bootstrap infrastructure

Run once per environment to create Pub/Sub topics, Cloud Tasks queues, and the Workflow service account:

```bash
./bootstrap_orchestration.sh [dev|staging|production]
```

This provisions:
- Pub/Sub topics and the pipeline trigger subscription (with dead-letter, 5 max delivery attempts)
- Cloud Tasks queues (`ots-notify-{env}`, `ots-retry-{env}`)
- Service account `ots-workflow-{env}` with required IAM roles

### 2. Deploy workflows

```bash
./deploy_workflows.sh [dev|staging|production]
```

This deploys:
- `ots-fast-track-{env}` — Fast Track workflow
- `ots-literary-track-{env}` — Literary Track workflow
- `ots-pipeline-router-{env}` — Router workflow
- `ots-pipeline-trigger-eventarc-{env}` — Eventarc trigger (Pub/Sub → router)

Re-run `deploy_workflows.sh` whenever workflow definitions change.

## Triggering a pipeline run

Publish a message to the pipeline trigger topic:

```bash
gcloud pubsub topics publish ots-pipeline-trigger-dev \
  --message='{"order_id": "YOUR_ORDER_ID"}' \
  --project=ots-translation
```

The router fetches the order from the API backend to determine `track_type` (`fast` or `literary`) and dispatches to the correct workflow.

## Monitoring

```bash
# List recent Fast Track executions
gcloud workflows executions list ots-fast-track-dev \
  --location=asia-east1 --project=ots-translation

# Describe a specific execution
gcloud workflows executions describe EXECUTION_ID \
  --workflow=ots-fast-track-dev \
  --location=asia-east1 --project=ots-translation

# Cancel a stuck execution
gcloud workflows executions cancel EXECUTION_ID \
  --workflow=ots-fast-track-dev \
  --location=asia-east1 --project=ots-translation
```

## Resource naming

All resources follow the pattern `ots-{component}-{env}` where `{env}` is `dev`, `staging`, or `production`. The GCP project is always `ots-translation` and the region is always `asia-east1`.

## Configuration

Workflows receive runtime configuration via environment variables set at deploy time (`--set-env-vars`):

| Variable | Description |
|----------|-------------|
| `ENV` | Deployment environment (`dev` / `staging` / `production`) |
| `API_BASE_URL` | Base URL of the `ots-api-backend-{env}` Cloud Run service |
