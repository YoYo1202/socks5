#!/usr/bin/env bash
# ============================================================
# 一键 SOCKS5（microsocks）— Debian 11 / 12 / 13
#
#   bash s5.sh                  # 1080 端口，账号 s5user，密码随机
#   bash s5.sh 10800            # 指定端口
#   bash s5.sh 10800 myuser     # 指定端口 + 账号
#   bash s5.sh 1080 none        # 免认证（仅内网/临时）
#
# 只代理 TCP；要 UDP 换 sing-box / xray。
# ============================================================
set -euo pipefail

PORT=$(printf '%s' "${1:-1080}" | tr -cd '0-9'); [ -n "$PORT" ] || PORT=1080
U=$(printf '%s' "${2:-s5user}" | tr -d '\r\n ')
[ -n "$U" ] || U=s5user
[[ $EUID -eq 0 ]] || { echo "请用 root 运行（sudo bash $0）"; exit 1; }
(( PORT > 0 && PORT < 65536 )) || { echo "端口不合法: $PORT"; exit 1; }
W=""
[[ "$U" == "none" ]] || W=$(head -c 16 /dev/urandom | md5sum | cut -c1-16)

# ---------- 安装（apt 源坏了也能自救） ----------
have() { command -v "$1" >/dev/null 2>&1; }
apt_update() { apt-get update -qq >/dev/null 2>&1 || true; }

apt_update
if ! have microsocks; then
  apt-get install -y -qq microsocks >/dev/null 2>&1 || {
    echo "==> 装 microsocks 失败，尝试修 apt 源（换成 deb.debian.org，去掉 backports）..."
    if [[ -f /etc/apt/sources.list ]]; then
      cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"
    fi
    sed -i -E 's|https?://[a-z0-9.-]*deb\.debian\.org|http://deb.debian.org|g; /-backports/d' \
      /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
    apt_update
    apt-get install -y microsocks || {
      echo "!! microsocks 仍装不上，请手动看 /etc/apt/sources.list"; exit 1; }
  }
fi
have microsocks || { echo "microsocks 未安装成功"; exit 1; }
MBIN=$(command -v microsocks)

# curl / ip 只是用来自检和取 IP，装不上不影响服务
have curl || apt-get install -y -qq curl >/dev/null 2>&1 || true
have ip   || apt-get install -y -qq iproute2 >/dev/null 2>&1 || true

# ---------- 配置 ----------
if [[ -n "$W" ]]; then
  printf 'MS_U=%s\nMS_P=%s\n' "$U" "$W" >/etc/microsocks.env
  chmod 600 /etc/microsocks.env
  A='-i 0.0.0.0 -p '"$PORT"' -u "$MS_U" -P "$MS_P"'
  F='EnvironmentFile=/etc/microsocks.env'
else
  A='-i 0.0.0.0 -p '"$PORT"
  F=''
fi

cat >/etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=SOCKS5 proxy (microsocks)
After=network-online.target

[Service]
Type=simple
$F
ExecStart=/bin/sh -c 'exec $MBIN $A'
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# ---------- 启动 ----------
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable microsocks >/dev/null 2>&1 || true
  systemctl restart microsocks
  sleep 1
  systemctl is-active --quiet microsocks || { journalctl -u microsocks -n 30 --no-pager; exit 1; }
else
  pkill -f '[m]icrosocks' 2>/dev/null || true
  if [[ -n "$W" ]]; then
    nohup microsocks -i 0.0.0.0 -p "$PORT" -u "$U" -P "$W" >/var/log/microsocks.log 2>&1 &
  else
    nohup microsocks -i 0.0.0.0 -p "$PORT" >/var/log/microsocks.log 2>&1 &
  fi
  sleep 1
fi

# ---------- 放行 ----------
command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && { ufw allow "$PORT"/tcp >/dev/null; echo "==> ufw 已放行 $PORT/tcp"; }
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 && { firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null; firewall-cmd --reload >/dev/null; echo "==> firewalld 已放行 $PORT/tcp"; }

# ---------- 自检 ----------
IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5;exit}' || true)
IP=""
[[ -n "${IFACE:-}" ]] && IP=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
[[ -n "$IP" ]] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
X="socks5h://127.0.0.1:$PORT"
[[ -n "$W" ]] && X="socks5h://$U:$W@127.0.0.1:$PORT"
OUT=""
have curl && OUT=$(curl -s --max-time 12 -x "$X" https://api.ipify.org || true)
if ! have curl; then SELF="跳过（未装 curl）"
elif [[ -n "$OUT" ]]; then SELF="通过 ✔ 出口IP=$OUT"
else SELF="失败（查安全组/防火墙是否放行 $PORT）"; fi

echo
echo "============ SOCKS5 已就绪 ============"
echo " 地址 : ${IP:-自行查公网IP}"
echo " 端口 : $PORT"
echo " 账号 : $([[ -n "$W" ]] && echo "$U" || echo 免认证)"
echo " 密码 : ${W:-免认证}"
echo " 自检 : $SELF"
echo " 云服务器记得安全组放行 $PORT"
echo "======================================"
