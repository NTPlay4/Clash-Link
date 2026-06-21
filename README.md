# Clash-Link 网络检测器

基于 Clash 代理的网络可达性自动检测与节点切换工具，支持 LuCI Web 界面配置。

## 功能概述

- **多任务检测**：可配置多个独立的检测任务，每个任务有不同的检测目标和策略组
- **自动节点切换**：检测失败时自动切换到策略组中的下一个节点
- **Webhook 通知**：支持以下通知场景，兼容 Bark / 企业微信 / 钉钉 / 飞书等
  - **恢复通知**：节点失效切换后恢复正常访问，告知切换详情及失败原因（无法连接/被封）
  - **全部失败通知**：所有节点均尝试失败，通知失败起因
  - 可独立开关各类通知
- **Web UI 配置**：所有参数通过 LuCI 界面配置，无需手动编辑文件
  - 策略组下拉选择（自动从 Clash API 拉取）
  - Secret 一键获取（点击按钮从 OpenClash 配置自动填入）
  - 日志实时刷新、一键清除、一键下载
  - 立即检测按钮（30 秒冷却）
  - 检测任务可排序（上移/下移）
  - 当日切换/失败次数统计（自动每日重置）
- **定时运行**：支持秒/分/时三种粒度，秒级 <60s 通过内部循环实现，分/时级通过 cron 调度
- **自定义检测间隔**：独立配置间隔数值与单位，灵活调整检测频率
- **智能失败分类**：区分「无法连接」和「被封」两种失败原因
- **简洁通知**：恢复通知区分失败原因，全部失败通知保留起因

## 项目结构

```
d:/openwrt/
├── network-detector/              # 核心包
│   ├── Makefile                   # OpenWrt 包编译脚本
│   └── files/
│       ├── etc/
│       │   ├── config/
│       │   │   └── network-detector   # UCI 默认配置
│       │   ├── init.d/
│       │   │   └── network-detector   # procd 服务脚本
│       │   └── uci-defaults/
│       │       └── 99-luci-network-detector  # 首次安装初始化
│       └── usr/
│           └── bin/
│               └── network-detector   # 检测核心脚本
│
├── luci-app-network-detector/     # LuCI Web 界面包
│   ├── Makefile                   # OpenWrt LuCI 编译脚本
│   ├── luasrc/
│   │   ├── controller/
│   │   │   └── admin/
│   │   │       └── network_detector.lua   # LuCI 路由与 API 端点
│   │   ├── model/
│   │   │   └── cbi/
│   │   │       └── network_detector.lua  # CBI 配置页（表单 + 增强 JS）
│   │   └── view/
│   │       └── network_detector/
│   │           └── status.htm         # 运行状态页面
│   └── root/
│       └── etc/
│           └── uci-defaults/
│               └── 99-luci-network-detector  # 首次安装初始化
│
```

## 使用方法

### Web 界面

安装后在 LuCI 菜单中找到：`服务` → `网络检测器`

**配置** 页签（页面布局从上到下）：

1. **全局设置**：启用/禁用服务、检测间隔（数值+单位）、日志保留天数
2. **Clash API 设置**：API 地址、密钥（点击「自动获取」按钮从 OpenClash 配置获取，失败弹窗提示）、代理类型、代理地址
3. **Webhook 通知设置**：启用/禁用、Webhook URL、分别控制恢复/全部失败的通知开关
4. **检测任务列表**：动态表格，可添加/删除/上移下移排序多个任务
5. **字段说明**：任务表格下方字段含义提示
6. **运行日志**：实时显示最近日志（每 5 秒自动刷新），支持清除和下载
7. **快捷操作**：立即检测按钮（触发后 30 秒冷却）

**运行状态** 页签：
- 服务运行状态横幅（运行中/已停止）
- 快速统计卡片（任务总数、活跃任务）
- 检测任务列表：每个任务卡片显示启用状态、策略组、检测 URL、**当日切换/失败次数**（15 秒自动刷新）
- 最近日志（终端风格，5 秒自动刷新，支持高亮着色）

# 手动控制

### 启动服务
```
/etc/init.d/network-detector start
```

### 停止服务
```
/etc/init.d/network-detector stop
```

### 重启服务
```
/etc/init.d/network-detector restart
```

### 手动运行一次
```
/usr/bin/network-detector
```

## 配置说明 (UCI)

配置文件：`/etc/config/network-detector`

### 全局设置 (main)

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `enabled` | 启用服务 | `1` |
| `interval_value` | 检测间隔数值 | `60` |
| `interval_unit` | 间隔单位 (`s`/`m`/`h`) | `s` |
| `log_retention_days` | 日志保留天数 | `3` |

### Clash API 设置 (clash)

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `api_url` | Clash 外部控制 API 地址 | `http://127.0.0.1:9090` |
| `secret` | API 密钥（点击按钮从 OpenClash 获取） | (空) |
| `proxy_type` | 代理协议类型 (`http`/`socks5`) | `http` |
| `local_proxy` | 本地代理地址 | `127.0.0.1:7890` |

### Webhook 通知 (webhook)

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `enabled` | 启用 Webhook 通知 | `0` |
| `url` | Webhook URL | (空) |
| `notify_recover` | 节点恢复时发送通知 | `1` |
| `notify_allfail` | 全部失败时发送通知 | `1` |

### 检测任务 (task)

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `enabled` | 是否启用该任务 | `1` |
| `name` | 任务名称 | (必填) |
| `proxy_group` | Clash 策略组名称 | (必填) |
| `test_url` | 通过代理访问的检测 URL | (必填) |
| `banned_keyword` | IP 被封关键词（留空仅检查 HTTP 连通性） | (可选) |
| `max_tries` | 最大节点切换次数 | `5` |

## API 端点

配置页提供以下 AJAX 端点（需登录 LuCI）：

| 端点 | 说明 |
|------|------|
| `GET /proxy_groups` | 从 Clash API 获取策略组名称列表 |
| `GET /log` | 获取最近日志（纯文本） |
| `GET /run` | 立即运行一次检测（后台执行） |
| `GET /clearlog` | 清除所有日志 |
| `GET /detectsecret` | 自动检测 OpenClash Secret |
| `GET /downloadlog` | 下载完整日志文件 |
| `GET /counters` | 获取当日切换/失败计数 (JSON) |

## 依赖

- OpenWrt 21.02+
- curl
- jsonfilter (来自 libubox)
- cron
- luci-base (仅 LuCI 界面需要)
- Clash / OpenClash (或其他兼容 Clash API 的代理客户端)

## 许可证

GPL-2.0
