# 常见故障核对

| 症状 | 优先核对 |
|---|---|
| Unknown argument / command | 当前 Qt/CMake 版本、组件、命令与参数拼写 |
| QML module/type not found | URI、输出目录、import 路径、qmldir、插件与注册 |
| 单例按普通组件加载 | pragma 与单例源文件属性、设置顺序 |
| qrc 文件找不到 | 资源是否打包、前缀、别名和调用方 URL |
| moc/type registration 缺失 | AUTOMOC、目标源文件与头文件、注册生成步骤 |
| 静态模块测试加载失败 | 测试宿主链接和插件导入，而非只增加搜索路径 |
| 本机构建通过、包内失败 | 运行时依赖、插件、资源与部署结果 |
| 新 import 未生效 | 是否重新配置并刷新生成导入信息 |

- 不把合法的 RESOURCE_PREFIX 定制、qt6_* 命令或手工 AUTOMOC 判成必修缺陷。
- 不通过修改生成文件暂时消除错误，应修正生成它的源配置。
- 不为了通过模板检查迁移无关目标、提升版本或改资源布局。
