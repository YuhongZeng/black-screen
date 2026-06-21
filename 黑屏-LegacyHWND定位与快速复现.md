# 黑屏定位（仅靠 WinDbg/Trace/Spy++）+ 快速复现方案

> 新增关键现象：正常时 VSCode 有 **"Intermediate D3D Window"** 和 **"Chrome Legacy Window"(`Chrome_RenderWidgetHostHWND`)** 两个内部窗口；**黑屏时 "Chrome Legacy Window" 消失，只剩一个；黑屏恢复后它又回来。**
> 编写日期：2026-06-18。配套：`黑屏定位与修复-执行Playbook.md`、`黑屏问题分析与修复.md`。

---

## 0. 这条现象意味着什么（先定性）

- **`Chrome_RenderWidgetHostHWND`（标题 "Chrome Legacy Window"）= Chromium 的 `LegacyRenderWidgetHostHWND`**：由主窗口 web-contents 的**根 `RenderWidgetHostViewAura`** 拥有。但它**不是常驻窗口**——它是**无障碍(MSAA/IAccessible/UIA)按需懒创建**的影子窗口（也兼老式 IME）。
- ⚠️ **重要更正（回答“为什么我本地正常时没有这个窗口”）**：现代 Chromium/Electron 默认走 **windowless + DirectComposition** 渲染，**不需要这个子 HWND**，所以**没有挂任何屏幕阅读器/检查工具时它根本不存在**。只有当某个 **AT/检查客户端**（Spy++、Inspect.exe、Accessibility Insights、Narrator/NVDA、UiPath/AutoIt 等）或 `--force-renderer-accessibility` 触发 Chromium 建立原生无障碍树时，它才被**懒创建**出来。你之前能看到它“出现/消失”，正是因为当时挂着检查工具；工具断开或视图重置，它就没了。
- **`Intermediate D3D Window` = `gpu::ChildWindowWin` / `DirectCompositionChildSurfaceWin`**：GPU 进程里给 DirectComposition 呈现用的窗口。**真正出像素的是它这条合成面，不是 Legacy 窗口。**
- 所以“黑屏时 Legacy 窗口消失”**不是黑的直接原因，而是一个伴随信号**：它归根视图所有，它消失 ⇒ **根视图对象被销毁/重建了**（且 DMP 健康 ⇒ 不是进程崩溃，是同进程内的视图重置，多半伴随合成器丢失重建/显示重配）。黑的本质仍是 **合成面在视图重置后没重新挂上**。
- **拖动窗口/改尺寸能恢复**：`WM_SIZE`/可见性变化触发根视图重新挂回根窗口 + 合成面重建 → 恢复（此时 a11y 客户端在的话，Legacy 窗口也被重建）。

> 结论：**Legacy 窗口的销毁事件 = “案发瞬间”的好标记，但要把它当“伴随信号”而非根因**；抓“是谁销毁了根视图 / 合成面为何没重挂”，根因就定了——**完全不需要源码**。
> ⚠️ 用它做信号有个前提：**必须全程挂着一个 a11y 客户端**（或 `--force-renderer-accessibility` 启动），否则“工具断开导致它消失”会被误当成“黑屏导致它消失”。主力观测应放到 **Intermediate D3D Window / DirectComposition 合成面**（见 §1 第 3 段加观测）。

> 注：你们启动参数里有 `--disable-features=CalculateNativeWinOcclusion`，意味着 **Chromium 不靠原生遮挡判断**。所以“被别的窗口盖住”在 Chromium 看来未必算遮挡；真正能让根视图进入 hidden/摘除的，主要是 **最小化、显示器/DPI 变化(WM_DISPLAYCHANGE)、会话锁屏/睡眠唤醒**。这对“快速复现”很关键（见 §3）。

---

## 1. 能不能只靠 WinDbg/Trace/Spy++ 定位清楚？—— 能。三段式取证

### 第 1 段 · Spy++：把“案发瞬间”和“消息序列”拍下来
目的：确认是 `WM_DESTROY`（销毁）而非隐藏，并抓到销毁前的消息上下文。

1. 用 Spy++ 的 Finder Tool 在正常状态定位窗口树：
   `顶层窗口` → `Chrome_WidgetWin_1`(或 `_0`) → 子：`Chrome_RenderWidgetHostHWND`("Chrome Legacy Window") + `Intermediate D3D Window`。
   记下 `Chrome_WidgetWin_1` 的 HWND（父窗口在整个过程里**不会消失**，对它挂日志最稳）。
2. 对 **父窗口 `Chrome_WidgetWin_1`** 启动 Messages 日志，勾选：
   - `WM_PARENTNOTIFY`（**关键**：子窗口创建/销毁会通过它通知父窗口，能精确拍到 Legacy 窗口何时被销毁/重建）
   - `WM_SIZE` / `WM_WINDOWPOSCHANGED` / `WM_SHOWWINDOW`
   - `WM_DISPLAYCHANGE` / `WM_DPICHANGED` / `WM_SETTINGCHANGE`
   - `WM_ACTIVATEAPP` / `WM_ACTIVATE` / `WM_SYSCOMMAND`（最小化/恢复）
3. 同时对 **`Chrome_RenderWidgetHostHWND` 本体** 单独挂一份日志（勾 `WM_DESTROY`/`WM_NCDESTROY`/`WM_SIZE`，尤其留意有没有 **被设成 0×0 尺寸**再销毁）。
4. 复现黑屏 → 在日志里定位 Legacy 窗口的 `WM_DESTROY`，**回看它前面 1~2 秒的消息**：
   - 若前面是 `WM_DISPLAYCHANGE`/`WM_DPICHANGED` → 多屏/DPI 切换路径；
   - 若前面是最小化(`WM_SYSCOMMAND SC_MINIMIZE`)/`WM_SIZE 0x0` → 可见性/尺寸归零路径；
   - 若没有任何 OS 消息、纯内部触发 → 进程内逻辑（占用 WinDbg 那段确认）。
5. 恢复（拉伸）→ 确认 `WM_PARENTNOTIFY(WM_CREATE)` 重建 Legacy 窗口。

> 产出：黑屏 = Legacy 窗口被销毁的**实锤 + 触发它的外部消息类别**。

### 第 2 段 · WinDbg：抓“是谁销毁了它”（最决定性，你已有 Electron 142 PDB）
目的：拿到销毁 `LegacyRenderWidgetHostHWND` 的**调用栈**——这串栈直接点名根因。

附加到主进程（Browser 进程，含 UI 线程）。

> ⚠️ **不要直接 `bm *...* + be *`**：`bm` 是通配批量下断，一个 `*...*` 会命中一堆同名/内联副本（实测 ~19 个）；而 `WasHidden/WasShown/SetVisible` 是**高频函数**，每次命中还 `k`（打全栈要加载符号）= 在热路径上单步 → **IDE 卡死**。正确做法是**只留 1 个罕见且决定性的销毁断点**。

#### 推荐：一个有条件的 `DestroyWindow` 断点（最省、最稳）
先拿到 Legacy 窗口 HWND（Spy++/Inspect，或用下面一次性创建断点抓一次），然后**只下这一个**：
```windbg
.logopen /t /u C:\dbg\legacy.log     ; 输出写文件，别刷控制台
bc *                                  ; 清掉之前所有断点
bp user32!DestroyWindow ".if (@rcx = 0x000001A2B3C4D5E0) { .echo >>> LEGACY DESTROY; k 15 } .else { gc }"
g
```
- `DestroyWindow` 不是高频；条件不满足立即 `gc`（不打印/不打栈/不卡），只有命中你那个 HWND 才停下打栈。
- 把 `0x...` 换成真实句柄；更底层可用 `win32u!NtUserDestroyWindow`（同样 `@rcx` 是 hwnd）。想停住手检就去掉 `gc`，想自动记录就保留。
- 抓一次 HWND 用一次性创建断点：`bp /1 user32!CreateWindowExW`（命中即删），或干脆从 Spy++ 拿。

#### 若要用符号断点：先 `x` 数数，再对**单个地址** `bp`（不要 `bm`）
```windbg
x codearts_agent!*LegacyRenderWidgetHostHWND*~*               ; 看析构到底几个
x codearts_agent!*RenderWidgetHostViewAura*RemovingFromRootWindow*
bp <析构地址>             ".echo === LEGACY_DTOR ===; k 12; gc"
bp <RemovingFromRoot地址>  ".echo === RWHVA_REMOVE ===; k 12; gc"
```
- **务必砍掉** `WasHidden`/`WasShown`/`Compositor::SetVisible`/`AddedToRootWindow`/`*Init*` —— 高频且对“谁销毁了它”无用，是卡死元凶。
- 降噪开关：`bd *` 全禁用后 `be <id>` 只启用销毁那 1–2 个（`bl` 看 id）；高频断点必须保留时用 `k 8` 限栈深、`.logopen` 写文件、绝不在其上 `k`。

复现黑屏 → 看 `>>> LEGACY DESTROY` / `=== LEGACY_DTOR ===` 那条的栈：
- 栈里若出现 `WindowTreeHost`/`occlusion`/`OnWindowVisibilityChanged` → 可见性/遮挡状态机；
- 栈里若出现 `display`/`DisplayChange`/`UpdateScreenInfo`/`UpdateVisualProperties` → 多屏/DPI 重配；
- 栈里若出现 `Compositor`/`recreate`/`OnContextLost` → 合成器丢失重建（软渲染管线层）。

> 这条栈就是“清楚的定位”。配合 §1.5 / Spy++ 的外部消息，就能完整说出“**外部什么事件 → 内部什么路径 → 销毁了根视图 HWND → 黑屏**”。

补充取证（可选）：黑屏瞬间对主进程和 GPU 进程各 `~*k` 看全部线程栈、`!handle 0 f Window` 看窗口句柄、确认根视图 HWND 句柄已释放。

### 第 3 段 · Trace（Perfetto，交叉验证时间线）
```
--trace-startup=ui,cc,viz,gpu,latency,toplevel,views --trace-startup-file="D:\trace.pftrace" --trace-startup-format=proto --trace-startup-duration=0 --trace-startup-record-mode=record-continuously
```
拖进 `ui.perfetto.dev`，把 Legacy 窗口销毁时间点对齐到 `Compositor::SetVisible`/`SetVisible (Did not end)`、`OnWindowOcclusionChanged`、`UpdateVisualProperties`，确认是哪条内部事件没收尾。

---

## 1.5 Spy++ 抓不到时的替代取证（API Monitor / WinDbg / WinEventHook）

### 为什么 Spy++ 常常没输出（先排除）
1. **`WM_PARENTNOTIFY` 被抑制**：Chromium 子窗口多半带 `WS_EX_NOPARENTNOTIFY` 创建，**父窗口收不到子窗口创建/销毁通知** —— 靠 `WM_PARENTNOTIFY` 这条思路在这里大概率失效（这是最常见原因）。
2. **位数不匹配**：`code.exe` 是 x64，必须用 **64 位 Spy++**（VS 自带 `spyxx_amd64.exe`）；用 32 位的什么都抓不到。
3. **未以管理员运行**：跨进程消息钩子要求 Spy++ 权限 ≥ 目标进程 → **以管理员启动**。
4. **选错进程**：顶层窗口/Legacy 窗口由**主(browser)进程**管，别选到渲染/GPU 进程句柄。

> 窗口生命周期应改用 **API 钩子直接抓 `CreateWindowEx`/`DestroyWindow`**，而非窗口消息。

### 方案一 · API Monitor（rohitab API Monitor v2）
前提：
- 用 **64 位**版、**以管理员运行**（位数必须对上 x64 的 `code.exe`）。
- 先定位**主进程**：命令行里**没有 `--type=` 的那个** `code.exe` 即 browser/主进程（Process Explorer 看命令行）。窗口 API 都在它里面发生，且**主进程无沙箱、可注入**；渲染/GPU 进程有沙箱，注入常失败也不需要。
- Monitor → **Attach** 到该主进程（Electron 会自重启，Attach 比 Launch 省事）。

勾选的 API（API Filter）：
- `User32.dll` → `CreateWindowExW`、`DestroyWindow`、`SetParent`、`ShowWindow`、`SetWindowPos`、`SetWindowLongPtrW`（抓 Legacy/子窗口创建、销毁、隐藏、被设 0×0）。
- 多屏（可选）：`ChangeDisplaySettingsExW`、`EnumDisplayMonitors`，与黑屏时间点对齐。
- 软渲染面（可选）：`Gdi32.dll` → `CreateDIBSection`、`CreateCompatibleDC`、`BitBlt`、`StretchDIBits`、`DeleteObject`。**若黑屏瞬间 `CreateDIBSection` 返回 NULL，即抓到软件输出面创建失败的实证。**

抓“谁销毁了它 + 何时”：
1. Legacy 窗口活着时先拿到其 HWND（Spy++ Finder 或 Inspect）。
2. 复现到黑屏。
3. 捕获列表按 `DestroyWindow` 过滤，找 **hWnd 参数 = 该 Legacy 句柄** 的那条；或按 `CreateWindowExW`、`lpClassName="Chrome_RenderWidgetHostHWND"` 找创建反推 HWND。
4. 点该调用 → 看 **Call Stack** 面板。Options 里把**符号路径指向你已有的 Electron 142 PDB**（+ MS 符号服务器），栈名即可解析 → **这就是“谁销毁了根视图”**，价值等同 WinDbg。
5. 顺带看销毁前是否有 `ShowWindow(SW_HIDE)` / `SetWindowPos` 设 0×0。

注意：
- API Monitor 注入 DLL，遇高度优化的 Electron + 沙箱**可能不稳/偶发崩进程**，在隔离环境跑。
- 只能看 Attach 的那个进程 —— **窗口 API 看主进程**；`Present`/DirectComposition 在 GPU 进程（沙箱内基本钩不到）。
- `BitBlt`/`Present` 高频 API 日志爆量，**只在复现前一刻开捕获**、过滤要窄。

### 方案二 · WinDbg 对销毁下断点（最稳，推荐至少做这个）
绕开注入与位数坑，你已有 PDB：
```windbg
* 命中时打印 hwnd(rcx) 并打栈、自动继续
bp user32!DestroyWindow ".printf \"DestroyWindow hwnd=%p\\n\", rcx; k; gc"
* 更底层、更难被绕过：
bp win32u!NtUserDestroyWindow ".printf \"NtUserDestroyWindow hwnd=%p\\n\", rcx; k; gc"
```
复现黑屏后，在日志里找 hwnd = Legacy 句柄 的那条，其 `k` 栈即根因路径。可与 §1 第 2 段的 `LegacyRenderWidgetHostHWND` 断点合用。

### 方案三 · WinEventHook 跨进程探针（最省事，确认“时刻”）
十几行小工具用 `SetWinEventHook(EVENT_OBJECT_CREATE / EVENT_OBJECT_DESTROY, ...)` 全局监听，稳定、跨进程拍到该窗口的创建/销毁时刻（但拿不到进程内栈）。用它确认黑屏与销毁是否同刻，再用方案二的 WinDbg 断点拿栈。

> 复用提醒：Legacy 窗口是**无障碍影子窗口**，需**全程挂 a11y 客户端或用 `--force-renderer-accessibility` 启动**才稳定存在；否则你可能在抓一个本就时有时无的窗口。真正像素面在 GPU 进程 DirectComposition，用 GPU 进程 `--vmodule=*direct_composition*=2,*viz*=2` 日志看。

---

## 2. 给插件团队的“不要做什么”清单（不需源码即可下结论）

`LegacyRenderWidgetHostHWND` 是**渲染器根视图**的窗口；它被销毁/重建本属正常生命周期，但被插件的后台行为推到“销毁后没能正常重建”的死角。所以建议插件团队**避免在被遮挡/隐藏期间制造任何会冲击可见性状态机和软渲染管线的负载**：

1. **不要在 webview 隐藏（`document.visibilityState==='hidden'` / `panel.visible===false`）时继续 `postMessage`。** 两个 webview 互相通信尤其要停——隐藏时只缓存，可见时一次性补发。
2. **不要在隐藏时跑 `setInterval` / `requestAnimationFrame` / 持续 append DOM。** 历史记录 webview 不要在后台无限增长 DOM/滚动。
3. **不要让两个 webview 在后台长期保持高频互通。** 这是“加了第二个 webview 才整窗黑”的直接嫌疑——后台跨 webview 消息在唤醒瞬间冲垮调度，正赶上根视图重建窗口期。
4. **不要对历史记录这类列表用 `retainContextWhenHidden:true` 且后台改 DOM。** 要么 `false`（隐藏即销毁、可见回灌），要么严格配合第 1/2 条门控。
5. **不要在“变可见/最大化/换屏”的瞬间触发大规模重排（reflow）。** 把首屏渲染拆帧、延后非关键 DOM 操作到 `requestIdleCallback`。
6. **慎用会压垮软件合成的 CSS：`backdrop-filter`、大面积 `opacity` 透明层、`will-change:transform`、`mix-blend-mode`、超大模糊/阴影。** 软渲染（`--disable-gpu-compositing`）下这些极易出问题；用 §3D 的 DevTools 删样式法验证。
7. **不要把 webview 尺寸瞬间设为 0×0 或快速反复切换可见性。** 容易触发“尺寸归零→销毁”路径。
8. **不要依赖“在隐藏 webview 里预渲染/预热”。** 隐藏态的渲染结果会被 evict，预热无效还增加唤醒负担。

> 一句话给插件团队：**webview 一旦不可见，就把它当“暂停”——停发消息、停定时器、停改 DOM；可见了再恢复。** 这能从源头避免根视图 HWND 在唤醒时卡在“销毁未重建”。

---

## 3. 能不能构造快速复现？—— 能。压缩“30 分钟”的三个杠杆

现场要等 ~30 分钟，是因为要等 **OS/DWM 回收被长期隐藏窗口的后台图形缓冲**。快速复现的思路：**用 Chromium 真正认账的 hidden 触发器（最小化、显示器/DPI 变化、锁屏/睡眠），叠加后台双 webview 通信洪泛，再用内存压力强制提前回收帧**，把 30 分钟压到秒级循环。

### 3.1 复现插件（最小工程）
两个 webview，后台互通 + 历史侧后台增长 DOM：
```ts
// extension.ts —— 注册两个 webview：history & chat，二者互发消息
const opts = { enableScripts: true, retainContextWhenHidden: true };
const history = vscode.window.createWebviewPanel('hist', '历史记录', vscode.ViewColumn.One, opts);
const chat    = vscode.window.createWebviewPanel('chat', '聊天',     vscode.ViewColumn.Two, opts);

// 关键“坏味道”：不判可见性，后台也猛发
let n = 0;
setInterval(() => {
  const payload = { i: n++, blob: 'x'.repeat(50 * 1024) };   // 50KB/条
  chat.webview.postMessage({ type: 'fromHistory', payload }); // 跨 webview 互通
  history.webview.postMessage({ type: 'fromChat', payload });
}, 8); // ~125 条/秒
```
```html
<!-- history webview：后台持续 append DOM + 滚动（最致命组合） -->
<script>
  window.addEventListener('message', e => {
    const d = document.createElement('div');
    d.textContent = JSON.stringify(e.data).slice(0, 200);
    document.body.appendChild(d);           // 不判 visibility，一直长
    window.scrollTo(0, document.body.scrollHeight);
  });
</script>
```

### 3.2 触发器（自动化，秒级循环）—— 用 AutoHotkey 跑几百次
```ahk
; minimize_restore.ahk —— 最小化/恢复循环（Chromium 立即 WasHidden/WasShown）
Loop, 500 {
    WinMinimize, ahk_exe code.exe
    Sleep, 1500            ; 后台停留：先 1.5s，复现不出再加大到 5s/15s/30s
    WinRestore,  ahk_exe code.exe
    WinActivate, ahk_exe code.exe
    Sleep, 1200
}
```
叠加更强的触发器（任选并行）：
- **显示器/DPI 变化（多屏现场的核心，强加速器）**：循环切换分辨率或主屏，或反复 `Win+P`（仅投影/扩展）/插拔扩展屏 → 触发 `WM_DISPLAYCHANGE`+`UpdateVisualProperties`+`LocalSurfaceId` churn。
- **跨屏拖动**：脚本把窗口在两块不同 DPI 屏之间来回 `WinMove`。
- **锁屏/睡眠唤醒**：`Win+L` 循环，或 `rundll32 powrprof.dll,SetSuspendState 0,1,0` 睡眠再唤醒。

### 3.3 强制“提前回收帧”（替代等 30 分钟）
被隐藏视图的 CompositorFrame 在**内存压力**下会被提前 evict（等价于 DWM 长期回收）。制造内存压力即可加速：
- 同机多开几个大网页/大文件、跑一个吃内存的小程序，把可用内存压到很低；隐藏期间 Chromium 更快 evict 隐藏帧。
- 或开很多 VSCode 标签/大文件让渲染器内存上涨。

### 3.4 边复现边监控（把判定自动化）
- **Spy++** 对 `Chrome_WidgetWin_1` 挂 `WM_PARENTNOTIFY` 日志：**一旦出现 Legacy 窗口的 `WM_DESTROY` 且随后没有 `WM_CREATE`** → 命中黑屏，时间戳即“最小触发条件”。
- 或简单脚本轮询：`Chrome_RenderWidgetHostHWND` 是否从窗口树消失（`FindWindowEx` 找不到该子窗口）= 黑屏命中。
- 命中后立刻保存 WinDbg 的 `LEGACY_DESTROY` 栈 + Spy++ 前序消息 = 完整证据链。

### 3.5 用 bisection 确认“是哪一项”
拿到稳定快速复现后，逐项关掉 §3.1 的坏味道（顺序 B5→B3/B4→B2→B1→B6，详见执行 Playbook），第一项让“Legacy 窗口不再被销毁”的，就是根因。

---

## 4. 一页纸交付（给团队）
- **现象本体**：黑屏 = 渲染器根视图 HWND `Chrome_RenderWidgetHostHWND` 被销毁未及时重建；恢复 = 其重建（拉伸窗口触发）。
- **定位方法（无需源码）**：Spy++ 抓销毁瞬间+消息序列 → WinDbg 抓销毁调用栈点名触发路径 → Perfetto 对齐时间线。
- **根因方向**：上游 `--disable-gpu-compositing` 软渲染 + 多屏/DPI/最小化的可见性变化 + 新版双 webview 后台高频互通/DOM 增长，三者叠加把根视图推到“销毁未重建”。
- **插件改法（不要做什么）**：见 §2 八条，核心是“webview 不可见就全面暂停”。
- **快速复现**：双 webview 洪泛插件 + 最小化/换屏自动循环 + 内存压力，Spy++ 监 `WM_PARENTNOTIFY` 自动判定（§3）。

## 来源
- [Chrome Legacy Window / `Chrome_RenderWidgetHostHWND`（chromium-dev）](https://groups.google.com/a/chromium.org/g/chromium-dev/c/UGX5RzjKYv4)
- [Intermediate D3D Window / `gpu::ChildWindowWin`（chromium-dev）](https://groups.google.com/a/chromium.org/g/chromium-dev/c/_RZfknIAXQ4)
- [Intermediate D3D Window painting problems（Chromium issue 41239884）](https://issues.chromium.org/issues/41239884/dependencies)
