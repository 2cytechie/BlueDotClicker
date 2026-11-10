# 蓝点器 (BlueDot Clicker)

Windows 自动化工具：基于蓝图工作流的连点器。

## 节点手册

### 执行流接入/接出与数据端口

| 节点 | 类型 key | 分类 | 执行流输入 | 执行流输出 | 数据输入 | 数据输出 |
|---|---|---|---|---|---|---|
| 开始 | `start` | 脚本 | 无 | `out` | 无 | 无 |
| 鼠标操作 | `mouse` | 交互 | `in` | `out` | `x`/`y`（拖拽时复用为起点）、`endX`/`endY` | 无 |
| 键盘操作 | `keyboard` | 交互 | `in` | `out` | 无 | 无 |
| 执行录制 | `playRecording` | 交互 | `in` | `out` | 无 | `success` 成功 |
| 截图 | `screenshot` | 媒体 | `in` | `out` | `left`/`top`/`right`/`bottom` 区域角点 | `imageOut` 图像 |
| 文字识别 | `ocr` | 媒体 | `in` | `out` | `image` 输入图像(可空)、`targetText` 目标文本(可空) | `text` 文本、`found` 是否命中、`x` 坐标X、`y` 坐标Y |
| 图像识别 | `imageMatch` | 媒体 | `in` | `out` | `image` 输入图像(可空) | `found` 是否命中、`x` 坐标X、`y` 坐标Y、`score` 相似度 |
| 条件判断 | `condition` | 逻辑 | `in` | `true` 真、`false` 假 | `left` 左值、`right` 右值 | 无 |
| 循环 | `loop` | 逻辑 | `in` 进入 | `true` 真（循环体，自动重复）、`false` 假（结束循环） | `left` 左值、`right` 右值 | 无 |
| 延时 | `delay` | 逻辑 | `in` | `out` | 无 | 无 |
| 设置变量 | `setVar` | 数据 | `in` | `out` | `value` 值 | `valueOut` 值 |
| 获取变量 | `getVar` | 数据 | 无（纯数据节点） | 无 | 无 | `value` 值 |
| 加法 | `add` | 数据 | `in` | `out` | `a`、`b` | `result` 结果 |
| 减法 | `subtract` | 数据 | `in` | `out` | `a`、`b` | `result` 结果 |
| 数据保存 | `saveData` | 数据 | `in` | `out` | `text` 文本、`image` 图像 | `textOut` 文本、`imageOut` 图像 |

> 未知/已移除类型使用占位定义 `kUnknownNodeDef`：无端口、无参数，执行到该节点会中断执行流。

### 参数明细（键=默认值）

| 节点 | 参数 |
|---|---|
| 开始 | `count`=1（执行次数，0=一直执行，F10 停止） |
| 鼠标操作 | `action`=click（click/doubleClick/swipe/longPress/scroll/move）、`button`=left、`x`=100、`y`=100（拖拽时复用为起点）、`mode`=coords、`endX`=600、`endY`=300、`angle`=0、`distance`=200、`durationMs`=300、`moveDurationMs`=0、`holdMs`=800、`dx`=0、`dy`=120 |
| 键盘操作 | `action`=tap（tap 按键 / combo 组合键）、`vkCode`=0、`comboKeys`=[]、`durationMs`=60 |
| 执行录制 | `recordingId`='' |
| 截图 | `useRegion`=false、`left`=0、`top`=0、`right`=400、`bottom`=300 |
| 文字识别 | `useRegion`=false、`left`=0、`top`=0、`right`=400、`bottom`=300、`targetText`=''（留空 = 任意文本模式） |
| 图像识别 | `templatePath`=''、`threshold`=0.8、`useRegion`=false、`left`=0、`top`=0、`right`=400、`bottom`=300 |
| 条件判断 | `op`=`==`（==/!=/</>/<=/>=/contains/notContains）、`leftConst`=''、`rightConst`='' |
| 循环 | `op`=`==`、`leftConst`=''、`rightConst`=''、`maxIterations`=0（0=不限制） |
| 延时 | `ms`=500 |
| 设置变量 | `name`='myVar'、`const`=''（数字/字符串/布尔自动推断） |
| 获取变量 | `name`='' |
| 加法/减法 | `a`=0、`b`=0 |
| 数据保存 | `fileName`='result'（不含扩展名，存到「文档\bluedot_clicker\save\」） |

## 开发

### OCR 构建依赖（OpenCV）

文字识别使用 [pp_ocr](https://pub.dev/packages/pp_ocr)（PaddleOCR PP-OCRv6 + ONNX Runtime），
其 Windows 原生库需要 OpenCV。首次构建前执行一次：

```powershell
powershell -ExecutionPolicy Bypass -File tool/setup_opencv.ps1
```

也可自行安装 OpenCV 4.x 预编译包，并设置环境变量 `OpenCV_DIR` 指向其 `build` 目录。
PP-OCRv6 模型已随 `assets/ocr/ppocr_v6/` 提供，无需额外下载。

```powershell
flutter pub get
flutter run -d windows
flutter analyze
flutter test
```

