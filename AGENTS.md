# Shiying 项目约定

## 构建副本管理（用户明确要求，参照 Qiming）

- 仅保留日常使用版 `/Applications/Shiying.app` 和 Xcode 默认 DerivedData 中的一个 `Shiying Dev.app`。每次构建、测试、更新后清理旧应用副本，不累积可被 Spotlight 搜索到的应用。
- Debug 使用 `./Scripts/build.sh Debug` 或 Xcode 的 Shiying / My Mac，两者共用默认 DerivedData。不要额外指定开发版输出目录。
- Release 使用 `./Scripts/build.sh Release`：在 `.noindex` 临时目录构建和校验，正常退出旧版后替换 `/Applications/Shiying.app`，清除临时 `.app`。不强制覆盖运行中的应用。
- 每次更新后从同一份已安装正式版刷新 `dist/Latest/Shiying.zip` 与 `Shiying.dmg`，报告包体大小。压缩包中仅有同一份正式版，不在项目内另留展开的 Release 应用。
- 测试使用 `./Scripts/test.sh`，产物放 `.noindex` 目录并自动清理测试应用。
- 如必须使用临时构建目录，结束后运行 `python3 Scripts/manage_build_apps.py cleanup`，核对只剩以上两份；仅清理已识别的构建副本，不删除源码、设计资源、历史、密钥或验收记录。
- Dev 的 bundle ID、偏好、历史和密钥与正式版隔离，Dev 不默认注册登录启动。
