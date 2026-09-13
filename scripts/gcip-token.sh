#!/usr/bin/env bash
# 사용법: ./scripts/gcip-token.sh <uid> <department>
# 출력: GCIP ID 토큰 (stdout 한 줄)
set -euo pipefail
UID_ARG="${1:?uid required}"
DEPT="${2:?department required}"
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || echo '<YOUR_PROJECT_ID>')}"
SA="${GCIP_SA:-$(gcloud iam service-accounts list --project="${PROJECT}" --filter="name:firebase-adminsdk" --format="value(email)" 2>/dev/null | head -n1 || echo "firebase-adminsdk@${PROJECT}.iam.gserviceaccount.com")}"
AT=$(gcloud auth print-access-token)

CT=$(python3 "$(dirname "$0")/gcip_payload.py" "$SA" "$UID_ARG" "$DEPT" | curl -sS -X POST \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SA}:signJwt" \
  -H "Authorization: Bearer ${AT}" \
  -H "X-Goog-User-Project: ${PROJECT}" \
  -H "Content-Type: application/json" \
  --data @- \
  | python3 "$(dirname "$0")/gcip_pick.py" signedJwt)

KEY=$(curl -sS \
  -H "Authorization: Bearer ${AT}" \
  -H "X-Goog-User-Project: ${PROJECT}" \
  "https://firebase.googleapis.com/v1beta1/projects/${PROJECT}/webApps/-/config" \
  | python3 "$(dirname "$0")/gcip_pick.py" apiKey)

curl -sS -X POST \
  "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"${CT}\",\"returnSecureToken\":true}" \
  | python3 "$(dirname "$0")/gcip_pick.py" idToken
