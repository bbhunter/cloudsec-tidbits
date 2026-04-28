#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SUMMARY_FILE="lab-deployment.txt"
HINT_FILE="hint.txt"

case "${1:-apply}" in
  destroy)
    terraform init
    terraform destroy -auto-approve
    echo ""
    echo "Lab stack destroyed."
    exit 0
    ;;
  apply) ;;
  *)
    echo "Usage: $0 [apply|destroy]" >&2
    exit 1
    ;;
esac

terraform init
terraform apply -auto-approve > /dev/null

# User-data installs Go, builds the app, and starts systemd; targets need a short settle time.
sleep 5

terraform output -no-color >"$SUMMARY_FILE"

CF_URL=$(terraform output -raw cloudfront_url)
CF_HTTPS=$(terraform output -raw cloudfront_https_url)
PORTAL_ALB_URL=$(terraform output -raw portal_alb_url)
PORTAL_ALB_DNS=$(terraform output -raw portal_alb_dns)
OPS_ALB_URL=$(terraform output -raw ops_alb_url)

cat >"$HINT_FILE" <<EOF
First hint — portal Application Load Balancer

The main public ALB (the origin behind CloudFront) is reachable directly, outside the CDN edge:

  ${PORTAL_ALB_URL}

(DNS hostname only: ${PORTAL_ALB_DNS})

The same ALB hostname is deliberately leaked inside the CloudFront geo-block error page HTML (served when the viewer country is not on the distribution allowlist, or via the custom error response for /errors/geo-blocked.html). View page source on that response and search for the origin host to practice origin bypass.
EOF

echo ""
echo "HTTPS:"
echo "$CF_HTTPS"
echo ""
echo "Full outputs written to: $(pwd)/${SUMMARY_FILE}"
echo "First hint written to:   $(pwd)/${HINT_FILE}"
echo ""

cat <<EOF

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


_| || |__ |   ____/                                                                          
\   __   / |____  \                                                                           
 |  ||  |  /       \                                                                          
/_  ~~  _\/______  /                                                                          
  |_||_|         \/                                                                           
_________________________________________________________________________________________

Your Lab is deployed and ready.
Start hacking at :    ${CF_URL}
EOF
