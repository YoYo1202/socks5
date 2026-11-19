#!/usr/bin/env bash
# 一键 SOCKS5（microsocks）— Debian 12/13 · 自包含版，不联网下载脚本
# 用法: bash s5-mini.sh [端口] [用户名|none]
set -e
PORT="${1:-1080}"; U="${2:-s5user}"; P=""
[ "$U" = "none" ] || P=$(head -c 16 /dev/urandom | md5sum | cut -c1-16)

apt-get update -qq
apt-get install -y -qq microsocks curl iproute2 >/dev/null

if [ -n "$P" ]; then
  printf 'S5_USER=%s\nS5_PASS=%s\n' "$U" "$P" >/etc/microsocks.env; chmod 600 /etc/microsocks.env
  ARGS='-i 0.0.0.0 -p '"$PORT"' -u "$S5_USER" -P "$S5_PASS"'; ENVF='EnvironmentFile=/etc/microsocks.env'
else
  ARGS='-i 0.0.0.0 -p '"$PORT"; ENVF=''
fi

cat >/etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=SOCKS5 proxy (microsocks)
After=network-online.target

[Service]
Type=simple
$ENVF
ExecStart=/bin/sh -c 'exec /usr/bin/microsocks $ARGS'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable microsocks >/dev/null 2>&1 || true
systemctl restart microsocks
sleep 1
systemctl is-active --quiet microsocks || { echo "启动失败: journalctl -u microsocks -n 30"; exit 1; }

IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5;exit}')
IP=""
[ -n "$IFACE" ] && IP=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PROXY="socks5h://127.0.0.1:$PORT"
[ -n "$P" ] && PROXY="socks5h://$U:$P@127.0.0.1:$PORT"

echo
echo "============ SOCKS5 已就绪 ============"
echo " 地址   : ${IP:-查一下公网IP}"
echo " 端口   : $PORT"
echo " 用户名 : $([ -n "$P" ] && echo "$U" || echo 免认证)"
echo " 密码   : ${P:-免认证}"
echo -n " 自检   : "; curl -s --max-time 12 -x "$PROXY" https://api.ipify.org; echo " (出口IP)"
echo " 云服务器记得安全组放行 $PORT"
echo "======================================"
