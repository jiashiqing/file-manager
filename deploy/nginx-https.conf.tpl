# =====================================================================
#  __APP_TITLE__ · Nginx 反向代理（域名 + HTTPS）
#  安装位置：/etc/nginx/conf.d/__SVC__.conf
#  setup.sh 会自动替换域名、后端端口、限速规则、实时路径、访问控制
# =====================================================================

upstream __NGX_ID___backend {
    server 127.0.0.1:__PORT__;
    keepalive 32;
}

# 写接口限速：防止有人写脚本灌数据
limit_req_zone $binary_remote_addr zone=__NGX_ID___write:10m rate=20r/s;

server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    # certbot 续期验证走这里，其余全跳 HTTPS
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size __MAX_BODY__;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    # ---------------- 访问控制 ----------------
__AUTH__

    # 停止接口彻底关掉
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
