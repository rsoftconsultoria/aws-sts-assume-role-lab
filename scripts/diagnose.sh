#!/usr/bin/env bash
###############################################################################
# diagnose.sh
# Diagnostico e validacao de todos os recursos do lab STS Assume Role
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Variaveis
# ---------------------------------------------------------------------------
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Defina a variavel AWS_ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-sts-lab-role}"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
POLICY_NAME="${POLICY_NAME:-sts-lab-ec2-s3-policy}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXTERNAL_ID="${EXTERNAL_ID:-sts-lab-external-id}"

# ---------------------------------------------------------------------------
# Cores e contadores
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
check_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
log_info()   { echo -e "${CYAN}[INFO]${NC} $1"; }

echo ""
echo "=============================================="
echo "  Diagnostico - STS Assume Role Lab"
echo "=============================================="
echo "  Data: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Account: ${AWS_ACCOUNT_ID}"
echo "  Regiao: ${AWS_REGION}"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Verificar AWS CLI
# ---------------------------------------------------------------------------
echo -e "${BOLD}1. AWS CLI${NC}"

if command -v aws &>/dev/null; then
    AWS_VERSION=$(aws --version 2>&1)
    check_pass "AWS CLI instalado: ${AWS_VERSION}"
else
    check_fail "AWS CLI nao encontrado"
fi

if command -v jq &>/dev/null; then
    check_pass "jq instalado: $(jq --version)"
else
    check_warn "jq nao encontrado (recomendado para parsing JSON)"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Verificar identidade
# ---------------------------------------------------------------------------
echo -e "${BOLD}2. Identidade IAM${NC}"

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null || echo "")

if [ -n "${CALLER_IDENTITY}" ]; then
    CALLER_ARN=$(echo "${CALLER_IDENTITY}" | jq -r '.Arn')
    CALLER_ACCOUNT=$(echo "${CALLER_IDENTITY}" | jq -r '.Account')
    check_pass "Identidade: ${CALLER_ARN}"

    if [ "${CALLER_ACCOUNT}" = "${AWS_ACCOUNT_ID}" ]; then
        check_pass "Account ID confere: ${CALLER_ACCOUNT}"
    else
        check_fail "Account ID diverge: esperado ${AWS_ACCOUNT_ID}, obtido ${CALLER_ACCOUNT}"
    fi
else
    check_fail "Nao foi possivel obter identidade (verifique credenciais)"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Verificar IAM Role
# ---------------------------------------------------------------------------
echo -e "${BOLD}3. IAM Role${NC}"

if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    ROLE_INFO=$(aws iam get-role --role-name "${ROLE_NAME}" --output json)
    ROLE_ARN_ACTUAL=$(echo "${ROLE_INFO}" | jq -r '.Role.Arn')
    MAX_SESSION=$(echo "${ROLE_INFO}" | jq -r '.Role.MaxSessionDuration')
    check_pass "Role existe: ${ROLE_ARN_ACTUAL}"
    check_pass "Max session duration: ${MAX_SESSION}s"

    # Verificar Trust Policy
    TRUST_POLICY=$(echo "${ROLE_INFO}" | jq -r '.Role.AssumeRolePolicyDocument')
    TRUSTED_PRINCIPAL=$(echo "${TRUST_POLICY}" | jq -r '.Statement[0].Principal.AWS // empty')

    if [ -n "${TRUSTED_PRINCIPAL}" ]; then
        check_pass "Trust Policy - Principal: ${TRUSTED_PRINCIPAL}"
    else
        check_warn "Trust Policy - Principal nao encontrado no formato esperado"
    fi
else
    check_fail "Role '${ROLE_NAME}' nao encontrada"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Verificar Policy
# ---------------------------------------------------------------------------
echo -e "${BOLD}4. Custom Policy${NC}"

if aws iam get-policy --policy-arn "${POLICY_ARN}" &>/dev/null; then
    POLICY_INFO=$(aws iam get-policy --policy-arn "${POLICY_ARN}" --output json)
    ATTACHMENT_COUNT=$(echo "${POLICY_INFO}" | jq -r '.Policy.AttachmentCount')
    check_pass "Policy existe: ${POLICY_ARN}"
    check_pass "Atachada em ${ATTACHMENT_COUNT} entidade(s)"

    # Verificar se esta atachada na role
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
        --role-name "${ROLE_NAME}" \
        --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyName" \
        --output text 2>/dev/null || echo "")

    if [ -n "${ATTACHED_POLICIES}" ]; then
        check_pass "Policy atachada na role '${ROLE_NAME}'"
    else
        check_fail "Policy NAO esta atachada na role '${ROLE_NAME}'"
    fi
else
    check_fail "Policy '${POLICY_NAME}' nao encontrada"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Testar STS Assume Role
# ---------------------------------------------------------------------------
echo -e "${BOLD}5. STS Assume Role${NC}"

STS_RESULT=$(aws sts assume-role \
    --role-arn "${ROLE_ARN}" \
    --role-session-name "diagnose-session-$(date +%s)" \
    --external-id "${EXTERNAL_ID}" \
    --duration-seconds 900 \
    --output json 2>/dev/null || echo "")

if [ -n "${STS_RESULT}" ]; then
    STS_ACCESS_KEY=$(echo "${STS_RESULT}" | jq -r '.Credentials.AccessKeyId')
    STS_EXPIRATION=$(echo "${STS_RESULT}" | jq -r '.Credentials.Expiration')
    ASSUMED_ARN=$(echo "${STS_RESULT}" | jq -r '.AssumedRoleUser.Arn')

    check_pass "Assume Role bem-sucedido"
    check_pass "Session ARN: ${ASSUMED_ARN}"
    check_pass "Access Key temporaria: ${STS_ACCESS_KEY:0:8}************"
    check_pass "Expiracao: ${STS_EXPIRATION}"

    # Testar com credenciais temporarias
    export AWS_ACCESS_KEY_ID=$(echo "${STS_RESULT}" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "${STS_RESULT}" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "${STS_RESULT}" | jq -r '.Credentials.SessionToken')

    TEMP_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null || echo "")
    if [ -n "${TEMP_IDENTITY}" ]; then
        check_pass "Credenciais temporarias funcionando"
    else
        check_fail "Credenciais temporarias nao funcionam"
    fi
else
    check_fail "Assume Role falhou (verifique Trust Policy e permissoes)"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Verificar recursos EC2 do lab
# ---------------------------------------------------------------------------
echo -e "${BOLD}6. Recursos EC2${NC}"

EC2_INSTANCES=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Project,Values=sts-lab" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PublicIpAddress]' \
    --output json 2>/dev/null || echo "[]")

INSTANCE_COUNT=$(echo "${EC2_INSTANCES}" | jq 'length')

if [ "${INSTANCE_COUNT}" -gt 0 ]; then
    check_pass "Encontrada(s) ${INSTANCE_COUNT} instancia(s) do lab:"
    echo "${EC2_INSTANCES}" | jq -r '.[] | "    ID: \(.[0]) | Tipo: \(.[1]) | Estado: \(.[2]) | IP: \(.[3] // "N/A")"'
else
    check_warn "Nenhuma instancia EC2 do lab encontrada (pode ja ter sido terminada)"
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Verificar recursos S3 do lab
# ---------------------------------------------------------------------------
echo -e "${BOLD}7. Recursos S3${NC}"

S3_BUCKETS=$(aws s3api list-buckets --query 'Buckets[?starts_with(Name, `sts-lab`)].Name' --output json 2>/dev/null || echo "[]")
BUCKET_COUNT=$(echo "${S3_BUCKETS}" | jq 'length')

if [ "${BUCKET_COUNT}" -gt 0 ]; then
    check_pass "Encontrado(s) ${BUCKET_COUNT} bucket(s) do lab:"
    for BUCKET in $(echo "${S3_BUCKETS}" | jq -r '.[]'); do
        OBJECT_COUNT=$(aws s3api list-objects-v2 --bucket "${BUCKET}" --query 'KeyCount' --output text 2>/dev/null || echo "0")
        echo "    Bucket: ${BUCKET} | Objetos: ${OBJECT_COUNT}"
    done
else
    check_warn "Nenhum bucket S3 do lab encontrado (pode ja ter sido deletado)"
fi
echo ""

# Limpar credenciais temporarias
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# ---------------------------------------------------------------------------
# 8. Resumo
# ---------------------------------------------------------------------------
echo "=============================================="
echo -e "  ${BOLD}Resumo do Diagnostico${NC}"
echo "=============================================="
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC}"
echo -e "  ${RED}FAIL: ${FAIL}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN}${NC}"
echo ""

if [ "${FAIL}" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}Status: TODOS OS CHECKS PASSARAM!${NC}"
else
    echo -e "  ${RED}${BOLD}Status: ${FAIL} CHECK(S) FALHARAM - VERIFICAR${NC}"
fi

echo ""
echo "=============================================="
exit "${FAIL}"
