# 每日开机训练锁(Boot Training Lock)设计文档

日期:2026-07-18
状态:已与用户逐节确认

## 1. 目标

给 dual n-back Electron 应用增加"每日训练锁":每天首次使用 Mac 时进入全屏锁定,
必须累计完成 20 分钟 dual n-back 训练才能正常使用电脑,类似 iOS 上"不打卡就不能用手机"的应用。

## 2. 已确认的产品决策

| 决策点 | 结论 |
|---|---|
| 强度 | 硬核自律锁:全屏 kiosk + 屏蔽常用快捷键 + 强退后自动拉起。防"意志力薄弱的自己",不追求系统级不可绕过 |
| 触发时机 | 每天首次使用(登录、开机、睡眠唤醒、解锁屏都算触发点);当天完成后不再触发 |
| 完成标准 | 当日累计训练满 20 分钟;游戏运行中超过 90 秒无有效输入则暂停计时并提醒(防挂机);不考核正确率 |
| 应急出口 | 锁屏界面提供"紧急跳过":手动输入指定长句 + 强制等待 60 秒;滚动 7 天内限 2 次;使用记录在案 |
| 中断处理 | 进度每 5 秒落盘、当日累计;崩溃/强退/离开后回来从剩余时长继续 |
| 配额与自由训练 | 自由训练同样计入当日配额。锁定的语义是"今日未完成",不是"没在锁屏里练"。每日配额固定由 config.dailyMinutes 决定(默认 20),与界面上自由训练的 Session 时长下拉框无关 |

## 3. 总体方案(已选定方案 A)

单一 Electron 应用双模式(锁定模式 / 常规模式)+ macOS launchd LaunchAgent。

排除的备选:
- 独立守卫进程:更抗强退,但两个产物、复杂度翻倍;launchd KeepAlive 已能秒级复活,收益小
- 系统能力(屏幕使用时间 / 专注模式 / MDM):无公开 API 支持"训练后解锁",专注模式只静音通知,MDM 面向企业,均不可行

## 4. 架构与组件

```
~/Library/LaunchAgents/com.dualnback.lock.plist     ← 系统层
    RunAtLoad=true                     登录即启动(带 --autostart,静默后台)
    KeepAlive={SuccessfulExit=false}   非正常退出(强退/崩溃)→ launchd 自动拉起
                                       正常 exit(0) → 不拉起(仅连续崩溃保护路径使用)

Electron 主进程(main.js 精简为入口,逻辑拆模块)
    src/main/lock-state.js     状态持久化:userData/lock-state.json,原子写入(临时文件+rename)
    src/main/lock-manager.js   核心状态机 + 计时权威
    src/main/kiosk.js          锁屏窗口管理(kiosk/置顶/多显示器/快捷键屏蔽)
    src/main/launch-agent.js   plist 安装/卸载(app 内开关)
    src/preload.js             contextBridge,渲染层只见最小 IPC API

渲染层
    src/renderer/index.html    现有训练 UI + 锁定模式形态 + 空闲检测 + 暂停
    src/renderer/blackout.html 副显示器纯黑遮罩页
```

现有 `main.js` 的单实例锁(`requestSingleInstanceLock`)保留:LaunchAgent 常驻实例 +
用户手动再开 app 时,第二实例退出并聚焦常驻实例。

### 4.1 状态机(主进程持有,渲染层只是显示器)

```
触发点:app 启动 / powerMonitor resume·unlock-screen / 跨天检查(每 60 秒)
                      │
                evaluateLock()
                      │
   今日已完成或已跳过? ──是──► IDLE(常驻后台,无窗口)
                      │否
                      ▼
                   LOCKED ──累计满 dailyMinutes──► UNLOCKED_TODAY(写完成日期,撤锁屏)
                      │
              跳过流程通过 ─────────────────────► UNLOCKED_TODAY(记录跳过,扣周配额)
```

### 4.2 计时权威与防挂机

- 计时和解锁判定全部在主进程;渲染层每秒发心跳 `{gameRunning, secondsSinceLastInput}`
- 主进程仅在 `gameRunning && secondsSinceLastInput < 90` 时累计,每 5 秒落盘
- 主进程校验累计速度不得超过墙钟流逝(每次心跳最多 +min(1, 实际间隔) 秒),页面被篡改也刷不了进度
- "有效输入"= 锁窗内的 A / L / Space 按键或响应按钮点击;鼠标移动不算
- 空闲超过 90 秒:游戏自动暂停(停止出题)+ 计时暂停 + 显示"还在吗?按任意键继续"遮罩;恢复输入后继续

### 4.3 状态文件 `userData/lock-state.json`

```json
{
  "progressDate": "2026-07-18",
  "progressSecondsToday": 736,
  "lastCompletedDate": "2026-07-17",
  "skips": ["2026-07-14T09:02:11+08:00"],
  "recentLaunches": ["2026-07-18T08:00:01+08:00"],
  "config": {
    "dailyMinutes": 20,
    "idleThresholdSeconds": 90,
    "skipsPerWeek": 2,
    "skipWaitSeconds": 60,
    "skipPhrase": "我承认我今天没有完成训练,我欠自己20分钟"
  }
}
```

- "今天"按本地日历日;`progressDate` ≠ 今天 → 进度清零
- 跳过配额按滚动 7 天窗口计数
- 文件在 `userData`,app 覆盖升级不影响;写入方式为临时文件 + rename(POSIX 原子)
- 不在 localStorage 存这些:主进程在建窗前就要决策,且需防渲染层篡改

### 4.4 锁屏形态(kiosk.js)

- 主显示器:`kiosk: true` + `setAlwaysOnTop(true, 'screen-saver')` + `visibleOnAllWorkspaces`,
  加载训练 UI(锁定模式):顶部大字"今日剩余 XX:XX",隐藏历史记录区与 Session 时长设置,
  n-level / 速度仍可调
- 锁屏弹出后不自动开始游戏:显示剩余配额与"开始训练"按钮,由用户按 Start/Space 开局;
  计时只在游戏运行且非空闲时累计(§4.2 心跳规则天然保证)
- 副显示器:各盖一张 blackout 全黑窗口;监听 `screen` 事件,热插新显示器立即补盖
- 屏蔽 Cmd+Q / Cmd+W / Cmd+H / Cmd+M(globalShortcut),清空应用菜单,窗口不可关闭/最小化;
  LOCKED 态下 `before-quit` 一律 `preventDefault`
- 诚实边界(写入 README):Cmd+Opt+Esc 强退与 Cmd+Tab 无法从用户态彻底禁止;
  但强退后 launchd 立即拉回锁屏(短时间反复退出时 launchd 有约 10 秒节流),
  切走后锁窗仍覆盖所有工作区,实际绕不过去

### 4.5 常驻语义

- 常规模式下关窗 / Cmd+Q 仅隐藏窗口,进程保持常驻(用于检测唤醒和跨天)
- 程序正常路径不调用 `exit(0)`;唯一允许真正退出的状态是连续崩溃降级态(见 §6)
- 因此"干净退出后 launchd 不再拉起、次日锁失效"的漏洞在正常使用中不存在

### 4.6 IPC 契约(preload 暴露的全部接口)

| 接口 | 方向 | 载荷 |
|---|---|---|
| `lock:get-state` | 渲染→主 (invoke) | → `{mode, remainingSeconds, skipsRemaining, idleThresholdSeconds}` |
| `lock:heartbeat` | 渲染→主 (每秒 send) | `{gameRunning, secondsSinceLastInput}` |
| `lock:state-changed` | 主→渲染 (push) | `{remainingSeconds, pausedForIdle, unlocked}` |
| `lock:request-skip` | 渲染→主 (invoke) | `{phrase}` → 校验长句+周配额;主进程计时 60 秒后解锁并推送 |

`webPreferences` 保持 `contextIsolation: true, nodeIntegration: false`,新增 preload。

## 5. LaunchAgent 细节

```xml
<key>Label</key><string>com.dualnback.lock</string>
<key>ProgramArguments</key>
<array>
  <string>{安装时通过 app.getPath('exe') 取得的二进制路径}</string>
  <string>--autostart</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ProcessType</key><string>Interactive</string>
```

- app 设置页开关"开机锁屏训练":开 → 写 plist + `launchctl bootstrap gui/$UID`;
  关 → `launchctl bootout` + 删 plist(会终止常驻进程,界面上明示)
- 全部动作在用户目录内,不需要 sudo
- plist 记录的是安装时的二进制路径;用户移动 app 后需重新开关一次(设置页显示 agent 状态指示灯)
- `--autostart`:静默启动,不弹常规窗口,由 evaluateLock 决定是否弹锁屏
- 开发时 `npm start` 不带该参数,agent 逻辑不触发;`--test-lock dailyMinutes=0.5` 可把配额缩成 30 秒做手动验证

## 6. 异常处理

| 场景 | 处理 |
|---|---|
| 锁定中崩溃/被强退 | launchd 拉回;进度落盘间隔 5 秒,最多丢 5 秒 |
| 连续崩溃保护 | `recentLaunches` 记录启动时间戳;LOCKED 态下 5 分钟内启动 ≥5 次 → 降级为常规窗口(非 kiosk)+ 顶部横幅"锁屏因连续异常暂停,请自觉完成训练"。降级后 1 小时内不再尝试 kiosk,之后任何触发点重新评估。降级态下 Cmd+Q 允许真正退出(exit(0),launchd 不拉起)。避免 bug 造成死循环变砖 |
| 睡眠/唤醒 | 睡眠中无心跳自然停钟;`powerMonitor.resume` 触发 re-evaluate:同日→续练,跨天→重置进度再判定 |
| 运行中跨天 | 每 60 秒查一次日期,变了→进度清零并 re-evaluate |
| 状态文件损坏 | JSON 解析失败→按"今日未完成、零进度"的默认态重建文件(宁可多练不可漏练),并保留坏文件为 `.corrupt` 备份 |
| LaunchAgent 被手动删除 | 安全退化:app 可手动运行,无自启/复活;设置页指示灯提示 |
| 多显示器热插拔 | `screen` 事件→新显示器立即盖 blackout |
| 系统时钟被改 | 明确不设防(自律工具,改时钟骗的是自己),写入文档 |

## 7. 恢复手段(防变砖阶梯)

1. 锁屏内"紧急跳过"(长句 + 60 秒,周限 2 次)
2. 终端/SSH:`launchctl bootout gui/$UID/com.dualnback.lock`
3. 安全模式启动(LaunchAgent 不加载)
4. Recovery 终端删除 `~/Library/LaunchAgents/com.dualnback.lock.plist`

以上写入 `docs/RECOVERY.md` 随仓库分发。

## 8. 测试策略

| 层 | 内容 | 工具 |
|---|---|---|
| 纯逻辑单元测试 | lock-state 读写与损坏恢复、"今天"判定与跨天清零、跳过配额(滚动 7 天)、心跳累计(空闲暂停、墙钟上限)、连续崩溃判定 | vitest(新增 devDependency),纯函数不依赖 Electron |
| IPC 集成 | preload 接口与主进程 handler 契约一致 | Electron 手动/脚本验证 |
| 端到端手动 checklist | 用 `--test-lock dailyMinutes=0.5`:① 触发→锁→练满→解锁;② kill -9 → 拉回且进度保留;③ 空闲 90 秒→暂停→回归继续;④ 第 3 次跳过被拒;⑤ 睡眠唤醒恢复;⑥ 跨天清零;⑦ 双显示器遮罩;⑧ 开关 agent 生效/干净卸载 | 手动 |

## 9. 目录变更

```
dual-n-back-app/
├── main.js                    # 精简入口
├── src/
│   ├── main/
│   │   ├── lock-state.js
│   │   ├── lock-manager.js
│   │   ├── kiosk.js
│   │   └── launch-agent.js
│   ├── preload.js
│   └── renderer/
│       ├── index.html         # 现有文件迁移至此,增量加入锁定模式 UI
│       └── blackout.html
├── test/lock-state.test.js
├── docs/RECOVERY.md
└── package.json               # files 字段与 vitest 更新
```

现有 1670 行 index.html 不做整体重构,锁相关 UI(剩余时间 banner、空闲遮罩、跳过弹窗)
以明确的 CSS class toggle 增量加入。

## 10. 范围外(明确不做)

- 防系统时钟篡改
- Windows / Linux 支持(打包本就仅 darwin-arm64)
- 与 macOS 专注模式/勿扰的联动、通知抑制
- 正确率考核门槛(仅时长 + 防挂机)
- 多用户 Mac 的跨账户封锁(LaunchAgent 本就 per-user)
