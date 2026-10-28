# Cinefile → iOS 移植计划

> 源码：`d:\Users\10759\Downloads\f651b829`（Cinefile 0.3.2，Python 3.11 + PySide6 + libmpv，10,653 行）
> 目标：iPad（iPadOS 16.4.1，TrollStore）原生 App，功能对等，GitHub Actions 云端构建未签名 IPA。

---

## 一、源码解读结论

### 1.1 功能清单（按模块）

| # | 功能 | 源码位置 | 关键行为 |
|---|---|---|---|
| 1 | 文件夹即片库 | `library.py` | `os.scandir` 只列文件夹 + 15 种视频扩展名；跳过隐藏/系统目录；文件夹在前、自然排序（`Episode 2` < `Episode 10`） |
| 2 | 缩略图 | `thumbnail_cache.py` | ffprobe 取时长 → ffmpeg 在 20% 处（3s~120s 夹取）抽 1 帧，缩放 640 宽 lanczos，jpg q3；缓存键 `sha1(path\|mtime\|size\|thumb-v2)`；并发 3、先占位后替换；上限 1.5GB LRU 清理 |
| 3 | 播放器 | `player.py` | libmpv（`hwdec=auto-safe`、`cache=yes`、`demuxer-max-bytes=256MiB`、`network-timeout=15`）；播放/暂停、±10s、点击/拖动 seek（30px 命中区、60ms 合并）、音量/静音、字幕轨循环（含关闭）、音轨循环、全屏、控制条 2.8s 自动隐藏、结束标记已看、播放中评分 |
| 4 | SMB | `smb.py` | `WNetAddConnection2W` 建会话 → 全程 UNC 路径；密码只驻留内存；`\\server\share\sub` 解析与错误映射 |
| 5 | 加密发现 | `peer.py` | UDP 组播 `239.255.42.99:45990`；查询包 JSON（`magic=CFPEER2`、`type=discover`、`v=2`、`query_id` 32hex、`epk` X25519-32B、`salt` 16B、`pid=sha256(instance_id)`）；主机单播回应：X25519→HKDF-SHA256(info=`Cinefile/peer-discovery/v2/`)→AES-256-GCM，AAD=`Cinefile/peer-response/v2:`+query_id；每 IP 2s 冷却、全局 60/min、10–60ms 抖动；无周期广播 |
| 6 | 配对（v2.2） | `peer.py` | TCP TLS1.3 自签证书 + SHA-256 指纹 pin；JSON 行协议（`\n` 分隔，≤16KB）；`hello{challenge}` → `pair{code/no_code, client_instance, my_share, guest_fingerprint, guest_cert, guest_proof}` → `paired{token, access{server,share,username,password}, reverse}`；6 位码 120s 有效、3 次锁定；guest 证明 = 自签证书私钥 RSA-PSS-SHA256 签名 challenge |
| 7 | 配对存储 | `peer.py` `PeerStore` | `peers.json` v1，凭据 DPAPI 加密；主机名优先重连（DHCP 换 IP 不影响）；`token`/`guest_token` 双向合并；指纹变化即拒绝自动连接 |
| 8 | 文件互传 | `transfer.py` | TCP 45992 TLS1.3；control 连接：`hello{instance,token,name}`→`offer{files[id,name,size,sha256]}`→`accept{workers}`→`file_done/file_ok/progress/bye`；data 连接：`chunk-open`→`ready`→`chunk{id,offset,length}`→二进制→`ok`；8MB 分块、按 CPU 核数并行、预分配、可选 sha256 校验 |
| 9 | 我的共享（主机） | `host_share.py` | 生成 PowerShell 脚本（建只读账号 + SMB 共享 + 防火墙规则），UAC 提权执行；或录入已有共享；配置 DPAPI 加密 |
| 10 | 评分 / 已看 | `ratings.py` | `ratings.json` v1；1–10 分、播放次数、最后观看；键 = `sha256(path\|size\|mtime)`；卡片显示 `★ 9` / `—` / 已看 |
| 11 | 库管理 | `ui.py` | 最近库列表（本地 + SMB）、欢迎页三张快捷卡、面包屑、前进/后退/上一级/片库根、搜索过滤、网格/列表切换、侧栏三面板（附近设备/传输/看过·评分） |
| 12 | 设计系统 | `theme.py`、`design/tokens.css` | "Graphite & Gate"：暖石墨底 `#0F1011/#131416/#18191C`、琥珀强调 `#E2A24C/#F59E0B`、8/12 圆角、发丝线、等宽时间码、三态（未看蓝/在看琥珀/已看灰） |

### 1.2 协议可复刻性结论

**发现与配对协议 100% 可复刻**，字段全部明确，无 Windows 专有依赖：

- X25519 / HKDF-SHA256 / AES-256-GCM → **CryptoKit** 原生支持
- TLS 1.3 自签证书 + 指纹 pin → **Network.framework**（`sec_protocol_options_set_verify_block`）
- RSA-PSS-SHA256 guest 证明 → **Security.framework** `SecKeyCreateSignature(.rsaSignatureMessagePSSSHA256)`
- JSON 行协议 → `JSONSerialization` / `Codable`

唯一 Windows 专有项：DPAPI（凭据加密）。iOS 用 **Keychain**（`kSecClassGenericPassword` + `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）替代，安全等级不低于 DPAPI。

---

## 二、移植映射表

| 模块 | Windows | iOS 方案 | 说明 |
|---|---|---|---|
| UI | PySide6 QWidget | **SwiftUI**（iOS 16+） | 复刻 Graphite & Gate tokens；iPad 横屏双栏 |
| 播放器 | libmpv（DLL） | **MPVKit**（SPM，libmpv xcframework） | 全格式（mkv/rmvb/avi/ts…）+ 硬解 + 字幕/音轨轨切换，与桌面端行为一致；AVPlayer 不支持这些容器，不可用 |
| 本地文件 | `os.scandir` | `FileManager` + security-scoped bookmark | 文件 App 选文件夹 → 存 bookmark 持久访问；TrollStore 环境可选全盘权限（默认不用） |
| 缩略图 | ffmpeg 抽帧 | **AVAssetImageGenerator 优先 + libmpv 截帧回退** | mp4/mov 走原生（快）；mkv/rmvb 走 mpv `screenshot-raw`；同一套 sha1 缓存键 |
| SMB 客户端 | WNetAddConnection2W | **AMSMB2**（SPM，libsmb2） | SMB2/3；凭据存 Keychain；UNC 语义映射为 `smb://server/share/path` |
| SMB 播放 | mpv 直接开 UNC | **本地 HTTP Range 代理**（127.0.0.1） | AMSMB2 读 → 内置 HTTP 服务 → mpv 播 `http://127.0.0.1:port/...`；seek 走 Range；同一套服务器复用于「我的共享」 |
| 发现 | UDP 组播 + X25519/AES-GCM | **Network.framework** `NWConnectionGroup` + CryptoKit | 需要 multicast entitlement（TrollStore 可注入，无需 Apple 审批） |
| 配对 | TLS1.3 自签 + 指纹 pin | `NWListener` + `NWProtocolTLS` + Security 自签证书 | wire 格式逐字段一致，可与 Windows 端互配 |
| 互传 | TCP TLS 双连接 | `NWConnection` + `NWProtocolTLS` | control/data 双连接、8MB chunk、并行 workers 全保留 |
| 我的共享 | Windows SMB 共享 | **内置 HTTP Range 共享服务**（替代） | iOS 无法开 SMB 服务端；改为把选定文件夹暴露为局域网 HTTP 源，生成二维码/链接。Windows 端访问需第二阶段加 HTTP 源支持 |
| 评分/已看 | JSON + DPAPI | JSON + Keychain（仅凭据） | 数据格式对齐，便于将来导入导出 |
| 构建 | PyInstaller | **GitHub Actions macOS + xcodebuild 无签名 + Payload zip** | 与 Aidoku 同一套流水线，TrollStore 直接装 |

### 2.1 「我的共享」的处理（唯一功能替换）

iOS 是沙盒客户端系统，**没有公开方式创建 SMB 共享**，也没有成熟的 iOS SMB server 开源库。三个选项：

- **A（采用）**：内置 HTTP Range 服务器共享文件夹。局域网内任何设备（含 Windows 端 Cinefile 后续版本、VLC、浏览器）可访问；iOS 端自身也能把该服务当作「本机片库」。
- B：砍掉该功能（iOS 只做客户端）。
- C：内嵌第三方 SMB server（无可靠开源实现，放弃）。

采用 A：功能语义不变（「把本机文件夹共享给局域网设备播放」），协议从 SMB 换成 HTTP。Windows 端要反向访问 iOS 共享，需要在 Python 端加 HTTP 源支持（第二阶段，约 300 行）。

---

## 三、iOS 工程结构

```
Cinefile-iOS/
├─ project.yml                      # XcodeGen
├─ Cinefile/
│  ├─ App/
│  │  ├─ CinefileApp.swift          # @main
│  │  ├─ AppState.swift             # 全局状态机
│  │  └─ Info.plist                 # NSLocalNetworkUsageDescription 等
│  ├─ Design/
│  │  ├─ Theme.swift                # tokens：颜色/字号/间距/圆角
│  │  └─ Components.swift           # 按钮/徽章/卡片/空状态
│  ├─ Browser/
│  │  ├─ LibraryStore.swift         # 最近库、bookmark 持久化
│  │  ├─ DirectoryModel.swift       # 枚举/排序/过滤（对齐 library.py）
│  │  ├─ BrowserView.swift          # 面包屑 + 网格 + 列表
│  │  └─ VideoCard.swift
│  ├─ Thumbnails/
│  │  ├─ ThumbnailService.swift     # AVAssetImageGenerator + mpv 回退 + 磁盘缓存
│  │  └─ ThumbnailCache.swift
│  ├─ Player/
│  │  ├─ MPVPlayer.swift            # MPVKit 封装（load/pause/seek/volume/tracks/screenshot）
│  │  ├─ PlayerView.swift           # 控制条 + 自动隐藏 + 手势
│  │  └─ PlayerModel.swift          # 进度/时长/轨道/结束回调
│  ├─ SMB/
│  │  ├─ SMBClient.swift            # AMSMB2 封装（list/stat/read）
│  │  └─ LocalHTTPProxy.swift       # SMB → 127.0.0.1 HTTP Range
│  ├─ Peer/
│  │  ├─ Identity.swift             # instance_id + 自签证书（Keychain）
│  │  ├─ Discovery.swift            # 组播查询/加密回应（CryptoKit）
│  │  ├─ PairingServer.swift        # TLS 服务端
│  │  ├─ PairingClient.swift        # TLS 客户端 + 指纹 pin
│  │  ├─ PeerStore.swift            # peers.json + Keychain 凭据
│  │  └─ PeerService.swift          # 状态机：announce/重连/在线判定
│  ├─ Transfer/
│  │  ├─ TransferServer.swift       # control + data 双连接
│  │  └─ TransferSender.swift       # 分块并行上传
│  ├─ Share/
│  │  └─ HTTPServer.swift           # 「我的共享」Range 服务 + 二维码
│  ├─ Ratings/
│  │  └─ RatingStore.swift          # ratings.json
│  └─ Panels/
│     ├─ DevicesView.swift          # 附近设备
│     ├─ TransfersView.swift        # 传输队列
│     └─ RatingsView.swift          # 看过·评分
└─ .github/workflows/build-ipa.yml
```

依赖（SPM）：
- `https://github.com/mpvkit/MPVKit`（libmpv xcframework，iOS arm64）
- `https://github.com/amosavian/AMSMB2`（libsmb2 封装）

---

## 四、分阶段实施

| 阶段 | 内容 | 交付/验收 |
|---|---|---|
| **M0 脚手架 + 构建链路** | XcodeGen 工程、SwiftUI 骨架、GitHub 仓库 + Actions（macos-26，xcodebuild archive 无签名 → IPA）、TrollStore 安装验证 | 空壳 App 能装能启动 |
| **M1 浏览 + 缩略图** | 本地文件夹选择/bookmark、目录枚举与自然排序、16:9 网格、缩略图异步生成与缓存、面包屑/搜索/网格列表切换 | 本地片库浏览体验对齐桌面端 |
| **M2 播放器** | MPVKit 集成、控制条（seek/±10s/音量/全屏）、字幕/音轨循环、2.8s 自动隐藏、结束标记已看、播放中评分 | 本地 mkv/mp4/rmvb 播放全通 |
| **M3 SMB** | AMSMB2 连接对话框、凭据 Keychain、UNC 浏览、本地 HTTP Range 代理 → mpv 播放、最近库列表 | 连 Windows 共享浏览 + 播放 |
| **M4 发现 + 配对** | 组播查询/加密回应、TLS 配对服务/客户端、6 位码/免码 + 主机批准、一次对码双向交换、PeerStore、自动重连 | 与 Windows 端 0.3.2 互相发现、配对成功 |
| **M5 互传** | control/data 双连接、8MB 分块、并行 workers、进度/接受/取消、接收目录 | 与 Windows 端双向传文件 |
| **M6 共享 + 面板 + 打磨** | HTTP Range 共享服务 + 二维码、三面板、评分面板、设计系统统一、空状态/错误处理 | 功能对齐清单全绿 |
| **M7 回归** | 双机互通测试（iPad ↔ Windows）、边界（断网/证书变化/端口占用）、构建产物校验 | 可交付 IPA |

每个阶段都走「本地写代码 → push → Actions 构建 → 下载 IPA → 设备验证」的闭环。

---

## 五、构建流水线（复用 Aidoku 经验）

```yaml
runs-on: macos-26
steps:
  - checkout（本仓库：工程 + workflow）
  - brew install xcodegen ldid
  - xcodegen generate
  - xcodebuild archive -scheme Cinefile -destination generic/platform=iOS \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  - 从 .xcarchive 取 .app → Payload/ → zip 成 Cinefile-unsigned.ipa
  - ldid -S 预签主二进制与嵌入 framework（TrollStore 兜底）
  - upload-artifact
```

产物：`Cinefile-unsigned.ipa`（预计 80–120 MB，含 libmpv + libsmb2）。

---

## 六、风险清单

| 风险 | 影响 | 对策 |
|---|---|---|
| iOS 组播需要 `com.apple.developer.networking.multicast` entitlement | 发现功能不可用 | TrollStore 安装时注入该 entitlement（未签名 IPA 可携带任意 entitlements）；若失效，回退「手动输入 IP 配对」+ 单播发现 |
| MPVKit 体积/构建时长（首次 SPM 拉 ~100MB） | Actions 超时风险 | 缓存 SPM；必要时锁定 MPVKit 版本 tag |
| 嵌入的 framework 未签名导致 TrollStore 启动崩溃 | App 打不开 | CI 里 `ldid -S` 预签所有 framework；安装后首启验证 |
| SMB 播放 seek 体验 | 大文件拖动卡顿 | 本地 HTTP 代理实现 Range + 256MB 预读窗口；mpv `cache=yes` |
| iOS 后台挂起断连 | 配对/传输中断 | 前台运行时互联（与桌面端语义一致）；传输页明确提示「保持前台」 |
| 本地网络权限弹窗 | 首次发现无结果 | 启动引导页说明并主动触发一次本地网络访问 |
| 大文件缩略图（SMB） | 首屏慢 | 只读文件头 + mpv 截帧；先占位后替换；并发 3 |

---

## 七、默认决策（无需确认，除非要改）

1. **播放器用 MPVKit**（不是 AVPlayer）——保证 mkv/rmvb/avi/ts 全格式，与桌面端一致。
2. **最低 iOS 16.0，iPad 横屏优先**——匹配你的 iPadOS 16.4.1。
3. **「我的共享」用 HTTP Range 共享替代 SMB 共享**——iOS 系统限制，功能语义不变。
4. **凭据用 Keychain 替代 DPAPI**——iOS 等价安全方案。
5. **协议逐字段对齐 v2.2**——iOS 与 Windows 0.3.2 可直接互配、互传。

---

## 八、验收清单（与 Windows 端对测）

- [ ] iPad 浏览本地文件夹，缩略图网格正常，排序与桌面一致
- [ ] 本地 mkv / mp4 / rmvb 播放，seek、字幕、音轨、全屏、自动隐藏正常
- [ ] iPad 连 Windows SMB 共享，浏览 + 播放 + seek 正常
- [ ] Windows 端发现 iPad，输入 6 位码配对成功；iPad 反向看到 Windows 设备
- [ ] 一次对码后双向互访（Windows 浏览 iPad 共享的 HTTP 源需第二阶段；iPad 浏览 Windows 共享应即时可用）
- [ ] 双向互传文件，进度、校验、取消正常
- [ ] 评分/已看在卡片、播放器、评分面板三处同步
- [ ] 杀进程重启后：最近库、配对记录、评分均保留
