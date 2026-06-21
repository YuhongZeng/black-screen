# Webview 黑屏定位与修复 Playbook（隔离环境执行版）

> 配套文档：`G:\crash\黑屏问题分析与修复.md`（背景、证据、根因推导）。本文件是“在隔离环境怎么做”的执行版。
> 编写日期：2026-06-18

## Context（为什么做这件事）
内部 VSCode（CodeArts Agent，Chromium 142，启动带 **上游 VSCode 自带的 `--disable-gpu-compositing`**，纯软件合成）+ 新版自研 AI 插件出现黑屏。
新版插件比旧版多了一个 webview：现在是 **两个 webview —— 历史记录 + 聊天**，且“生成代码时两个 webview 会互相通信”。**正是加了第二个 webview 之后才出现整窗黑屏**；同时存在 **单个 webview 黑屏（改变该 webview 大小即恢复）**。
场景：**多屏 + 笔记本**（更改在笔记本屏上浮现）。
约束：① `--disable-gpu-compositing` 是上游为别的 bug 加的，**不能简单去掉**；② **尺寸抖动方案被否决**（会让动态界面样式产生可见震颤）；③ 本机没有插件/IDE 源码，以下为隔离环境里执行的建议。

目标：**先定位“插件到底做了什么触发它”，再用不抖动的方式修复。**

---

## 1. 心智模型（决定排查方向）
- 两种黑屏是**同一根因的不同层级**：
  - **webview 级黑屏**：被遮挡/后台时该 webview（child `RenderWidgetHostView`/嵌入式 surface）的 `LocalSurfaceId` 对应 CompositorFrame 被 evict；切回前台走 `WasShown` 时**没重新提交新帧/没重新嵌入子表面** → 这一块黑。改变该 webview 大小 → 内部 `ResizeObserver`→新尺寸→新 `LocalSurfaceId`→重嵌入→恢复。
  - **整窗黑屏**：父（workbench）聚合表面唤醒时也没对齐 → 整窗黑，`WM_SIZE` 才恢复。
- **为何“加了第二个会互通的 webview”才爆发**：两个 child surface + 高频互通改变了 view/surface 树拓扑与唤醒时序，使“遮挡→唤醒”的软件合成路径更易卡住。**这是最需被实验证实/证伪的核心假设。**
- **多屏笔记本相关性**：跨屏/混合 DPI/集显独显切换触发 `WM_DISPLAYCHANGE` + `UpdateVisualProperties`，进一步打乱 `LocalSurfaceId` 同步；多屏下 D3D 设备丢失概率更高。
- 已知：进程不崩、线程健康；`SetVisible (Did not end)`；GDI 未耗尽；纯 IPC/DOM 洪泛 mock 复现不出 → **必须叠加“后台/遮挡 + 软件合成 + 双互通 webview”**才触发。

---

## 2. 稳定复现（先决条件）
环境贴近现场：**多屏 + 笔记本 + 同版 IDE（带 `--disable-gpu-compositing`）+ `code --status` 确认 `Software Rendering: Yes`**。

配方：
1. 打开装新版插件的 IDE，历史 + 聊天两个 webview 都激活。
2. 让 AI 在**后台持续通信**（生成代码/流式 token），两 webview 被遮挡时仍互发消息。
3. 遮挡 webview / 最小化 / 切别的 Tab / 切别的屏，挂几分钟到 ~30 分钟（先短后长）。
4. 切回前台 / 切回笔记本屏 → 观察 webview 黑或整窗黑。

> 复现不出就逐项加压：拉长后台时间、提高通信频率、跨屏切换、最小化恢复叠加。记录“最小触发条件”作为 bisection 基准。

---

## 3. 定位“插件做了什么”（先诊断再改）

### 3A. DevTools 看“黑时帧有没有产出”
`Developer: Open Webview Developer Tools`（分别开历史/聊天）：
- **Console**：hidden 期间是否仍打印（有 timer/rAF/DOM 在跑）。
- **Rendering → Paint flashing / Layer borders**：黑屏时完全无 paint 闪烁 = 合成帧没产出；一动 webview 大小立刻闪 → 实锤 LocalSurfaceId/嵌入问题。
- **Performance 录制**唤醒瞬间：主线程是否被超长 task 占满、合成线程是否停在 commit/WaitForSyncToken。

### 3B. 底层日志（不动 `--disable-gpu-compositing`，只加日志）
```
--enable-logging --v=1 --vmodule=*viz*=2,*cc*=2,*surface*=2,*software_output_device*=2,*hwnd_message_handler*=2 --log-file="D:\ide_surface.log"
```
关注：`LocalSurfaceId`、`EvictDelegatedFrame`/`EvictSurface`、`WasShown`/`WasHidden`、`SetVisible`、`SoftwareOutputDevice`。对黑屏时间点，看子 surface 被 evict 后是否没重新 allocate/embed。

### 3C. Perfetto 抓唤醒瞬间
```
--trace-startup=ui,cc,viz,gpu,latency --trace-startup-file="D:\trace.pftrace" --trace-startup-format=proto --trace-startup-duration=0 --trace-startup-record-mode=record-continuously
```
拖进 `ui.perfetto.dev`，看还原瞬间 `LayerTreeHostImpl::SetVisible`/`Compositor::SetVisible` 是否“有始无终”，子 webview frame sink 是否停摆。

### 3D. 决定性手段——插件行为 bisection（找出根因）
每次只改一项，按 §2 复现，记录黑屏是否消失。第一个让黑屏消失的开关即指向根因：

| 实验 | 改动 | 黑屏消失 → 结论 |
|---|---|---|
| B5 | 临时只注册一个 webview / 去掉两者通信 | 证实/证伪“双互通 webview 是触发条件” |
| B3 | 隐藏期间停止两 webview 互发 postMessage（`if(panel.visible)` 门控+缓冲） | 后台高频 IPC 冲垮调度器 |
| B4 | 隐藏期间停掉 webview 内所有 setInterval/rAF/DOM 追加（听 `visibilitychange`） | 后台前端自驱动渲染/DOM 增长 |
| B2 | 历史 webview 关 `retainContextWhenHidden`、聊天保持（再反过来） | 定位到**具体哪个 webview**是元凶 |
| B1 | 两个 webview 都 `retainContextWhenHidden:false` | 根因是“隐藏态保留 DOM/旧表面” |
| B6 | DevTools 删 `backdrop-filter`/`will-change:transform`/`mix-blend-mode`/大面积 `opacity` 层 | 该 CSS 触发软渲染管线缺陷 |

> 建议顺序 **B5 → B3/B4 → B2 → B1 → B6**：先证因子、再缩小到具体 webview、最后定配置/CSS。bisection 的产出 = “插件做了什么”的答案。

### 3E.（可选）WinDbg 精确断点（你已有 Electron 142 PDB）
对 `RenderWidgetHostImpl::WasShown`/`WasHidden`、`Compositor::SetVisible` 下断点，黑屏时看哪个 child 的 `WasShown` 没把可见性传下去、`LocalSurfaceId` 是否更新。用于 3D 定位到具体 webview 后做最终确认。

---

## 4. 修复（不用尺寸抖动，治因 → 兜底）

### 🥇 F1（首选·治因·无视觉副作用）：隐藏态彻底静默，可见时补发
B3/B4 命中即落地。被遮挡的 webview 不再产生后台渲染/通信压力，从源头避免唤醒卡死，**不需要任何 repaint hack**。

**扩展宿主侧**——按可见性门控 + 缓冲，可见时批量补发一次：
```ts
class VisibilityGatedPanel {
  private buffer: any[] = [];
  private visible: boolean;
  constructor(private panel: vscode.WebviewPanel) {  // WebviewView 同理
    this.visible = panel.visible;
    panel.onDidChangeViewState(e => {
      this.visible = e.webviewPanel.visible;
      if (this.visible && this.buffer.length) {
        const batch = this.buffer.splice(0);          // 合并补发，避免唤醒瞬间洪泛
        this.panel.webview.postMessage({ type: 'batch', data: batch });
      }
    });
  }
  post(msg: any) {
    if (this.visible) this.panel.webview.postMessage(msg);
    else this.buffer.push(msg);                        // 隐藏只缓存
  }
}
```
把 AI 流式 token、两个 webview 互通的消息全部走 `post()`。

**webview 前端侧**——hidden 时暂停所有自驱动：
```js
let timers = [], rafId = null, paused = false;
function pauseAll() { paused = true; timers.forEach(clearInterval); timers = []; if (rafId) cancelAnimationFrame(rafId); }
function resumeAll() { paused = false; /* 重建必要的 timer/rAF */ }
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') pauseAll();
  else resumeAll();
});
// 收到 host 的消息时：隐藏态不要 append DOM，先入队，resume 时再渲染
```
历史记录 webview 尤其不要在隐藏时继续 append DOM。

### 🥈 F2（针对元凶 webview）：只对它关 `retainContextWhenHidden`
若 B1/B2 指向某个 webview（大概率是历史记录），只对它：
```ts
vscode.window.createWebviewPanel('history', '历史记录', col, {
  enableScripts: true,
  retainContextWhenHidden: false,   // 隐藏即销毁，可见时由宿主回灌状态重渲染
});
```
- 切回时由扩展宿主把状态 `postMessage` 回灌；“历史记录”这类只读列表代价很小。
- 通信频繁、需常驻的聊天 webview 可保持 true，配合 F1 门控。

### 🥉 F3（兜底·不改几何·无震颤，替代被否决的尺寸抖动）
仅 F1+F2 仍偶发残留时用。唤醒时强制重提一帧，**不动布局/几何**：

1. **首选：Electron 壳层 `webContents.invalidate()`**（内部 IDE 构建若能改壳层）——“安排一次整窗重绘”，是 resize 的无尺寸变更等价物，不 reflow、不移动像素：
```js
const { powerMonitor } = require('electron');
function repaint(win){ if(win && !win.isDestroyed()) win.webContents.invalidate(); }
mainWindow.on('restore', () => repaint(mainWindow));
mainWindow.on('focus',   () => repaint(mainWindow));
powerMonitor.on('resume', () => repaint(mainWindow));
powerMonitor.on('unlock-screen', () => repaint(mainWindow));
// 多屏：监听显示器变化后也重绘
require('electron').screen.on('display-metrics-changed', () => repaint(mainWindow));
```
2. **退路：webview 内不改几何的重绘**（择一验证对你们 CSS 真正无副作用）：
```js
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  const el = document.documentElement;
  el.style.opacity = '0.9999';                 // 合成层属性，不 reflow、肉眼不可见
  requestAnimationFrame(() => { el.style.opacity = '1'; });
  // 或：el.style.filter='opacity(1)' → 下一帧 'none'
});
```
- **明确不要** `transform: translateZ(1px)` / 改 width/height —— 移动像素或触发布局，正是震颤来源。

> F3 是兜底；能用 F1/F2 治因就尽量不依赖它。

### 关于上游 `--disable-gpu-compositing`
- 由上游为别的 bug 加，**不要在产品默认配置里去掉**。
- 但**可在隔离环境做一次对照实验**：临时 `--use-gl=angle --use-angle=swiftshader`（保留 GPU 合成管线、底层走软件 GL），看黑屏是否消失。**仅用于确认根因是否落在“软件合成器唤醒路径”**，不作最终交付（除非验证后与上游确认那个 bug 已不复现）。

---

## 5. 验证（端到端）
1. 基准：未改动版本按 §2 能稳定黑屏。
2. 应用 F1（+ 必要时 F2），按 §2 同配方 + 多屏切换 + 笔记本屏浮现 + 最小化恢复，反复跑足够多次，**webview 黑与整窗黑均不再出现**。
3. 复测动态界面样式**无可见震颤**（确认没用尺寸抖动）。
4. 用 §3B 日志 / §3C Perfetto 复测：唤醒时 `SetVisible` 正常结束、子 surface 正常重嵌、无 `Evict…` 后悬空。
5. 回归：长时间后台（≥30min）、跨屏、DPI 不同两屏间拖动。

## 6. 交付物
- “最小复现条件 + bisection 结论（哪个 webview / 哪种后台行为是根因）”记录。
- 代码改动：F1 可见性门控（宿主 + 两个 webview 前端）；命中则 F2 的 `retainContextWhenHidden` 调整；需则 F3 无几何重绘兜底。
