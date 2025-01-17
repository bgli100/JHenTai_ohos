# JHenTai for OpenHarmony

[JHenTai](https://github.com/jiangtian616/JHenTai) 的 OpenHarmony 移植版, 详见原库

# TODO

`sqlite3_flutter_libs` 上游暂未移植支持 ohos, 暂时应用设置无法保存生效

# 编译

Flutter SDK:
https://gitee.com/harmonycommando_flutter/flutter

```
flutter build hap --target-platform ohos-arm64 --release -t lib/src/main.dart
```