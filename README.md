# liteflow-conf-puller-docker

以固定间隔调用 **/app/scripts/pull.sh** 完成配置拉取与写入。`pull.sh` 与 `entrypoint.sh` 由仓库根目录复制到镜像内 `/app/scripts/`，镜像不从外部下载脚本。

> 许可：BSD 3-Clause License

---

## 目录结构

'''
.
├─ Dockerfile
├─ entrypoint.sh        # 构建时复制到 /app/scripts/entrypoint.sh
├─ pull.sh              # 构建时复制到 /app/scripts/pull.sh（你提供）
├─ docker-compose.sample.yml
├─ .dockerignore
└─ README.md
'''

---

## 运行时约定

- 容器启动后，每隔 `INTERVAL` 秒执行一次 `/app/scripts/pull.sh`。
- `pull.sh` 负责从配置仓库读取指定文件并写入 `DEST_FILE`；其实现由你提供。
- 已预置 `ssh-keyscan github.com`，如需额外 Git 主机，请通过 `SSH_KNOWN_HOSTS` 传入。

---

## 环境变量（建议由 `pull.sh` 读取）

| 变量名             | 必填 | 说明 |
|-------------------|------|------|
| `CONF_REPO`       | 是   | 配置仓库地址（SSH/HTTPS），如 `git@github.com:xnervwang/liteflow-conf-repo.git` |
| `CONF_SRC`        | 是   | 仓库内配置相对路径，如 `output/raspberrypi.node33.us.conf` |
| `DEST_FILE`       | 是   | 目标写入路径，如 `/app/etc/liteflow.conf` |
| `INTERVAL`        | 否   | 轮询间隔秒，默认 `60` |
| `TZ`              | 否   | 容器时区，如 `Asia/Shanghai` |
| `SSH_KNOWN_HOSTS` | 否   | 追加到 `/etc/ssh/ssh_known_hosts` 的主机公钥（可多行） |

---

## 构建镜像

'''bash
docker build -t xnervwang/liteflow-conf-puller:latest .
'''

> 构建前请确保仓库根目录存在可执行的 `pull.sh` 与 `entrypoint.sh`：
> 
> '''bash
> chmod +x pull.sh entrypoint.sh
> '''

---

## 直接运行示例

'''bash
docker run -d --name liteflow-conf-puller \
  -e TZ=Asia/Shanghai \
  -e CONF_REPO=git@github.com:xnervwang/liteflow-conf-repo.git \
  -e CONF_SRC=output/raspberrypi.node33.us.conf \
  -e DEST_FILE=/app/etc/liteflow.conf \
  -e INTERVAL=60 \
  -v "$PWD":/app/etc:rw \
  -v "$HOME/.ssh":/root/.ssh:ro \
  --restart unless-stopped \
  xnervwang/liteflow-conf-puller:latest
'''

---

## 使用 Compose（示例）

见 `docker-compose.sample.yml`，按需修改后运行：

'''bash
docker compose up -d
'''

---

## 实现要点

- `Dockerfile` 预装：`bash`, `git`, `openssh-client`, `diffutils`, `ca-certificates`, `tzdata`。
- 镜像内目录：
  - `/app/scripts/entrypoint.sh`：定时器与通用初始化（时区/known_hosts）。
  - `/app/scripts/pull.sh`：你提供的实际拉取与写入逻辑。
  - `/app/etc/`：默认建议写入配置文件的位置（可改）。
- 如需统一 Bash 语义，可在 `Dockerfile` 中添加 `SHELL ["/bin/bash","-lc"]`（当前不必需）。

---

## 许可证

本项目使用 **BSD 3-Clause License**。详见 `LICENSE`。
