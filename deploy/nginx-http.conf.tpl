# =====================================================================
#  __APP_TITLE__ · Nginx 反向代理（只有 IP、没有域名的版本）
#  安装位置：/etc/nginx/conf.d/__SVC__.conf
#  setup.sh 会替换监听端口、后端端口、限速规则、实时路径、访问控制
#
#  ⚠ 没有 HTTPS 时，口令与业务数据都是明文上网。只建议临时用，
#    一旦有了域名请立刻改用 nginx-https.conf.tpl + certbot。
# =====================================================================

# upstream / limit_req zone 的名字在 nginx 里是全局唯一的，
# 同机装第二个实例时必须靠 __NGX_ID__ 区分，否则 nginx -t 报 duplicate。
upstream __NGX_ID___backend {
    server 127.0.0.1:__PORT__;
    keepalive 32;
}

# 写接口限速：防止有人写脚本灌数据
limit_req_zone $binary_remote_addr zone=__NGX_ID___write:10m rate=20r/s;

server {
    listen __WEB_PORT__;
    listen [::]:__WEB_PORT__;
    server_name __DOMAIN_OR_UNDERSCORE__;

    # 上传体积上限（按需调：名单导入 / 图片上传）
    client_max_body_size __MAX_BODY__;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    # ---------------- 访问控制（见 SKILL.md「三种开放模式」）----------------
__AUTH__

    # 停止接口彻底关掉（服务端也应同时关闭，双保险）
    location = /api/shutdown { return 403; }

    # 实时推送：必须关缓冲，否则大屏 / 进度墙不动
    location = __SSE_PATH__ {
        proxy_pass http://__NGX_ID___backend;
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 24h;
        chunked_transfer_encoding off;
    }

    # 写接口限速
    location ~ __LIMIT_RE__ {
        limit_req zone=__NGX_ID___write burst=40 nodelay;
        proxy_pass http://__NGX_ID___backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }

    # 其余（页面、静态资源、只读接口）
    location / {
        proxy_pass http://__NGX_ID___backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
