# SekaiStoryActions

用 GitHub Actions 跟进五个区服（日服、CN、TW、KR、EN）的剧情：Team-Haruki 的 masterdata 仓库有新提交时，用 [SekaiStoryRipper](https://github.com/StarMoe-org/SekaiStoryRipper) 导出新增的剧集，发布到 `s3://sekai-extra-assets/sekai-story/ripper/<区服>`。[SekaiStoryExporter](https://github.com/StarMoe-org/SekaiStoryExporter) 直接读取这些地址。

| 区服 | masterdata | key（secrets） | 说明 |
|---|---|---|---|
| `jp` | `haruki-sekai-master` | `RIPPER_AB_KEY` / `RIPPER_AB_IV` | 游客账号（`RIPPER_JP_ACCOUNT`），经 VPN Gate 日本节点访问 |
| `cn` | `haruki-sekai-sc-master` | `RIPPER_AB_KEY_CN` / `RIPPER_AB_IV_CN` | 匿名 CDN |
| `tw` | `haruki-sekai-tc-master` | 同 CN | 匿名 CDN |
| `kr` | `haruki-sekai-kr-master` | 同 CN | 匿名 CDN |
| `en` | `haruki-sekai-en-master` | `RIPPER_AB_KEY_EN` / `RIPPER_AB_IV_EN` | 资源版本和 hash 取自 masterdata，不登录 |

## 工作方式

[`.github/workflows/rip.yml`](.github/workflows/rip.yml) 每小时运行一次（第 23 分钟），处理变量 `REGIONS` 里列出的区服：

1. **检测**：比较每个区服上游的 `HEAD` 与已发布的 `ripper.lock.json` 里 masterdata 固定的 commit。都相同就结束，不需要任何密钥。
2. **导出**（只对上游有变化的区服，一个接一个地运行）：
   - 下载固定版本的 ripper release；
   - 把 masterdata 固定到上游的新 commit，app 版本号和 hash（EN 还有资源版本和 hash）也取自这个 commit 的 `versions/current_version.json`；
   - 日服连接一个 [VPN Gate](https://www.vpngate.net) 日本节点（见下文「日本代理」）；
   - 打开到 SeaweedFS 的 SSH 通道（见下文「去重上传」）；
   - 运行 `ripper manifest`，然后 `ripper rip all --missing`：只导出 lock 里还没有的剧集，包括新活动，以及上次资源还没上线的剧集；
   - 发布到 S3，最后写 lock。lock 记下新的 commit，下一次检测就不会再触发。

状态只保存在已发布的 lock 里，本仓库不提交任何数据。

- 运行中途出错（登录、清单、网络）时 lock 不会更新，下个小时会自动重试；一个区服失败不影响其他区服。
- 个别 bundle 解包失败时，其余剧集照常发布，lock 也会更新；受影响的剧集不写进 lock，等上游下次更新时再补，也可以手动用 `force` 运行一次。
- 同一时间只运行一次，区服之间也依次进行：各区服共用 SeaweedFS 上的内容锚点，它们的链接计数不能被两个进程同时修改。

设计见 SekaiStoryRipper 的 [ADR-0016](https://github.com/StarMoe-org/SekaiStoryRipper/blob/main/docs/adr/0016-incremental-runs.md)（增量运行）和 [ADR-0019](https://github.com/StarMoe-org/SekaiStoryRipper/blob/main/docs/adr/0019-seaweedfs-hard-link-dedup.md)（去重）。

**手动运行**（Actions → Rip → Run workflow）：
- `regions`：只运行这些区服，例如 `jp` 或 `cn tw`；留空用变量 `REGIONS`；
- `force`：上游没有变化也运行一次 `all --missing`；
- `selectors`：重导指定的剧集，例如 `event:218` 或 `event:204/1 area:8`，用于资源修正之后。只对一个区服使用。

**去重上传**：五个区服的 library 大部分内容相同。SeaweedFS 用 Filer 硬链接，让相同的内容只存一份，各区服的路径保持不变。配置了通道时，ripper 发布 `library/` 的文件前会先查内容锚点：桶里已有的直接建链接，不再上传。
- Filer 的 gRPC 只在集群内部可达。[`.github/scripts/filer-tunnel.sh`](.github/scripts/filer-tunnel.sh) 用 `SEAWEED_SSH_KEY` 建立 SSH 动态转发（SOCKS5），经 master 的 ClusterIP 查出当前 leader Pod 的 IP（Pod 重建后会变），写进 ripper 的 `[s3] filer` / `filer_proxy`；
- 服务器上的账号 `sekai-tunnel` 只允许端口转发：没有 shell，不能执行命令；
- 通道打不开时，这次照常上传、不去重，并留下警告；之后可以在服务器上用 `ripper dedup --apply` 补做；
- 往这些前缀写入的任何程序都必须先删除再上传，不能原地覆盖：原地覆盖硬链接会在下次 vacuum 后损坏共用这份数据的其他区服。ripper 从 0.8.0 起遵守这一点，**不要再用更早的版本发布**。

## 不在这里做的事

以下情况需要在本地用 ripper 全量导出，然后发布到同一个前缀。在 GitHub runner 上，全量导出所需的磁盘（约 14GB 可用）和时间（6 小时）都不够。

- 首次导出；
- ripper 升级了格式（lock 的 `formats` 变化）。这时 `--missing` 会直接报错，不会在 runner 上退化成全量导出；
- 已导出剧集的资源被修正。`--missing` 只补缺少的剧集，已有剧集可以用 `selectors` 手动重导。

## 配置

**Secrets**（Settings → Secrets and variables → Actions）：

| 名称 | 内容 |
|---|---|
| `RIPPER_AB_KEY`、`RIPPER_AB_IV` | 日服的 AES key 和 IV（API 和清单共用） |
| `RIPPER_AB_KEY_CN`、`RIPPER_AB_IV_CN` | CN 的清单 key 和 IV，TW、KR 共用 |
| `RIPPER_AB_KEY_EN`、`RIPPER_AB_IV_EN` | EN 的 key 和 IV（API 和清单共用） |
| `RIPPER_JP_ACCOUNT` | 日服游客账号文件 `account.json` 的内容。没有它，ripper 每次运行都会注册一个新的游客账号，所以这一项缺失时日服的运行会直接失败 |
| `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` | S3 凭据，需要对上面的前缀有读写权限 |
| `AWS_ENDPOINT_URL` | S3 端点 |
| `SEAWEED_SSH_KEY` | SSH 通道的私钥（服务器上 `sekai-tunnel` 账号的 key，只能做端口转发） |
| `SEAWEED_KNOWN_HOSTS` | 服务器的主机公钥（`ssh-keyscan -t ed25519 <host>` 的输出）。只接受这把公钥，通道不会信任未知主机 |

key 需要自行从合法持有的客户端取得。

**Variables**：

| 名称 | 内容 |
|---|---|
| `REGIONS` | 要跟进的区服，空格分隔，例如 `jp cn tw kr en`。**未设置时什么也不运行**，用来启用或停用整个工作流 |
| `SEAWEED_SSH_HOST`、`SEAWEED_SSH_USER` | SSH 通道的主机和用户；未设置 `SEAWEED_SSH_HOST` 时不去重 |
| `SEAWEED_MASTER` | master 的 HTTP 地址（集群内的 ClusterIP:9333），用来查 leader Pod 的 IP |
| `AWS_REGION`、`S3_ADDRESSING_STYLE` | 可选，S3 的区域和寻址方式（`auto` / `path` / `virtual`） |
| `VPNGATE` | 可选，设为 `false` 时日服不连 VPN，直连游戏服务器 |

**日本代理**：日服的游戏服务器拒绝 GitHub runner 的地址（版本接口返回 403）。导出前 [`.github/scripts/vpngate.sh`](.github/scripts/vpngate.sh) 从 VPN Gate 的公开列表里按评分依次尝试日本节点（最多 20 个），直到出口在日本、而且通过它请求版本接口返回 200（游戏也会拒绝一部分 VPN Gate 地址）：
- 不修改 runner 的默认路由，只有本地 HTTP 代理（tinyproxy，`127.0.0.1:3128`）的出站连接走隧道；
- 只有 ripper 那一步设置 `HTTPS_PROXY`，S3、masterdata（GitHub）和资源站用 `NO_PROXY` 直连；断开时日志列出经代理连接的游戏域名；
- 所有节点都连不上时运行失败，lock 不会更新，下个小时重试。VPN Gate 是志愿者运营的节点，速度和可用性都没有保证。

日志是公开的：
- 游客账号的各个字段在导出前登记为掩码；
- 密钥只通过环境变量传给 ripper，ripper 不打印它们；SSH 私钥只写进 runner 的临时目录，运行结束时删除；
- 不要在本仓库提交任何密钥或逆向资料。

**升级 ripper**：修改 workflow 里的 `RIPPER_VERSION`。如果新版本改变了格式，要先在本地全量重导。

## 许可

MIT OR Apache-2.0，与 SekaiStoryRipper 相同。
