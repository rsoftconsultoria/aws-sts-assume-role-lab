#!/usr/bin/env bash
###############################################################################
# launch-ec2.sh
# Lanca uma instancia EC2 t2.micro usando credenciais temporarias do STS
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Variaveis
# ---------------------------------------------------------------------------
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Defina a variavel AWS_ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-sts-lab-role}"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
SESSION_NAME="sts-lab-ec2-session-$(date +%s)"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXTERNAL_ID="${EXTERNAL_ID:-sts-lab-external-id}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"

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
echo "  EC2 Launch via STS Assume Role"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Verificar identidade atual (usuario IAM sem policies)
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

# Extrair credenciais temporarias
export AWS_ACCESS_KEY_ID=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.SessionToken')

EXPIRATION=$(echo "${STS_CREDENTIALS}" | jq -r '.Credentials.Expiration')

log_ok "Credenciais temporarias obtidas!"
log_info "Access Key ID: ${AWS_ACCESS_KEY_ID:0:8}************"
log_info "Expiracao: ${EXPIRATION}"
echo ""

# ---------------------------------------------------------------------------
# 3. Verificar nova identidade (role assumida)
# ---------------------------------------------------------------------------
log_info "Nova identidade (role assumida):"
aws sts get-caller-identity --output table
echo ""

# ---------------------------------------------------------------------------
# 4. Buscar AMI mais recente do Amazon Linux 2023
# ---------------------------------------------------------------------------
log_info "Buscando AMI mais recente do Amazon Linux 2023..."

AMI_ID=$(aws ec2 describe-images \
    --region "${AWS_REGION}" \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023.*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
    log_error "Nao foi possivel encontrar AMI do Amazon Linux 2023"
    exit 1
fi

log_ok "AMI encontrada: ${AMI_ID}"

# ---------------------------------------------------------------------------
# 5. Buscar VPC e Subnet padrao
# ---------------------------------------------------------------------------
log_info "Buscando VPC e Subnet padrao..."

VPC_ID=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[0].SubnetId' \
    --output text)

log_ok "VPC: ${VPC_ID} | Subnet: ${SUBNET_ID}"

# ---------------------------------------------------------------------------
# 6. Buscar Security Group padrao
# ---------------------------------------------------------------------------
SG_ID=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

log_ok "Security Group: ${SG_ID}"

# ---------------------------------------------------------------------------
# 7. Lancar instancia EC2
# ---------------------------------------------------------------------------
log_info "Lancando instancia EC2 ${INSTANCE_TYPE}..."

INSTANCE_OUTPUT=$(aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${SG_ID}" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=sts-lab-instance},{Key=Project,Value=sts-lab},{Key=CreatedBy,Value=sts-assume-role},{Key=Environment,Value=lab}]" \
    --output json)

INSTANCE_ID=$(echo "${INSTANCE_OUTPUT}" | jq -r '.Instances[0].InstanceId')

log_ok "Instancia lancada: ${INSTANCE_ID}"

# ---------------------------------------------------------------------------
# 8. Aguardar instancia ficar running
# ---------------------------------------------------------------------------
log_info "Aguardando instancia ficar no estado 'running'..."

aws ec2 wait instance-running \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}"

log_ok "Instancia esta running!"

# ---------------------------------------------------------------------------
# 9. Obter IP publico
# ---------------------------------------------------------------------------
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

PRIVATE_IP=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

# ---------------------------------------------------------------------------
# 10. Resumo
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  EC2 Lancada com Sucesso via STS!"
echo "=============================================="
echo ""
log_info "Instance ID:  ${INSTANCE_ID}"
log_info "Instance Type: ${INSTANCE_TYPE}"
log_info "AMI:          ${AMI_ID}"
log_info "IP Publico:   ${PUBLIC_IP}"
log_info "IP Privado:   ${PRIVATE_IP}"
log_info "Regiao:       ${AWS_REGION}"
log_info "Credenciais expiram em: ${EXPIRATION}"
echo ""
log_warn "LEMBRE-SE: Termine a instancia apos o lab para evitar custos!"
log_info "aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
echo ""
