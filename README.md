# SekaiStoryActions

用 GitHub Actions 跟进 Project Sekai 五个区服的剧情：某个区服在 Team-Haruki 的 masterdata 仓库有新提交时，用 [SekaiStoryRipper](https://github.com/StarMoe-org/SekaiStoryRipper) 导出新增的剧集，发布到 `s3://sekai-extra-assets/sekai-story/ripper/<区服>`。[SekaiStoryExporter](https://github.com/StarMoe-org/SekaiStoryExporter) 直接读取这个地址。

| 区服 | workflow | masterdata | 每小时第几分钟 | VPN |
|---|---|---|---|---|
| 日服 | [`jp.yml`](.github/workflows/jp.yml) | [haruki-sekai-master](https://github.com/Team-Haruki/haruki-sekai-master) | 23 | 需要时 |
| EN | [`en.yml`](.github/workflows/en.yml) | [haruki-sekai-en-master](https://github.com/Team-Haruki/haruki-sekai-en-master) | 33 | 需要时 |
| CN | [`cn.yml`](.github/workflows/cn.yml) | [haruki-sekai-sc-master](https://github.com/Team-Haruki/haruki-sekai-sc-master) | 43 | — |
| TW | [`tw.yml`](.github/workflows/tw.yml) | [haruki-sekai-tc-master](https://github.com/Team-Haruki/haruki-sekai-tc-master) | 53 | — |
| KR | [`kr.yml`](.github/workflows/kr.yml) | [haruki-sekai-kr-master](https://github.com/Team-Haruki/haruki-sekai-kr-master) | 13 | — |

GitHub 不保证定时任务准时，负载高时会推迟或跳过一部分，实际频率可能只有每几小时一次。

## 工作方式

每个区服的 workflow 都调用同一个 [`rip.yml`](.github/workflows/rip.yml)：

1. **检测**：比较上游 `HEAD` 与已发布的 `ripper.lock.json` 里 masterdata 固定的 commit。两者相同就结束，不需要任何密钥。这个区服还没有发布过 lock 时，只给出警告并结束（见「不在这里做的事」）。
2. **导出**（只在上游有变化时）：
   - 下载固定版本的 ripper release；
   - 把 masterdata 固定到上游的新 commit，app 版本号也取自这个 commit 的 `versions/current_version.json`。日服和 EN 还要取 app hash；EN 连资源版本和 hash 一起固定，因此不需要游客账号；
   - 日服和 EN：runner 被游戏拒绝时，连接一个 [VPN Gate](https://www.vpngate.net) 日本节点（见下文「日本代理」）；
   - 运行 `ripper manifest`，然后 `ripper rip all --missing`：只导出 lock 里还没有的剧集，包括新活动，以及上次资源还没上线的剧集；
   - 发布到 S3，最后写 lock。lock 记下新的 commit，下一次检测就不会再触发。

状态只保存在已发布的 lock 里，本仓库不提交任何数据。

- 运行中途出错（登录、清单、网络）时 lock 不会更新，下个小时会自动重试。
- 个别 bundle 解包失败时，其余剧集照常发布，lock 也会更新；受影响的剧集不写进 lock，等上游下次更新时再补，也可以手动用 `force` 运行一次。

设计见 SekaiStoryRipper 的 [ADR-0016](https://github.com/StarMoe-org/SekaiStoryRipper/blob/main/docs/adr/0016-incremental-runs.md)。

**手动运行**（Actions → 选择区服，如 JP → Run workflow）：
- `force`：上游没有变化也运行一次 `all --missing`；
- `selectors`：重导指定的剧集，例如 `event:218` 或 `event:204/1 area:8`，用于资源修正之后。

## 不在这里做的事

以下情况需要在本地用 ripper 全量导出，然后发布到同一个前缀。在 GitHub runner 上，全量导出所需的磁盘（约 14GB 可用）和时间（6 小时）都不够。

- 首次导出。EN、CN、TW、KR 目前都还没有发布过 library，要先在本地全量导出一次（`ripper --region <区服> --out s3://sekai-extra-assets/sekai-story/ripper/<区服> rip all`），之后的增量更新才会由这里接手；
- ripper 升级了格式（lock 的 `formats` 变化）。这时 `--missing` 会直接报错，不会在 runner 上退化成全量导出；
- 已导出剧集的资源被修正。`--missing` 只补缺少的剧集，已有剧集可以用 `selectors` 手动重导。

## 配置

**Secrets**（Settings → Secrets and variables → Actions）：

| 名称 | 内容 |
|---|---|
| `RIPPER_AB_KEY`、`RIPPER_AB_IV` | 日服的 AES key 和 IV（API 和清单共用），需要自行从合法持有的客户端取得 |
| `RIPPER_EN_AB_KEY`、`RIPPER_EN_AB_IV` | EN 的 key 和 IV（同上） |
| `RIPPER_CN_AB_KEY`、`RIPPER_CN_AB_IV` | CN 的清单 key 和 IV |
| `RIPPER_TW_AB_KEY`、`RIPPER_TW_AB_IV` | TW 的清单 key 和 IV |
| `RIPPER_KR_AB_KEY`、`RIPPER_KR_AB_IV` | KR 的清单 key 和 IV |
| `RIPPER_JP_ACCOUNT` | 日服游客账号文件 `account.json` 的内容。没有它，ripper 每次运行都会注册一个新的游客账号，所以这一项缺失时日服的导出会直接失败 |
| `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` | S3 凭据，需要对上面的前缀有读写权限 |
| `AWS_ENDPOINT_URL` | S3 端点（MinIO） |

**Variables**（可选）：`AWS_REGION`、`S3_ADDRESSING_STYLE`（`auto` / `path` / `virtual`）、`VPNGATE`（设为 `false` 时不连 VPN，直连游戏服务器）。

**日本代理**：日服的游戏服务器拒绝 GitHub runner 的地址（版本接口返回 403）。日服和 EN 导出前，[`.github/scripts/vpngate.sh`](.github/scripts/vpngate.sh) 先从 runner 直接请求该区服的版本接口：返回 200 就不连 VPN；否则从 VPN Gate 的公开列表里按评分依次尝试日本节点（最多 20 个），直到出口在日本、而且通过它请求版本接口返回 200（游戏也会拒绝一部分 VPN Gate 地址）：
- 不修改 runner 的默认路由，只有本地 HTTP 代理（tinyproxy，`127.0.0.1:3128`）的出站连接走隧道；
- 只有 ripper 那一步设置 `HTTPS_PROXY`，S3、masterdata（GitHub）和资源站用 `NO_PROXY` 直连；断开时日志列出经代理连接的游戏域名；
- 所有节点都连不上时运行失败，lock 不会更新，下个小时重试。VPN Gate 是志愿者运营的节点，速度和可用性都没有保证。

日志是公开的：
- 游客账号的各个字段在导出前登记为掩码；
- 密钥只通过环境变量传给 ripper，ripper 不打印它们；
- 不要在本仓库提交任何密钥或逆向资料。

**升级 ripper**：修改 [`rip.yml`](.github/workflows/rip.yml) 里的 `RIPPER_VERSION`（所有区服共用）。如果新版本改变了格式，要先在本地全量重导。EN、TW、KR 需要 ripper 0.7.0 或更高版本。

## 许可

MIT OR Apache-2.0，与 SekaiStoryRipper 相同。
