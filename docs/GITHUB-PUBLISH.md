# 上传与发布

源码可以从当前项目提交，继续在本机编译正式版。`.local/`、日志、账号备份、签名、构建缓存和安装包已被忽略；不要通过网页拖入整个原始目录。

上传前检查：

```powershell
python tool/check_public_files.py
# git add 后检查暂存内容
python tool/check_public_files.py --staged
```

本机编译的 APK、EXE 单独上传 **Releases**，不要加入源码历史。同版本维护包需要用户手动安装；推送新版本更新时递增版本和构建号。

## 远程更新配置

更新字段中的 `version` 和 `build` 应与安装包一致；`downloadUrl` 填纯 HTTPS 地址，不能写成 Markdown 链接。

若同一个配置地址还服务 **0.3.47**，保持 `schema: 1`，`clouds` 只填写旧版认识的 8 项：`baidu`、`quark`、`uc`、`pan123`、`c139`、`tianyi`、`xunlei`、`lanzou`。新网盘字段会让旧版拒绝整份配置；省略这些字段时，新版中的新网盘仍默认开启。`config/control.example.json` 包含新网盘字段，仅供新版参考。

每次发布递增 `revision`，公告变更时更新 `id`，兼容旧版缓存判断。主配置访问失败后，应用才检查 GitHub 备用更新。

## 可选：GitHub Actions 打包

仓库配置 `release` Environment，在 Secrets 中设置：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Secrets 中另设 `ASTERLINK_CONTROL_URL`、`UMENG_APPKEY`；Variables 中设置 `ASTERLINK_GITHUB_REPO`、`ASTERLINK_APPLICATION_ID` 和 `UMENG_CHANNEL`。正式版包名为 `com.asterlink.app`；正式配置不完整时工作流会停止，本机参数不会自动上传。

修改 `pubspec.yaml` 后运行 `dart tool/sync_version.dart --write`。推送与完整版本一致的新标签，或在 Actions → Build signed release → Run workflow 选择分支，均可生成正式签名安装包。完成后下载 `release-android`、`release-windows` 附件；工作流不会自动创建或发布 Release。需要发布时，再单独上传附件并发布版本。不要覆盖已发布标签。只有正式 Release 会被备用更新识别。
