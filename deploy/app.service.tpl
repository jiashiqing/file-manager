[Unit]
Description=__APP_TITLE__
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=__RUN_USER__
Group=__RUN_USER__
WorkingDirectory=__ROOT__

# ---- 部署参数（setup.sh 渲染时按实际情况改写下面这段）----
__ENV_LINES__

ExecStart=__START_CMD__
Restart=always
RestartSec=3
# 大量长连接（SSE / WebSocket）会把默认 1024 个 fd 用光
LimitNOFILE=65535
KillSignal=SIGINT
TimeoutStopSec=20

StandardOutput=journal
StandardError=journal
SyslogIdentifier=__SVC__

# ---- 轻量加固（APP_DIR 在 /home 下时 setup.sh 会自动降级，见 references/pitfalls.md）----
__HARDEN_LINES__

[Install]
WantedBy=multi-user.target
