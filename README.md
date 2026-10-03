# SekaiStoryActions

用 GitHub Actions 跟进日服剧情：[Team-Haruki/haruki-sekai-master](https://github.com/Team-Haruki/haruki-sekai-master) 有新提交时，用 [SekaiStoryRipper](https://github.com/StarMoe-org/SekaiStoryRipper) 导出新增的剧集，发布到 `s3://sekai-extra-assets/sekai-story/ripper/jp`。[SekaiStoryExporter](https://github.com/StarMoe-org/SekaiStoryExporter) 直接读取这个地址。

## 工作方式

[`.github/workflows/jp.yml`](.github/workflows/jp.yml) 每小时运行一次（第 23 分钟）：

1. **检测**：比较上游 `HEAD` 与已发布的 `ripper.lock.json` 里 masterdata 固定的 commit。两者相同就结束，不需要任何密钥。
2. **导出**（只在上游有变化时）：
   - 下载固定版本的 ripper release；
   - 把 masterdata 固定到上游的新 commit，app 版本号和 hash 也取自这个 commit 的 `versions/current_version.json`；
   - 连接一个 [VPN Gate](https://www.vpngate.net) 日本节点（见下文「日本代理」）；
   - 运行 `ripper manifest`，然后 `ripper rip all --missing`：只导出 lock 里还没有的剧集，包括新活动，以及上次资源还没上线的剧集；
   - 发布到 S3，最后写 lock。lock 记下新的 commit，下一次检测就不会再触发。

状态只保存在已发布的 lock 里，本仓库不提交任何数据。

- 运行中途出错（登录、清单、网络）时 lock 不会更新，下个小时会自动重试。
- 个别 bundle 解包失败时，其余剧集照常发布，lock 也会更新；受影响的剧集不写进 lock，等上游下次更新时再补，也可以手动用 `force` 运行一次。

设计见 SekaiStoryRipper 的 [ADR-0016](https://github.com/StarMoe-org/SekaiStoryRipper/blob/main/docs/adr/0016-incremental-runs.md)。

**手动运行**（Actions → JP → Run workflow）：
- `force`：上游没有变化也运行一次 `all --missing`；
- `selectors`：重导指定的剧集，例如 `event:218` 或 `event:204/1 area:8`，用于资源修正之后。

## 不在这里做的事

以下情况需要在本地用 ripper 全量导出，然后发布到同一个前缀。在 GitHub runner 上，全量导出所需的磁盘（约 14GB 可用）和时间（6 小时）都不够。

- 首次导出；
- ripper 升级了格式（lock 的 `formats` 变化）。这时 `--missing` 会直接报错，不会在 runner 上退化成全量导出；
- 已导出剧集的资源被修正。`--missing` 只补缺少的剧集，已有剧集可以用 `selectors` 手动重导。

## 配置

**Secrets**（Settings → Secrets and variables → Actions）：

| 名称 | 内容 |
|---|---|
| `RIPPER_AB_KEY`、`RIPPER_AB_IV` | 日服的 AES key 和 IV（API 和清单共用），需要自行从合法持有的客户端取得 |
| `RIPPER_JP_ACCOUNT` | 游客账号文件 `account.json` 的内容。没有它，ripper 每次运行都会注册一个新的游客账号，所以这一项缺失时工作流会直接失败 |
| `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` | S3 凭据，需要对上面的前缀有读写权限 |
| `AWS_ENDPOINT_URL` | S3 端点（MinIO） |

**Variables**（可选）：`AWS_REGION`、`S3_ADDRESSING_STYLE`（`auto` / `path` / `virtual`）、`VPNGATE`（设为 `false` 时不连 VPN，直连游戏服务器）。

**日本代理**：日服的游戏服务器拒绝 GitHub runner 的地址（版本接口返回 403）。导出前 [`.github/scripts/vpngate.sh`](.github/scripts/vpngate.sh) 从 VPN Gate 的公开列表里按评分依次尝试日本节点（最多 20 个），直到出口在日本、而且通过它请求版本接口返回 200（游戏也会拒绝一部分 VPN Gate 地址）：
- 不修改 runner 的默认路由，只有本地 HTTP 代理（tinyproxy，`127.0.0.1:3128`）的出站连接走隧道；
- 只有 ripper 那一步设置 `HTTPS_PROXY`，S3、masterdata（GitHub）和资源站用 `NO_PROXY` 直连；断开时日志列出经代理连接的游戏域名；
- 所有节点都连不上时运行失败，lock 不会更新，下个小时重试。VPN Gate 是志愿者运营的节点，速度和可用性都没有保证。

日志是公开的：
- 游客账号的各个字段在导出前登记为掩码；
- 密钥只通过环境变量传给 ripper，ripper 不打印它们；
- 不要在本仓库提交任何密钥或逆向资料。

**升级 ripper**：修改 workflow 里的 `RIPPER_VERSION`。如果新版本改变了格式，要先在本地全量重导。

## 许可

MIT OR Apache-2.0，与 SekaiStoryRipper 相同。
