#!/usr/bin/env bash
###############################################################################
# s3-sync.sh
# Cria bucket S3 e sincroniza arquivos usando credenciais temporarias do STS
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Variaveis
# ---------------------------------------------------------------------------
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Defina a variavel AWS_ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-sts-lab-role}"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
SESSION_NAME="sts-lab-s3-session-$(date +%s)"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXTERNAL_ID="${EXTERNAL_ID:-sts-lab-external-id}"
BUCKET_NAME="${BUCKET_NAME:-sts-lab-$(date +%Y%m%d)-${AWS_ACCOUNT_ID:0:8}}"
SYNC_DIR="${SYNC_DIR:-./sample-data}"

# ---------------------------------------------------------------------------
# Cores
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }

echo ""
echo "=============================================="
echo "  S3 Sync via STS Assume Role"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Verificar identidade atual
# ---------------------------------------------------------------------------
log_info "Identidade atual (usuario IAM):"
aws sts get-caller-identity --output table
echo ""

# ---------------------------------------------------------------------------
# 2. Assumir Role via STS
# ---------------------------------------------------------------------------
log_info "Assumindo role '${ROLE_NAME}' via STS..."

STS_CREDENTIALS=$(aws sts assume-role \
    --role-arn "${ROLE_ARN}" \
    --role-session-name "${SESSION_NAME}" \
    --external-id "${EXTERNAL_ID}" \
    --duration-seconds 3600 \
    --output json)

export AWS_ACCESS_KEY_ID=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.SessionToken')

EXPIRATION=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.Expiration')

log_ok "Credenciais temporarias obtidas!"
log_info "Access Key ID: ${AWS_ACCESS_KEY_ID:0:8}************"
log_info "Expiracao: ${EXPIRATION}"
echo ""

# ---------------------------------------------------------------------------
# 3. Verificar nova identidade
# ---------------------------------------------------------------------------
log_info "Nova identidade (role assumida):"
aws sts get-caller-identity --output table
echo ""

# ---------------------------------------------------------------------------
# 4. Criar diretorio de dados de exemplo (se nao existir)
# ---------------------------------------------------------------------------
if [ ! -d "${SYNC_DIR}" ]; then
    log_info "Criando diretorio de dados de exemplo: ${SYNC_DIR}"
    mkdir -p "${SYNC_DIR}"

    # Gerar arquivos de exemplo
    echo "# Relatorio do Lab STS Assume Role" > "${SYNC_DIR}/relatorio.md"
    echo "Data: $(date '+%Y-%m-%d %H:%M:%S')" >> "${SYNC_DIR}/relatorio.md"
    echo "Bucket: ${BUCKET_NAME}" >> "${SYNC_DIR}/relatorio.md"
    echo "Metodo: Credenciais temporarias via STS" >> "${SYNC_DIR}/relatorio.md"

    echo '{"lab": "sts-assume-role", "status": "completed", "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' \
        > "${SYNC_DIR}/metadata.json"

    echo "# Configuracao de exemplo" > "${SYNC_DIR}/config-sample.yaml"
    echo "region: ${AWS_REGION}" >> "${SYNC_DIR}/config-sample.yaml"
    echo "role_name: ${ROLE_NAME}" >> "${SYNC_DIR}/config-sample.yaml"
    echo "session_duration: 3600" >> "${SYNC_DIR}/config-sample.yaml"

    log_ok "Arquivos de exemplo criados"
fi

# ---------------------------------------------------------------------------
# 5. Criar bucket S3
# ---------------------------------------------------------------------------
log_info "Criando bucket S3: ${BUCKET_NAME}"

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    log_warn "Bucket '${BUCKET_NAME}' ja existe"
else
    if [ "${AWS_REGION}" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}"
    else
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}" \
            --create-bucket-configuration LocationConstraint="${AWS_REGION}"
    fi
    log_ok "Bucket criado"
fi

# ---------------------------------------------------------------------------
# 6. Adicionar tags ao bucket
# ---------------------------------------------------------------------------
log_info "Adicionando tags ao bucket..."

aws s3api put-bucket-tagging \
    --bucket "${BUCKET_NAME}" \
    --tagging 'TagSet=[{Key=Project,Value=sts-lab},{Key=CreatedBy,Value=sts-assume-role},{Key=Environment,Value=lab}]'

log_ok "Tags adicionadas"

# ---------------------------------------------------------------------------
# 7. Habilitar versionamento
# ---------------------------------------------------------------------------
log_info "Habilitando versionamento no bucket..."

aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

log_ok "Versionamento habilitado"

# ---------------------------------------------------------------------------
# 8. Sincronizar arquivos
# ---------------------------------------------------------------------------
log_info "Sincronizando arquivos de '${SYNC_DIR}' para s3://${BUCKET_NAME}/..."

aws s3 sync "${SYNC_DIR}" "s3://${BUCKET_NAME}/" \
    --region "${AWS_REGION}" \
    --delete

log_ok "Sync concluido!"

# ---------------------------------------------------------------------------
# 9. Listar objetos no bucket
# ---------------------------------------------------------------------------
echo ""
log_info "Objetos no bucket:"
aws s3 ls "s3://${BUCKET_NAME}/" --recursive --human-readable

# ---------------------------------------------------------------------------
# 10. Resumo
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  S3 Sync Completo via STS!"
echo "=============================================="
echo ""
log_info "Bucket:   s3://${BUCKET_NAME}"
log_info "Regiao:   ${AWS_REGION}"
log_info "Arquivos sincronizados de: ${SYNC_DIR}"
log_info "Credenciais expiram em: ${EXPIRATION}"
echo ""
log_warn "LEMBRE-SE: Delete o bucket apos o lab para evitar custos!"
log_info "aws s3 rb s3://${BUCKET_NAME} --force"
echo ""
