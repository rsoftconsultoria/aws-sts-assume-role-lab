#!/usr/bin/env bash
###############################################################################
# setup-iam-role.sh
# Cria a IAM Role + Trust Policy + Custom Policy para o lab STS Assume Role
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Variaveis (altere conforme seu ambiente)
# ---------------------------------------------------------------------------
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Defina a variavel AWS_ACCOUNT_ID}"
IAM_USER_NAME="${IAM_USER_NAME:-sts-lab-user}"
ROLE_NAME="${ROLE_NAME:-sts-lab-role}"
POLICY_NAME="${POLICY_NAME:-sts-lab-ec2-s3-policy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXTERNAL_ID="${EXTERNAL_ID:-sts-lab-external-id}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/../policies"

# ---------------------------------------------------------------------------
# Cores para output
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

# ---------------------------------------------------------------------------
# Validacoes
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Setup IAM Role - STS Assume Role Lab"
echo "=============================================="
echo ""

log_info "Verificando pre-requisitos..."

if ! command -v aws &>/dev/null; then
    log_error "AWS CLI nao encontrado. Instale: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq nao encontrado. Instale: sudo apt install jq"
    exit 1
fi

log_ok "AWS CLI e jq encontrados"
log_info "Account ID: ${AWS_ACCOUNT_ID}"
log_info "Usuario IAM: ${IAM_USER_NAME}"
log_info "Role: ${ROLE_NAME}"
log_info "Regiao: ${AWS_REGION}"
echo ""

# ---------------------------------------------------------------------------
# 1. Preparar Trust Policy com valores reais
# ---------------------------------------------------------------------------
log_info "Preparando Trust Policy..."

TRUST_POLICY=$(cat "${POLICIES_DIR}/trust-policy.json" \
    | sed "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" \
    | sed "s/IAM_USER_NAME/${IAM_USER_NAME}/g")

log_ok "Trust Policy preparada"

# ---------------------------------------------------------------------------
# 2. Verificar se a Role ja existe
# ---------------------------------------------------------------------------
if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    log_warn "Role '${ROLE_NAME}' ja existe. Atualizando Trust Policy..."
    aws iam update-assume-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-document "${TRUST_POLICY}"
    log_ok "Trust Policy atualizada"
else
    log_info "Criando IAM Role '${ROLE_NAME}'..."
    aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --description "Role para lab STS Assume Role - acesso EC2 e S3 via credenciais temporarias" \
        --max-session-duration 3600 \
        --tags Key=Project,Value=sts-lab Key=ManagedBy,Value=cli \
        --output json | jq '.Role.Arn'
    log_ok "Role criada com sucesso"
fi

# ---------------------------------------------------------------------------
# 3. Criar ou atualizar Custom Policy
# ---------------------------------------------------------------------------
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "${POLICY_ARN}" &>/dev/null; then
    log_warn "Policy '${POLICY_NAME}' ja existe. Criando nova versao..."

    # Listar versoes e deletar a mais antiga se houver 5 (limite AWS)
    VERSIONS=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    VERSION_COUNT=$(echo "${VERSIONS}" | wc -w)

    if [ "${VERSION_COUNT}" -ge 4 ]; then
        OLDEST=$(echo "${VERSIONS}" | tr '\t' '\n' | tail -1)
        log_info "Removendo versao antiga: ${OLDEST}"
        aws iam delete-policy-version \
            --policy-arn "${POLICY_ARN}" \
            --version-id "${OLDEST}"
    fi

    aws iam create-policy-version \
        --policy-arn "${POLICY_ARN}" \
        --policy-document "file://${POLICIES_DIR}/ec2-s3-policy.json" \
        --set-as-default \
        --output json | jq '.PolicyVersion.VersionId'
    log_ok "Nova versao da policy criada"
else
    log_info "Criando policy '${POLICY_NAME}'..."
    aws iam create-policy \
        --policy-name "${POLICY_NAME}" \
        --policy-document "file://${POLICIES_DIR}/ec2-s3-policy.json" \
        --description "Permissoes granulares EC2 + S3 para lab STS" \
        --tags Key=Project,Value=sts-lab \
        --output json | jq '.Policy.Arn'
    log_ok "Policy criada"
fi

# ---------------------------------------------------------------------------
# 4. Atachar policy na role
# ---------------------------------------------------------------------------
log_info "Atachando policy na role..."

aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}"

log_ok "Policy atachada na role"

# ---------------------------------------------------------------------------
# 5. Resumo
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Setup Completo!"
echo "=============================================="
echo ""
log_info "Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
log_info "Policy ARN: ${POLICY_ARN}"
echo ""
log_info "Proximo passo: execute ./scripts/launch-ec2.sh"
echo ""
