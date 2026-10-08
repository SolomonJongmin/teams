#!/usr/bin/env bash
# INTELLI TEAMS 네이티브 배포 — 서버에서 실행된다(Actions 가 SSH 로 호출).
#
# 전제: 소스는 이미 ~/apps/teams 로 동기화됨(rsync). 이 스크립트는 그 위에서
#   1) Node 22 격리 확보(nvm)  2) npm ci + build  3) systemd user 유닛 갱신  4) 재시작  5) 헬스체크.
# 서버 전역 Node(18)는 건드리지 않는다. nginx(70-teams.conf)는 변경하지 않는다.
set -euo pipefail

APP_DIR="/home/soltech/apps/teams"
NODE_MAJOR=22
NVM_DIR="/home/soltech/.nvm"
SERVICE="deskrpg.service"
UNIT_SRC="$APP_DIR/deploy/intellicore/deskrpg.service"
UNIT_DST="/home/soltech/.config/systemd/user/$SERVICE"
HEALTH_URL="http://172.19.0.1:3000/"

echo "::deploy:: APP_DIR=$APP_DIR"
cd "$APP_DIR"

# --- 1) Node 22 격리(nvm) ---------------------------------------------------
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "::deploy:: install nvm"
  export NVM_DIR
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_MAJOR" >/dev/null
nvm use "$NODE_MAJOR" >/dev/null
NODE_BIN_DIR="$(dirname "$(nvm which "$NODE_MAJOR")")"
# 유닛이 참조하는 안정 경로(v22-current)를 실제 설치 경로로 고정한다.
ln -sfn "$(dirname "$NODE_BIN_DIR")" "$NVM_DIR/versions/node/v22-current"
export PATH="$NODE_BIN_DIR:$PATH"
echo "::deploy:: node=$(node -v) npm=$(npm -v) at $NODE_BIN_DIR"

# --- 2) 의존성 + 빌드 -------------------------------------------------------
echo "::deploy:: npm ci"
npm ci
echo "::deploy:: npm run build"
npm run build

# --- 3) systemd user 유닛 갱신 ---------------------------------------------
mkdir -p "$(dirname "$UNIT_DST")"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl --user daemon-reload

# --- 4) 재시작 --------------------------------------------------------------
echo "::deploy:: restart $SERVICE"
systemctl --user enable "$SERVICE" >/dev/null 2>&1 || true
systemctl --user restart "$SERVICE"

# --- 5) 헬스체크 ------------------------------------------------------------
echo "::deploy:: health check $HEALTH_URL"
ok=0
for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" || true)"
  # 앱이 뜨면 200 또는 (미인증 리다이렉트) 3xx 를 돌려준다.
  if [ "$code" = "200" ] || [ "${code:0:1}" = "3" ]; then
    echo "::deploy:: healthy after ${i}0s (HTTP $code)"; ok=1; break
  fi
  sleep 10
done
if [ "$ok" != "1" ]; then
  echo "::deploy:: UNHEALTHY — recent logs:" >&2
  systemctl --user status "$SERVICE" --no-pager -l | tail -20 >&2 || true
  journalctl --user -u "$SERVICE" --no-pager -n 40 >&2 || true
  exit 1
fi
echo "::deploy:: done"
