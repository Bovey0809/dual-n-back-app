# 恢复手册(锁屏出问题时按顺序尝试)

1. **锁屏内"紧急跳过"**:输入指定长句 + 等待 60 秒(滚动 7 天限 2 次)。
2. **另开终端 / SSH**:
   `launchctl bootout gui/$(id -u)/com.dualnback.lock`
   然后 `rm ~/Library/LaunchAgents/com.dualnback.lock.plist`
3. **安全模式**:开机长按电源键(Apple Silicon)进入安全模式,LaunchAgent 不会加载;
   删除上述 plist 后正常重启。
4. **Recovery 模式终端**:`rm /Users/<用户名>/Library/LaunchAgents/com.dualnback.lock.plist`

重置训练进度/跳过配额:删除
`~/Library/Application Support/dualnbackapp/lock-state.json`(app 未运行时)。

## 已知边界(设计如此)

- Cmd+Opt+Esc 强退无法禁止,但 launchd 会在数秒内重新拉起锁屏
  (短时间反复强退会触发约 10 秒的 launchd 节流)。
- Cmd+Tab 可以切换,但锁窗覆盖所有工作区,切走也无法操作其他应用。
- 连续异常保护:锁定态下 5 分钟内启动 ≥5 次,锁屏自动降级为普通窗口 1 小时,防止 bug 导致死循环。
- 修改系统时钟可以骗过"今天"判定 —— 自律工具,不设防。
