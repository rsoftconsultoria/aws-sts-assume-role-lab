# Lab AWS CLI: STS Assume Role - Zero Policies no Usuario

> O usuario IAM nao possui NENHUMA policy atachada. Todo o acesso a EC2 e S3 e feito exclusivamente via credenciais temporarias usando STS Assume Role.

## Sobre o Lab

Este laboratorio demonstra uma abordagem **Zero Trust** para acesso a recursos AWS. Em vez de atachar policies diretamente ao usuario IAM, todo o acesso e concedido atraves de **credenciais temporarias** geradas pelo AWS STS (Security Token Service).

### Por que essa abordagem?

- **Principio do menor privilegio**: O usuario so tem permissao para assumir uma role, nada mais
- **Credenciais temporarias**: AccessKeyId + SecretAccessKey + SessionToken expiram em 1 hora
- **Auditoria completa**: Cada assume-role gera um registro no CloudTrail
- **Revogacao imediata**: Basta alterar a Trust Policy para revogar o acesso
- **Seguranca real**: Mesmo que as credenciais do usuario vazem, nao ha acesso direto a nenhum recurso

## Arquitetura

```
+---------------------+         +------------------------+
|                     |         |                        |
|   Usuario IAM       |         |   IAM Role             |
|   (zero policies)   |         |   sts-lab-role         |
|                     |         |                        |
|   Permissao unica:  |  STS    |   Trust Policy:        |
|   sts:AssumeRole    +-------->+   Permite o usuario    |
|                     |         |   assumir esta role     |
|                     |         |                        |
+---------------------+         +----------+-------------+
                                           |
                                           | Credenciais Temporarias
                                           | (1h de validade)
                                           |
                        +------------------+------------------+
                        |                                     |
               +--------v---------+              +------------v-----------+
               |                  |              |                        |
               |   Amazon EC2     |              |   Amazon S3            |
               |                  |              |                        |
               |   - Lancamento   |              |   - Criar bucket       |
               |   - t2.micro     |              |   - Upload/Sync        |
               |   - Describe     |              |   - ListObjects        |
               |   - Terminate    |              |   - DeleteObject       |
               |                  |              |                        |
               +------------------+              +------------------------+

+------------------------------------------------------------------------+
|                         Fluxo de Execucao                              |
|                                                                        |
|  1. setup-iam-role.sh  -->  Cria Role + Trust Policy + Custom Policy   |
|  2. assume-role (STS)  -->  Gera credenciais temporarias (1h)          |
|  3. launch-ec2.sh      -->  Lanca EC2 t2.micro com creds temporarias   |
|  4. s3-sync.sh         -->  Cria bucket e sincroniza arquivos          |
|  5. diagnose.sh        -->  Valida todos os recursos criados           |
+------------------------------------------------------------------------+
```

## Pre-requisitos

- **AWS CLI v2** instalado e configurado (`aws --version`)
- **jq** instalado para parsing de JSON (`jq --version`)
- **Conta AWS** com acesso ao console IAM
- **Usuario IAM** com apenas a permissao `sts:AssumeRole` (inline policy)
- **Bash** 4.0+ (Linux/macOS/WSL)

### Configuracao inicial do usuario IAM

No console AWS, crie um usuario IAM com a seguinte inline policy (unica permissao):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::YOUR_ACCOUNT_ID:role/sts-lab-role"
    }
  ]
}
```

Configure o AWS CLI com as credenciais deste usuario:

```bash
aws configure --profile sts-lab-user
# AWS Access Key ID: <sua-access-key>
# AWS Secret Access Key: <sua-secret-key>
# Default region: us-east-1
# Default output: json
```

## Estrutura do Projeto

```
aws-sts-assume-role-lab/
├── README.md
├── LICENSE
├── .gitignore
├── policies/
│   ├── trust-policy.json        # Trust Policy da Role
│   └── ec2-s3-policy.json       # Policy customizada EC2 + S3
└── scripts/
    ├── setup-iam-role.sh        # Criacao da Role + Policies
    ├── launch-ec2.sh            # Lancamento de EC2 via STS
    ├── s3-sync.sh               # Sync S3 via STS
    └── diagnose.sh              # Diagnostico e validacao
```

## Passo a Passo

### 1. Configurar variaveis de ambiente

```bash
export AWS_ACCOUNT_ID="123456789012"       # Seu Account ID
export IAM_USER_NAME="sts-lab-user"        # Nome do usuario IAM
export ROLE_NAME="sts-lab-role"            # Nome da Role
export AWS_REGION="us-east-1"             # Regiao AWS
export AWS_PROFILE="sts-lab-user"          # Profile do AWS CLI
```

### 2. Criar a IAM Role com Trust Policy e Custom Policy

```bash
chmod +x scripts/*.sh
./scripts/setup-iam-role.sh
```

Este script cria:
- A IAM Role `sts-lab-role` com a Trust Policy
- A policy customizada `sts-lab-ec2-s3-policy` com permissoes granulares
- Atacha a policy na role

### 3. Lancar EC2 com credenciais temporarias

```bash
./scripts/launch-ec2.sh
```

O script:
1. Executa `aws sts assume-role` para obter credenciais temporarias
2. Exporta `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN`
3. Lanca uma instancia EC2 t2.micro com Amazon Linux 2023
4. Exibe o Instance ID e IP publico

### 4. Criar e sincronizar bucket S3

```bash
./scripts/s3-sync.sh
```

O script:
1. Assume a role via STS (credenciais temporarias)
2. Cria um bucket S3 com nome unico
3. Faz upload/sync de arquivos para o bucket
4. Lista os objetos para confirmar

### 5. Diagnostico e validacao

```bash
./scripts/diagnose.sh
```

Valida:
- Existencia da IAM Role e policies
- Status da instancia EC2
- Conteudo do bucket S3
- Validade das credenciais temporarias

## Limpeza de Recursos

Para evitar custos, execute apos o lab:

```bash
# Terminar a instancia EC2
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region us-east-1

# Esvaziar e deletar o bucket S3
aws s3 rb s3://<BUCKET_NAME> --force

# Remover a policy da role
aws iam detach-role-policy \
  --role-name sts-lab-role \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/sts-lab-ec2-s3-policy

# Deletar a policy
aws iam delete-policy \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/sts-lab-ec2-s3-policy

# Deletar a role
aws iam delete-role --role-name sts-lab-role
```

## Conceitos-Chave

| Conceito | Descricao |
|----------|-----------|
| **STS** | Security Token Service - gera credenciais temporarias |
| **AssumeRole** | Acao que permite um principal assumir permissoes de uma Role |
| **Trust Policy** | Define QUEM pode assumir a Role |
| **Session Token** | Token temporario que acompanha as credenciais STS |
| **Duracao** | Credenciais temporarias validas por 1 hora (padrao) |

## Seguranca

- Nunca commite credenciais AWS em repositorios
- Use `aws sts get-caller-identity` para verificar qual identidade esta ativa
- Credenciais temporarias expiram automaticamente
- Monitore assume-role events no CloudTrail

## Autor

**Rafael Sousa** - Cloud Architect & DevOps Engineer

- LinkedIn: [linkedin.com/in/sousarafael](https://linkedin.com/in/sousarafael)
- Site: [RSoft Consultoria](https://rsoftconsultoria.github.io/rsoft-site/) - Cloud & DevOps
- Plataforma: [Sentinel Tecnologia](https://sentinel-agents.com.br) - 18 Agentes IA para Cloud, DevOps e FinOps

---

### Mais Labs e Conteudo

Acesse nossos canais para mais laboratorios, automacoes e conteudos sobre Cloud, DevOps e FinOps:

| Canal | Link |
|-------|------|
| **RSoft Consultoria** | [rsoftconsultoria.github.io/rsoft-site](https://rsoftconsultoria.github.io/rsoft-site/) |
| **Sentinel Agents** | [sentinel-agents.com.br](https://sentinel-agents.com.br) |
| **GitHub RSoft** | [github.com/rsoftconsultoria](https://github.com/rsoftconsultoria) |

## Licenca

Este projeto esta licenciado sob a licenca MIT - veja o arquivo [LICENSE](LICENSE) para detalhes.

---

> Feito com dedicacao para a comunidade Cloud e DevOps brasileira.
