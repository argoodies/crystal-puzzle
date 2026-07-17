# 擦水晶 · 水晶磨き · Crystal Puzzle（Godot 版）

一款轻松解压的 3D 擦拭小游戏:一枚蒙尘的**水晶拼图**，喷水擦去灰尘，露出下面通透光滑、折射炫光的水晶。
同一套 GDScript 代码同时出 **iOS / Web（GitHub Pages）**。三语发行:繁/简中「擦水晶」、日「水晶磨き」、英「Crystal Puzzle」。

- 引擎：Godot 4.6.3，语言 GDScript
- 渲染：`gl_compatibility`（OpenGL / WebGL2），Web 与移动端都稳
- 场景全部在 `main.gd` 里程序化生成，无 `.tscn`
- 设计理念见 [`DESIGN.md`](DESIGN.md)

## 玩法

- **喷水擦拭**：长按拖动水晶表面，向接触处持续喷水冲刷，一点点擦掉灰尘。
- **交付**：把整颗擦到 100% 无尘，底部中央出现圆圈；点它交付（对勾 + 奖励音），水晶被收进成就宝瓶，随后右上角出现**画廊**与**播放**按钮。
- **播放**：随机换一个未清洗的水晶重新开始。
- **成就宝瓶（画廊按钮）**：交付过的水晶收进一个装满水的水晶宝瓶，在水里漂浮、碰撞；拖拽绕竖直轴旋转、缩放、点击瓶身产生冲击。凑够 30 颗触发"全视之眼"完成仪式（瓶中爆发光芒 + 随机减 15），瓶子最多 30 颗（先进先出）。
- **旋转/缩放**：拖背景旋转、双指缩放；左上角 ☀️/🌙 切换日夜。
- 每次启动都是一个新的随机未完成水晶；持久化日/夜、挑战关与**成就水晶队列**。

## 技术要点

- **UV 遮罩擦拭**：1024² L8 遮罩，擦拭画进遮罩，shader 按 `UV` 采样，覆盖无上限、边缘细腻。
- **双趟材质（next_pass）**：灰尘层（不透明、写深度）+ 水晶层（透明、双面、不写深度），各自按遮罩 `discard`，实现"灰尘实、水晶透"。
- **屏幕空间体积光（丁达尔/神光）**：`hint_screen_texture` 径向模糊后处理，纯黑背景上把水晶高光拉成光柱。
- **伪影棚环境反光**：黑底无天空可反射，shader 里程序化生成反射亮斑 + 边缘辉光 + 泛光。

## 管线

| 目标 | Workflow | 说明 |
| --- | --- | --- |
| Web → GitHub Pages | `.github/workflows/web-pages.yml` | 无线程导出（适配 Pages 无 COOP/COEP 头），跨仓库推到公开的 `argoodies/crystal-puzzle-web` 托管 |
| iOS → TestFlight | `.github/workflows/ios-testflight.yml` | macOS runner + Godot iOS 导出模板 + 自动签名归档 + `altool` 上传，`build = 1000 + run_number`，App `io.github.argoodies.crystal` |

## 本地

```bash
# 用 Godot 4.6.3 打开工程
godot --editor .
# 无头导出 Web（需先装 4.6.3 的 Web 导出模板）
godot --headless --export-release "Web" build/web/index.html
```
