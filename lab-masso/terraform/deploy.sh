#!/usr/bin/env bash
# deploy.sh  Deployment for Cats as a top Service
#
# By default, clears a prior failed/partial deploy: terraform destroy when state is non-empty,
# then removes fixed-name orphans that are not in state. Set SKIP_DEPLOY_CLEANUP=1 to skip
# this and run a plain apply (updates in place).
set -euo pipefail

cd "$(dirname "$0")"

# Keep in sync with variable "aws_region" default in main.tf
LAB_REGION="${TF_VAR_aws_region:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

echo ">>> [1/4] Initializing environment..."
terraform init -upgrade -input=false > /dev/null

if [ "${SKIP_DEPLOY_CLEANUP:-0}" != "1" ]; then
  echo ">>> [2/4] Cleaning leftovers from a prior run (partial apply / lost state)..."
  STATE_LIST="$(terraform state list 2>/dev/null || true)"
  if [ -n "$STATE_LIST" ]; then
    echo "    Terraform state is non-empty; destroying managed resources first..."
    terraform destroy -auto-approve
  else
    echo "    No Terraform state; skipping destroy."
  fi

  echo "    Removing fixed-name orphans if present (app log group)..."
  aws logs delete-log-group --log-group-name "/ecs/demolab1-app" --region "$LAB_REGION" 2>/dev/null || true
else
  echo ">>> [2/4] Skipping cleanup (SKIP_DEPLOY_CLEANUP=1)."
fi

# Build Lambda source zips if missing (e.g. after destroy.sh or fresh clone)
for fn in pre_authentication pre_signup jit_provisioning; do
  if [ ! -f "${fn}.zip" ]; then
    echo "    Zipping missing Lambda: ${fn}.py"
    (cd ../lambdas && zip -j "$OLDPWD/${fn}.zip" "${fn}.py" -q)
  fi
done


echo ">>> [3/4] Applying infrastructure changes..."
terraform apply -auto-approve

REGION=$(terraform output -raw region)
CLUSTER=$(terraform output -raw ecs_cluster_name)

echo ">>> [4/4] Waiting for ECS service to stabilize (often 1–3 minutes)..."
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "demolab1-app" \
  --region "$REGION"

APP_DNS=""

get_task_dns() {
  local svc=$1
  local task_arn=$(aws ecs list-tasks --service-name "$svc" --cluster "$CLUSTER" --region "$REGION" --query 'taskArns[0]' --output text)
  if [ "$task_arn" == "None" ] || [ -z "$task_arn" ]; then return 1; fi

  local eni=$(aws ecs describe-tasks --tasks "$task_arn" --cluster "$CLUSTER" --region "$REGION" \
    --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
  if [ -z "$eni" ]; then return 1; fi

  aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
    --query 'NetworkInterfaces[0].Association.PublicDnsName' --output text --region "$REGION"
}

APP_DNS=$(get_task_dns "demolab1-app") || true

if [ -z "$APP_DNS" ] || [ "$APP_DNS" == "None" ]; then
  echo "ERROR: Could not retrieve Public DNS for app service."
  exit 1
fi


POOL_ID=$(terraform output -raw user_pool_id)
CLIENT_ID=$(terraform output -raw app_client_id)

echo "    Post-processing: Updating Cognito callback + support@acme.org account"
aws cognito-idp update-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-id   "$CLIENT_ID" \
  --callback-urls "https://$APP_DNS/callback" \
  --logout-urls   "https://$APP_DNS/" \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes email openid profile \
  --supported-identity-providers COGNITO \
  --allowed-o-auth-flows-user-pool-client \
  --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_ADMIN_USER_PASSWORD_AUTH \
  --read-attributes email name "custom:tenantID" "custom:isOrgAdmin" "custom:orgName" \
  --write-attributes email name "custom:tenantID" "custom:isOrgAdmin" "custom:orgName" \
  --region "$REGION" > /dev/null

aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username "support@acme.org" \
  --user-attributes Name=email,Value="support@acme.org" Name=email_verified,Value=true Name="custom:tenantID",Value="PLATFORM_SEED" \
  --message-action SUPPRESS --region "$REGION" > /dev/null 2>&1 || true

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "support@acme.org" \
  --password "Supp0rt@CaatS!Seed" \
  --permanent \
  --region "$REGION" > /dev/null 2>&1 || true

cat << EOF

_________________________________________________________________________________________
_________ .__                   .____________           ___________.__    .______.   .__  __
\_   ___ \|  |   ____  __ __  __| _/   _____/ ____   ___\__    ___/|__| __| _/\_ |__ |__|/  |_  ______
/    \  \/|  |  /  _ \|  |  \/ __ |\_____  \_/ __ \_/ ___\|    |   |  |/ __ |  | __ \|  \   __\/  ___/
\     \___|  |_(  <_> )  |  / /_/ |/        \  ___/\  \___|    |   |  / /_/ |  | \_\ \  ||  |  \___ \
 \______  /____/\____/|____/\____ /_______  /\___  >\___  >____|   |__\____ |  |___  /__||__| /____  >
        \/                       \/       \/     \/     \/                 \/      \/              \/
.___           _________       .____          ___.
|   | _____    \_   ___ \      |    |   _____ \_ |__
|   | \__  \   /    \  \/      |    |   \__  \ | __ \\
|   |  / __ \_ \     \____     |    |___ / __ \| \_\ \\
|___| (____  /  \______  /     |_______ (____  /___  /
           \/          \/              \/    \/    \/

   _  _     _____
__| || |__ /  |  |
\   __   /   |  |_     - The Danger Of Multi-SSO User Pools
 |  ||  |/    ^   /
/_  ~~  _\\____   |
  |_||_|      |__|
_________________________________________________________________________________________

  [+] App (HTTPS):  https://$APP_DNS

EOF
