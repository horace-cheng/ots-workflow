#!/usr/bin/env bash
# =============================================================================
# OTS — Orchestration Layer Bootstrap
# =============================================================================
# 建立 Pub/Sub topics、Cloud Tasks queues、Cloud Workflows SA
# 使用方式：./bootstrap_orchestration.sh [dev|staging|production]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

ENV="${1:-}"
[[ "$ENV" =~ ^(dev|staging|production)$ ]] || \
  err "請指定環境：./bootstrap_orchestration.sh [dev|staging|production]"

PROJECT_ID="ots-translation"
REGION="asia-east1"

# ── 命名 ──────────────────────────────────────────────────────────────────────
# Pub/Sub topics
TOPIC_PIPELINE="ots-pipeline-trigger-${ENV}"
TOPIC_NOTIFY="ots-notify-${ENV}"
TOPIC_DEADLETTER="ots-pipeline-deadletter-${ENV}"

# Pub/Sub subscriptions
SUB_WORKFLOW="ots-workflow-sub-${ENV}"

# Cloud Tasks queues
QUEUE_NOTIFY="ots-notify-${ENV}"
QUEUE_RETRY="ots-retry-${ENV}"

# Service Account for Cloud Workflows
SA_WORKFLOW_NAME="ots-workflow-${ENV}"
SA_WORKFLOW_EMAIL="${SA_WORKFLOW_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  OTS Orchestration Bootstrap — ENV: ${YELLOW}${ENV}${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

# ── 啟用 API ──────────────────────────────────────────────────────────────────
log "啟用必要 APIs..."
gcloud services enable \
  pubsub.googleapis.com \
  cloudtasks.googleapis.com \
  workflows.googleapis.com \
  workflowexecutions.googleapis.com \
  --quiet
ok "APIs 啟用完成"

# =============================================================================
# 1. SERVICE ACCOUNT for Cloud Workflows
# =============================================================================
log "建立 Cloud Workflows Service Account..."

if gcloud iam service-accounts describe "$SA_WORKFLOW_EMAIL" --quiet &>/dev/null; then
  warn "SA 已存在，跳過：$SA_WORKFLOW_NAME"
else
  gcloud iam service-accounts create "$SA_WORKFLOW_NAME" \
    --display-name="OTS Workflow [${ENV}]" \
    --description="Cloud Workflows orchestration service account - ${ENV}" \
    --quiet
  ok "SA 建立完成：$SA_WORKFLOW_NAME"
fi

# Workflow SA 需要的 roles
for role in \
  "roles/run.invoker" \
  "roles/run.developer" \
  "roles/workflows.invoker" \
  "roles/cloudtasks.enqueuer" \
  "roles/pubsub.publisher" \
  "roles/logging.logWriter" \
  "roles/storage.objectAdmin"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_WORKFLOW_EMAIL}" \
    --role="$role" \
    --condition=None \
    --quiet
done
ok "Workflow SA roles 授予完成"

# =============================================================================
# 2. PUB/SUB TOPICS & SUBSCRIPTIONS
# =============================================================================
log "建立 Pub/Sub topics..."

create_topic() {
  local topic="$1"
  if gcloud pubsub topics describe "$topic" --project="$PROJECT_ID" --quiet &>/dev/null; then
    warn "Topic 已存在，跳過：$topic"
  else
    gcloud pubsub topics create "$topic" --project="$PROJECT_ID" --quiet
    ok "Topic 建立完成：$topic"
  fi
}

create_topic "$TOPIC_PIPELINE"
create_topic "$TOPIC_NOTIFY"
create_topic "$TOPIC_DEADLETTER"

# Pipeline trigger subscription（Cloud Workflows 監聽）
log "建立 Pub/Sub subscription：$SUB_WORKFLOW ..."
if gcloud pubsub subscriptions describe "$SUB_WORKFLOW" --project="$PROJECT_ID" --quiet &>/dev/null; then
  warn "Subscription 已存在，跳過：$SUB_WORKFLOW"
else
  gcloud pubsub subscriptions create "$SUB_WORKFLOW" \
    --topic="$TOPIC_PIPELINE" \
    --ack-deadline=600 \
    --message-retention-duration=1d \
    --dead-letter-topic="$TOPIC_DEADLETTER" \
    --max-delivery-attempts=5 \
    --project="$PROJECT_ID" \
    --quiet
  ok "Subscription 建立完成：$SUB_WORKFLOW"
fi

# API Backend SA 需要 publisher 權限（才能發 pipeline trigger 訊息）
SA_API_EMAIL="ots-api-backend-${ENV}@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud pubsub topics add-iam-policy-binding "$TOPIC_PIPELINE" \
  --member="serviceAccount:${SA_API_EMAIL}" \
  --role="roles/pubsub.publisher" \
  --project="$PROJECT_ID" \
  --quiet
ok "API Backend SA publisher 權限設定完成"

# =============================================================================
# 3. CLOUD TASKS QUEUES
# =============================================================================
log "建立 Cloud Tasks queues..."

create_queue() {
  local queue="$1" max_attempts="$2" max_per_sec="$3"
  if gcloud tasks queues describe "$queue" \
       --location="$REGION" --project="$PROJECT_ID" --quiet &>/dev/null; then
    warn "Queue 已存在，跳過：$queue"
  else
    gcloud tasks queues create "$queue" \
      --location="$REGION" \
      --max-attempts="$max_attempts" \
      --max-dispatches-per-second="$max_per_sec" \
      --min-backoff=10s \
      --max-backoff=300s \
      --max-doublings=5 \
      --project="$PROJECT_ID" \
      --quiet
    ok "Queue 建立完成：$queue"
  fi
}

# 通知 queue：48hr deadline 通知、交付 email
create_queue "$QUEUE_NOTIFY" 3 1

# 重試 queue：pipeline 步驟失敗重試
create_queue "$QUEUE_RETRY" 5 2

# =============================================================================
# 4. 輸出摘要
# =============================================================================
echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Orchestration Bootstrap 完成 — ENV: ${YELLOW}${ENV}${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""
echo "  Pub/Sub topics   : $TOPIC_PIPELINE / $TOPIC_NOTIFY / $TOPIC_DEADLETTER"
echo "  Subscription     : $SUB_WORKFLOW"
echo "  Cloud Tasks      : $QUEUE_NOTIFY / $QUEUE_RETRY"
echo "  Workflow SA      : $SA_WORKFLOW_EMAIL"
echo ""
echo -e "${YELLOW}  後續步驟：${NC}"
echo "  執行 ./deploy_workflows.sh $ENV 部署 Cloud Workflows 定義"
echo ""
