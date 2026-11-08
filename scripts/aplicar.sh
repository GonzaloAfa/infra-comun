#!/usr/bin/env bash
# Crea o actualiza un stack con change set. DRY-RUN por defecto: muestra los cambios y no aplica.
#
#   scripts/aplicar.sh estatico lanelectric-sitio lanelectric Repo=GonzaloAfa/lanelectric_cl
#   scripts/aplicar.sh estatico lanelectric-sitio lanelectric Repo=… DominioCanonico=lanelectric.cl … --apply
#
# Argumentos: <plantilla: estatico|contacto> <stack> <proyecto> [Clave=Valor …] [--apply]
# Los parámetros que no se pasan conservan su valor anterior (UsePreviousValue) si el stack existe.
set -euo pipefail

PLANTILLA="${1:?plantilla (estatico|contacto|oidc-serverless|oidc-estatico|rearmado|cron-http)}"; STACK="${2:?stack}"; PROYECTO="${3:?proyecto}"; shift 3
APLICAR=0; PARAMS=()
for a in "$@"; do
  if [[ "$a" == "--apply" ]]; then APLICAR=1; else PARAMS+=("$a"); fi
done
REGION="${AWS_REGION:-us-east-1}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$DIR/$PLANTILLA/template.yaml"
[[ -f "$TPL" ]] || { echo "no existe $TPL" >&2; exit 1; }

PREVIOS=""
if aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" >/dev/null 2>&1; then
  TIPO=UPDATE
  # Solo los parámetros que el stack ya tiene admiten UsePreviousValue; uno nuevo toma su Default.
  PREVIOS=" $(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query 'Stacks[0].Parameters[].ParameterKey' --output text | tr '\t' ' ') "
else
  TIPO=CREATE
fi

# Proyecto siempre va; el resto, lo pasado + UsePreviousValue para lo que ya existía.
ARGS=("ParameterKey=Proyecto,ParameterValue=$PROYECTO")
DECLARADOS=$(aws cloudformation validate-template --region "$REGION" --template-body "file://$TPL" \
  --query 'Parameters[].ParameterKey' --output text)
for k in $DECLARADOS; do
  [[ "$k" == "Proyecto" ]] && continue
  v=""; dado=0
  for p in "${PARAMS[@]+"${PARAMS[@]}"}"; do
    if [[ "${p%%=*}" == "$k" ]]; then v="${p#*=}"; dado=1; fi
  done
  if [[ $dado == 1 ]]; then
    # Comas dentro de un valor (listas) van escapadas para la CLI.
    ARGS+=("ParameterKey=$k,ParameterValue=${v//,/\\,}")
  elif [[ $TIPO == UPDATE && "$PREVIOS" == *" $k "* ]]; then
    ARGS+=("ParameterKey=$k,UsePreviousValue=true")
  fi
done

CS="cs-$(date +%Y%m%d%H%M%S)"
aws cloudformation create-change-set --region "$REGION" --stack-name "$STACK" --change-set-name "$CS" \
  --change-set-type "$TIPO" --template-body "file://$TPL" --parameters "${ARGS[@]}" \
  --capabilities CAPABILITY_IAM --tags "Key=proyecto,Value=$PROYECTO" >/dev/null
echo "change set $CS ($TIPO $STACK)…"
if ! aws cloudformation wait change-set-create-complete --region "$REGION" --stack-name "$STACK" --change-set-name "$CS" 2>/dev/null; then
  aws cloudformation describe-change-set --region "$REGION" --stack-name "$STACK" --change-set-name "$CS" \
    --query 'StatusReason' --output text
  aws cloudformation delete-change-set --region "$REGION" --stack-name "$STACK" --change-set-name "$CS" || true
  [[ $TIPO == CREATE ]] && aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK" || true
  exit 0
fi
aws cloudformation describe-change-set --region "$REGION" --stack-name "$STACK" --change-set-name "$CS" \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output table

if [[ $APLICAR == 0 ]]; then
  echo "DRY-RUN: no se aplicó. Repite con --apply."
  aws cloudformation delete-change-set --region "$REGION" --stack-name "$STACK" --change-set-name "$CS"
  # Un CREATE en dry-run deja el stack en REVIEW_IN_PROGRESS: se borra para no dejar basura.
  [[ $TIPO == CREATE ]] && aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
  exit 0
fi

aws cloudformation execute-change-set --region "$REGION" --stack-name "$STACK" --change-set-name "$CS"
if [[ $TIPO == CREATE ]]; then W=stack-create-complete; else W=stack-update-complete; fi
aws cloudformation wait "$W" --region "$REGION" --stack-name "$STACK"
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
