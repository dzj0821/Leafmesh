# Android Release 签名

Leafmesh 的 Android Release 包使用持久的独立签名，后续版本必须沿用此密钥。RSA-4096、SHA256withRSA，证书有效期 10000 天；创建日期 2026-11-05。

公开证书为 `android/release-certificate.der`，SHA-256 指纹固定在 `android/release-certificate.sha256`。这些文件可以随源码保存。

私有材料位于 `%USERPROFILE%\.leafmesh\signing\android`：

- `leafmesh-release.p12`：包含签名私钥的 PKCS12 密钥库。
- `release.properties`：密钥库密码及别名。请按私密凭据保管，不发送到聊天或提交到版本库。

创建时生成随机密码，Windows 目录访问限制为当前用户与 SYSTEM。密码通过子进程环境变量传递给 keytool，不出现在命令参数或输出中。源码、APK、ZIP 均不含私钥或密码。

## 后续打包

```powershell
python tool/build_android.py --apk
python tool/verify_packages.py
```

Gradle 的 Release 构建会验证密钥库中的证书指纹；打包脚本再次用 `apksigner` 检查实际 APK 的签名。密钥缺失或指纹不一致时停止，不自动生成替代密钥。Android debug 构建仍使用独立的开发身份。

## 备份与迁移构建环境

请将整个私有签名目录备份到你控制的加密离线介质或密码保管工具中。密钥库与密码配置缺一不可；不要仅备份公开证书。丢失自管签名密钥将无法给已有安装正常发布更新。

换机器后恢复同一目录；也可将 `LEAFMESH_ANDROID_SIGNING_PROPERTIES` 指向恢复后的 `release.properties`。配置中的密钥库文件名按该配置文件所在目录解析，移动目录后不需要修改密码配置。

`python tool/android_signing.py --create` 会复用已存在的身份；项目已经固定证书后，如果密钥缺失，该命令会要求恢复原密钥。

## 从旧开发版切换

此 Release 证书与早期 Android Debug 证书不同。已安装早期开发版时，请先备份同步文件和未提交草稿，再卸载旧版、安装 Release 版并重新配对。卸载会清除应用内部数据。之后沿用此 Release 证书且版本号递增的更新可覆盖安装。

首次采用此 Release 签名的包为 `0.1.0+2`；之后构建保持同一证书并递增 versionCode。

参考：[Android 应用签名](https://developer.android.com/studio/publish/app-signing)、[Flutter Android 发布配置](https://docs.flutter.dev/deployment/android#sign-the-app)。
