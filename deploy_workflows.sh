#!/usr/bin/env bash
# =============================================================================
# OTS — 部署 Cloud Workflows + Eventarc Trigger
# =============================================================================
# 1. 部署 fast_track.yaml 和 literary_track.yaml 到 Cloud Workflows
# 2. 建立 Eventarc trigger：Pub/Sub 訊息 → 自動觸發對應 Workflow
#
# 使用方式：./deploy_workflows.sh [dev|staging|production]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

ENV="${1:-}"
[[ "$ENV" =~ ^(dev|staging|production)$ ]] || \
  err "請指定環境：./deploy_workflows.sh [dev|staging|production]"

PROJECT_ID="ots-translation"
REGION="asia-east1"
SA_WORKFLOW_EMAIL="ots-workflow-${ENV}@${PROJECT_ID}.iam.gserviceaccount.com"
TOPIC_PIPELINE="ots-pipeline-trigger-${ENV}"
WORKFLOW_FT="ots-fast-track-${ENV}"
WORKFLOW_LT="ots-literary-track-${ENV}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Deploy Workflows — ENV: ${YELLOW}${ENV}${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

# ── 啟用 Eventarc API ─────────────────────────────────────────────────────────
log "啟用 Eventarc API..."
gcloud services enable eventarc.googleapis.com --quiet
ok "Eventarc API 啟用完成"

# ── 授予 Eventarc SA 必要權限 ─────────────────────────────────────────────────
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
EVENTARC_SA="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"
# Eventarc SA 授權移至 trigger 建立後執行

# =============================================================================
# 1. 部署 Fast Track Workflow
# =============================================================================
# 取得 API Backend URL（service 名稱含 ENV suffix）
API_BASE_URL=$(gcloud run services describe "ots-api-backend-${ENV}" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(status.url)" 2>/dev/null || echo "")

if [[ -z "$API_BASE_URL" ]]; then
  warn "ots-api-backend-${ENV} service not found, using placeholder"
  API_BASE_URL="https://placeholder.run.app"
fi
log "API Base URL: $API_BASE_URL"

log "部署 Fast Track Workflow：$WORKFLOW_FT ..."
gcloud workflows deploy "$WORKFLOW_FT" \
  --location="$REGION" \
  --source="${SCRIPT_DIR}/workflows/fast_track.yaml" \
  --service-account="$SA_WORKFLOW_EMAIL" \
  --set-env-vars="ENV=${ENV},API_BASE_URL=${API_BASE_URL}" \
  --project="$PROJECT_ID" \
  --quiet
ok "Fast Track Workflow 部署完成：$WORKFLOW_FT"

# =============================================================================
# 2. 部署 Literary Track Workflow
# =============================================================================
log "部署 Literary Track Workflow：$WORKFLOW_LT ..."
gcloud workflows deploy "$WORKFLOW_LT" \
  --location="$REGION" \
  --source="${SCRIPT_DIR}/workflows/literary_track.yaml" \
  --service-account="$SA_WORKFLOW_EMAIL" \
  --set-env-vars="ENV=${ENV},API_BASE_URL=${API_BASE_URL}" \
  --project="$PROJECT_ID" \
  --quiet
ok "Literary Track Workflow 部署完成：$WORKFLOW_LT"

# =============================================================================
# 3. Eventarc Trigger：Pub/Sub → Workflow Router
# =============================================================================
# Eventarc 不能直接根據 message body 路由到不同 workflow
# 所以用一個 Router workflow 來做 track_type 判斷

WORKFLOW_ROUTER="ots-pipeline-router-${ENV}"

log "部署 Pipeline Router Workflow：$WORKFLOW_ROUTER ..."
cat > /tmp/pipeline_router.yaml << 'ROUTER_YAML'
main:
  params: [args]
  steps:
    - decode_message:
        assign:
          - message_data: ${base64.decode(args.data.message.data)}
          - payload: ${json.decode(message_data)}
          - order_id: ${payload.order_id}
          - project_id: ${sys.get_env("GOOGLE_CLOUD_PROJECT_ID")}
          - region: "asia-east1"
          - pipeline_env: ${sys.get_env("ENV", "dev")}
          - api_base: ${sys.get_env("API_BASE_URL")}
    - build_exec_args:
        assign:
          - exec_args:
              order_id: ${order_id}
    - get_track_type:
        call: http.get
        args:
          url: '${api_base + "/internal/orders/" + order_id}'
          auth:
            type: OIDC
        result: order_response
    - route_by_track:
        switch:
          - condition: ${order_response.body.track_type == "literary"}
            steps:
              - execute_literary:
                  call: googleapis.workflowexecutions.v1.projects.locations.workflows.executions.create
                  args:
                    parent: '${"projects/" + project_id + "/locations/" + region + "/workflows/ots-literary-track-" + pipeline_env}'
                    body:
                      argument: ${json.encode_to_string(exec_args)}
                  result: lt_execution
              - return_literary:
                  return: ${lt_execution}
          - condition: true
            steps:
              - execute_fast:
                  call: googleapis.workflowexecutions.v1.projects.locations.workflows.executions.create
                  args:
                    parent: '${"projects/" + project_id + "/locations/" + region + "/workflows/ots-fast-track-" + pipeline_env}'
                    body:
                      argument: ${json.encode_to_string(exec_args)}
                  result: ft_execution
              - return_fast:
                  return: ${ft_execution}
ROUTER_YAML

gcloud workflows deploy "$WORKFLOW_ROUTER" \
  --location="$REGION" \
  --source="/tmp/pipeline_router.yaml" \
  --service-account="$SA_WORKFLOW_EMAIL" \
  --set-env-vars="ENV=${ENV},API_BASE_URL=${API_BASE_URL}" \
  --project="$PROJECT_ID" \
  --quiet
ok "Router Workflow 部署完成：$WORKFLOW_ROUTER"

# ── Eventarc Trigger ──────────────────────────────────────────────────────────
TRIGGER_NAME="ots-pipeline-trigger-eventarc-${ENV}"

log "建立 Eventarc Trigger：$TRIGGER_NAME ..."
if gcloud eventarc triggers describe "$TRIGGER_NAME" \
     --location="$REGION" --project="$PROJECT_ID" --quiet &>/dev/null; then
  warn "Trigger 已存在，更新..."
  gcloud eventarc triggers update "$TRIGGER_NAME" \
    --location="$REGION" \
    --destination-workflow="$WORKFLOW_ROUTER" \
    --destination-workflow-location="$REGION" \
    --project="$PROJECT_ID" \
    --quiet
else
  gcloud eventarc triggers create "$TRIGGER_NAME" \
    --location="$REGION" \
    --event-filters="type=google.cloud.pubsub.topic.v1.messagePublished" \
    --transport-topic="$TOPIC_PIPELINE" \
    --destination-workflow="$WORKFLOW_ROUTER" \
    --destination-workflow-location="$REGION" \
    --service-account="$SA_WORKFLOW_EMAIL" \
    --project="$PROJECT_ID" \
    --quiet
fi
ok "Eventarc Trigger 建立完成：$TRIGGER_NAME"

# ── Eventarc SA 授權（trigger 建立後 SA 才會存在）──────────────────────────
log "授予 Eventarc SA 權限（等待 SA 建立）..."
sleep 10
for role in roles/workflows.invoker roles/pubsub.subscriber; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${EVENTARC_SA}" \
    --role="$role" \
    --condition=None \
    --quiet 2>/dev/null && ok "Granted ${role} to Eventarc SA" || \
    warn "Could not grant ${role} — SA may not exist yet, grant manually if needed"
done

# ── 輸出摘要 ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Workflows 部署完成 — ENV: ${YELLOW}${ENV}${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""
echo "  Fast Track  : $WORKFLOW_FT"
echo "  Literary    : $WORKFLOW_LT"
echo "  Router      : $WORKFLOW_ROUTER"
echo "  Trigger     : $TRIGGER_NAME"
echo "  Pub/Sub     : $TOPIC_PIPELINE → Router → FT / LT"
echo ""
echo -e "${YELLOW}  測試方式：${NC}"
echo "  # 手動發布測試訊息到 Pub/Sub"
echo "  gcloud pubsub topics publish $TOPIC_PIPELINE \\"
echo "    --message='{\"order_id\": \"YOUR_ORDER_ID\"}' \\"
echo "    --project=$PROJECT_ID"
echo ""
echo "  # 查看 Workflow 執行狀態"
echo "  gcloud workflows executions list $WORKFLOW_FT \\"
echo "    --location=$REGION --project=$PROJECT_ID"
echo ""
