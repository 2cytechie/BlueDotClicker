# 蓝点器 (BlueDot Clicker)

Windows 自动化工具：基于蓝图工作流的连点器。

## 节点手册

### 执行流接入/接出与数据端口

| 节点 | 类型 key | 分类 | 执行流输入 | 执行流输出 | 数据输入 | 数据输出 |
|---|---|---|---|---|---|---|
| 开始 | `start` | 脚本 | 无 | `out` | 无 | 无 |
| 鼠标操作 | `mouse` | 交互 | `in` | `out` | `x` X坐标、`y` Y坐标 | 无 |
| 键盘操作 | `keyboard` | 交互 | `in` | `out` | 无 | 无 |
| 执行录制 | `playRecording` | 交互 | `in` | `out` | 无 | 无 |
| 截图 | `screenshot` | 媒体 | `in` | `out` | 无 | `imageOut` 图像 |
| 文字识别 | `ocr` | 媒体 | `in` | `out` | `image` 输入图像(可空)、`resultVar` 识别文本(变量名,可空) | `text` 文本、`found` 是否命中、`x` 坐标X、`y` 坐标Y |
| 图像识别 | `imageMatch` | 媒体 | `in` | `out` | `image` 输入图像(可空) | `found` 是否命中、`x` 坐标X、`y` 坐标Y、`score` 相似度 |
| 条件判断 | `condition` | 逻辑 | `in` | `true` 真、`false` 假 | `left` 左值、`right` 右值 | 无 |
| 循环 | `loop` | 逻辑 | `enter` 进入、`continue` 体返回 | `body` 循环体、`done` 完成 | 无 | 无 |
| 延时 | `delay` | 逻辑 | `in` | `out` | 无 | 无 |
| 设置变量 | `setVar` | 数据 | `in` | `out` | `value` 值 | `valueOut` 值 |
| 获取变量 | `getVar` | 数据 | `in` | `out` | 无 | `value` 值 |
| 数据保存 | `saveData` | 数据 | `in` | `out` | `text` 文本、`image` 图像 | `textOut` 文本、`imageOut` 图像 |

> 未知/已移除类型使用占位定义 `kUnknownNodeDef`：无端口、无参数，执行到该节点会中断执行流。

### 参数明细（键=默认值）

| 节点 | 参数 |
|---|---|
| 开始 | `count`=1（执行次数，0=一直执行，F10 停止） |
| 鼠标操作 | `action`=click（click/doubleClick/swipe/longPress/scroll/move）、`button`=left、`x`=100、`y`=100、`mode`=coords、`startX`=400、`startY`=300、`endX`=600、`endY`=300、`angle`=0、`distance`=200、`durationMs`=300、`holdMs`=800、`dx`=0、`dy`=120 |
| 键盘操作 | `action`=tap（tap 按键 / combo 组合键）、`vkCode`=0、`comboKeys`=[]、`durationMs`=60 |
| 执行录制 | `recordingId`='' |
| 截图 | `useRegion`=false、`rx`=0、`ry`=0、`rw`=400、`rh`=300 |
| 文字识别 | `useRegion`=false、`rx`=0、`ry`=0、`rw`=400、`rh`=300、`resultVar`='ocrText'（识别文本存入的变量名，留空不存） |
| 图像识别 | `templatePath`=''、`threshold`=0.8、`useRegion`=false、`rx`=0、`ry`=0、`rw`=400、`rh`=300 |
| 条件判断 | `op`=`==`（==/!=/</>/<=/>=/contains）、`leftVar`=''、`leftConst`=''、`rightVar`=''、`rightConst`='' |
| 循环 | `count`=3（0=无限） |
| 延时 | `ms`=500 |
| 设置变量 | `name`='myVar'、`const`=''（数字/字符串/布尔自动推断） |
| 获取变量 | `name`='' |
| 数据保存 | `fileName`='result'（不含扩展名，存到「文档\bluedot_clicker\save\」） |

## 开发

```powershell
flutter pub get
flutter run -d windows
flutter analyze
flutter test
```
