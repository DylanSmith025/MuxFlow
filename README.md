# MuxFlow

一个原生 macOS SwiftUI / Xcode 项目，用于把 `.ts` 剧集批量无损封装为 `.mkv`，并批量整理轨道语言、名称、默认轨、强制显示、启用状态和保留状态。

## 当前主线

主项目在：

```text
MuxFlow/MuxFlow.xcodeproj
```

直接用 Xcode 打开这个 `.xcodeproj`，选择 `MuxFlow` scheme 和 `My Mac`，点击 Run 即可开发调试。

## 功能

- 拖拽 `.ts` 文件或文件夹，递归扫描剧集。
- 使用内置 `mkvmerge` 识别轨道并无损封装。
- 三栏原生界面：设置与预设、剧集列表、轨道检查器。
- 每条轨道可设置是否保留、语言、名称、默认轨、强制显示、启用状态。
- 支持“应用到所有匹配轨道”，匹配依据为轨道类型、同类型顺序和编码格式。
- 支持多个轨道预设，保存到 `UserDefaults`。
- 输出冲突时批量确认是否覆盖。

## 内置依赖

`mkvmerge` 和所需动态库已放在原生项目的 `Resources` 中，构建出的 App 不要求用户额外安装 MKVToolNix。

## 命令行验证

```bash
xcodebuild -project "MuxFlow/MuxFlow.xcodeproj" -scheme "MuxFlow" -configuration Debug -derivedDataPath "MuxFlow/DerivedData" build
```
