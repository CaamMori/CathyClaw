# 快速部署与排错

## 部署

```bash
git clone https://github.com/CaamMori/CakeClaw.git cakeclaw
cd cakeclaw
sudo ./scripts/install.sh
```

部署后打开 `http://<IP>:8080`，在 Gateway 控制台配置 API Key + Model。

## 排错

### Gateway 起不来
```bash
docker logs cakeclaw-gateway --tail 50
docker ps --filter name=cakeclaw-gateway
```

### 端口被占用
```bash
ss -tlnp | grep 18789
# 修改 GATEWAY_PORT 后重装
```

### Nginx 报错
```bash
nginx -t
cat /etc/nginx/sites-available/cakeclaw
```

### 防火墙
```bash
ufw status verbose
# 无域名模式需要 8080 开放
```

### 重置
```bash
sudo ./scripts/uninstall.sh
sudo ./scripts/install.sh
```
