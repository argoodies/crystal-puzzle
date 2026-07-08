# DeskFeel（Godot 版）

拟物数字桌板的 **Godot 4** 重制：真 3D 紫绒布桌板 + 可拖拽的圆柱厚片令牌。
同一套 GDScript 代码同时出 **iOS** 与 **Web（GitHub Pages）**。

- 引擎：Godot 4.6.3，语言 GDScript
- 渲染：`gl_compatibility`（OpenGL / WebGL2），Web 与移动端都稳
- 场景在 `main.gd` 里程序化生成（相机 / 光照 / 桌板 / 令牌 / 拖拽交互）

## 管线

| 目标 | Workflow | 说明 |
| --- | --- | --- |
| Web → GitHub Pages | `.github/workflows/web-pages.yml` | 无线程导出（适配 Pages 无 COOP/COEP 头），push main 或手动触发自动部署 |
| iOS → TestFlight | *（待接入）* | macOS runner + Godot iOS 导出模板 + 签名，复用 ASC 密钥 |

## 本地

```bash
# 用 Godot 4.6.3 打开工程
godot --editor .
# 无头导出 Web（需先装 4.6.3 的 Web 导出模板）
godot --headless --export-release "Web" build/web/index.html
```
