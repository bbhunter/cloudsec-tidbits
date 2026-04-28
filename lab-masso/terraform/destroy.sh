#!/usr/bin/env bash
set -euo pipefail

echo ">>> [1/2] Destroying AWS infrastructure via Terraform..."
terraform destroy -auto-approve

echo ">>> [2/2] Cleaning up local artifacts..."
rm -f ./*.zip

cat << EOF

 ___________________________________________________________________
|                                                                   |
|   Cleanup Complete. All AWS resources and local zips removed.     |
|___________________________________________________________________|

EOF
