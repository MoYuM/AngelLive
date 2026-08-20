# CloudKit schema

容器:`iCloud.com.moyum.angellive`(三端共用,tvOS 顶层货架扩展也读同一个容器)。

`schema.ckdb` 是从代码里的记录类型/字段/查询反推出来的完整 schema,内容与这些源文件一一对应:

| 记录类型 | 定义处 |
|---|---|
| `favorite_streamers` | `FavoriteService.swift` / `Sync/FavoriteSyncEngine.swift` |
| `stream_bookmarks` | `StreamBookmarkService.swift` |
| `cookie_sessions` | `PlatformCredentialSyncService.swift` |
| `plugin_sources` | `PluginSourceSyncService.swift` |

## 为什么要手工建,不能靠自动创建

CloudKit 只在 **Development** 环境会因为首次写入自动建记录类型,**Production 不会**;
而 TestFlight / App Store 包打的就是 Production(可在导出产物里看到
`com.apple.developer.icloud-container-environment = Production`)。

更关键的是:**自动创建只建字段,不建索引**。代码里这三处会发 `CKQuery`,
没有对应的 queryable 索引就直接查询失败:

- `favorite_streamers`:按 `room_id` 精确查(`FavoriteService.searchRecord(roomId:)`),
  以及 `NSPredicate(value: true)` 全量查 —— 后者要求 `___recordID` 可查询
- `stream_bookmarks`:按 `bookmark_id` 精确查 + 全量查
- `cookie_sessions`:全量查

`plugin_sources` 是固定 recordName 直接 fetch(`user_plugin_sources`),不走查询,
索引只是顺带留着。

所有数据都在**私有数据库**(代码里没有任何 `publicCloudDatabase` 用点),
所以权限给的是 `GRANT READ TO "_creator"`。

## 怎么导入

需要 CloudKit Console 生成的**管理令牌**(Manage Tokens → 新建),令牌自己保管:

```sh
xcrun cktool save-token --type management     # 交互式粘贴令牌

# 先验证语法,别直接导
xcrun cktool validate-schema \
  --team-id 57WZ39XQY3 \
  --container-id iCloud.com.moyum.angellive \
  --environment development \
  --file cloudkit/schema.ckdb

# 两个环境都要导:开发环境自己调试用,生产环境 TestFlight/正式包才用得上
xcrun cktool import-schema --team-id 57WZ39XQY3 \
  --container-id iCloud.com.moyum.angellive --environment development \
  --file cloudkit/schema.ckdb
xcrun cktool import-schema --team-id 57WZ39XQY3 \
  --container-id iCloud.com.moyum.angellive --environment production \
  --file cloudkit/schema.ckdb
```

也可以在 CloudKit Console 网页里手工建完 Development,再点 Deploy Schema to Production。

## 改了代码记得同步

新增记录类型/字段,或者新增一处 `CKQuery`(要配 queryable 索引)时,
这个文件要跟着改并重新导入两个环境,否则线上会报「记录类型/字段不存在」或查询失败。
