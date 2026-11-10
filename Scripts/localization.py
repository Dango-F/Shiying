#!/usr/bin/env python3
"""Compile-time bilingual string catalog; never a runtime dependency."""
from pathlib import Path
import json
rows = r'''panel.pin|Pin Window — keep open when clicking elsewhere|固定窗口（点击外部不收起）
panel.unpin|Unpin Window|取消固定窗口
panel.move|Drag the title area to move this window.|拖动标题区可移动窗口。
closeWindow|Close Window|关闭窗口
showStatusItem|Show Menu Bar Icon|显示菜单栏图标
version|Version|版本
development.note|Development build: separate history and settings. Automatic login is enabled by default for the installed release only.|开发版本使用独立历史与设置。仅安装的正式版默认启用登录启动。
status.loading|Opening encrypted history…|正在打开加密历史…
today|Today|今天
earlier|Earlier|更早
recentBuffer|Recent Buffer|最近缓冲
newItems|New fragments|有新片段
tagline|Fragments, kept.|片影，落定。
search|Search fragments…|搜索片段…
all|All|全部
saved|Saved|收藏
type|Type|类型
text|Text|文本
link|Links|链接
image|Images|图片
file|Files|文件
format.text|Text|文本
format.file|File|文件
format.folder|Folder|文件夹
format.mixed|Multiple Files|多文件
format.code|Code|代码
format.archive|Archive|压缩包
format.spreadsheet|Spreadsheet|表格
format.presentation|Presentation|演示文稿
format.itemCount|%ld items|%ld 项
format.fileType|%@ File|%@文件
time.secondsAgo|%ld sec. ago|%ld秒前
copy|Copy|复制
paste|Paste|粘贴
copyPlain|Copy as Plain Text|以纯文本复制
save|Save to Favorites|收藏
unsave|Remove from Favorites|取消收藏
details|Details|详情
settings|Settings…|设置…
filter|Filter history|筛选历史
history|History|历史
empty.results|No matching fragments|没有找到相关片段
empty.results.detail|Try another search or clear your filters.|试试其他关键词，或清除筛选。
empty.title|A place for every fragment.|每一片，都有去处。
empty.detail|Copy a piece of text, an image, or a file. Find it here when you need it.|复制文字、图片或文件，需要时在这里找回。
clearFilters|Clear Filters|清除筛选
start|Start Recording|开始记录
permissions|Permissions|权限
status.off|Recording is off|尚未开启记录
status.paused|Recording paused|已暂停记录
status.recording|Recording|正在记录
pause|Pause Recording|暂停记录
resume|Resume Recording|继续记录
pause15|Pause for 15 Minutes|暂停 15 分钟
pause60|Pause for 1 Hour|暂停 1 小时
pauseManual|Pause Until Resumed|暂停，直到手动恢复
buffer.count|Recent buffer: %ld / 5|最近缓冲：%ld / 5 条
history.count|%ld / 30 items|%ld / 30 条
saved.count|Saved: %ld / 30|收藏：%ld / 30 条
reveal|Show in Finder|在 Finder 中显示
viewFull|View Full Text|查看完整文本
preview.truncated|Preview shortened. View Full Text to read everything.|预览已截断，可查看完整文本。
notice.copied|Copied|已复制
notice.clipboardCleared|Current clipboard cleared|已清空当前剪贴板
error.storage|New fragments couldn’t be saved. Recording stopped. Retry in Permissions.|暂时无法保存新片段，已停止采集。请在权限页重试。
error.schema|Unsupported history version. Existing data has been preserved.|历史版本不兼容，原数据已保留。
error.keyAuthorization|Keychain authorization needed. History preserved; click Authorize Keychain in Settings.|需要钥匙串授权，历史已保留。请在设置中点击“授权钥匙串”。
authorizeKeychain|Authorize Keychain|授权钥匙串
keychain.authorization|Startup, wake and unlock never open password dialogs automatically. If access is needed, click Authorize Keychain and choose Always Allow in the system prompt to remember this signed app. No key is replaced and history is preserved.|启动、唤醒和解锁不会自动弹出密码窗口。如需授权，请点击“授权钥匙串”，在系统提示中选择“始终允许”以记住此签名版本。不会替换密钥或清空历史。
error.key|Encryption key unavailable. History preserved; recording stopped.|加密密钥暂不可用，已保留历史并停止采集。
error.authentication|Encrypted content failed verification. Recording stopped; data preserved.|加密内容校验失败，已停止采集并保留数据。
error.capacity|Not enough space. New fragment skipped; saved items preserved.|容量不足，已跳过新片段并保留收藏。
error.favoriteLimit|30 saved items already. Unsave one before saving another.|已收藏 30 条，请先取消一条收藏。
error.tooLarge|This fragment exceeds the size or pixel limit.|此片段超过保存大小或像素上限。
error.unreadable|Clipboard content couldn’t be read.|暂时无法读取剪贴板内容。
error.unsupported|This clipboard format isn’t supported.|暂不支持此剪贴板格式。
error.fileUnavailable|Original file unavailable|原文件不可用
error.write|Couldn’t copy this fragment. Please try again.|复制失败，请重试。
error.instance|Another Shiying instance is already using this history.|另一个拾影实例正在使用此历史库。
error.clipboard|Clipboard access required. Choose Always Allow in System Settings.|需要剪贴板访问权限，请在系统设置中选择始终允许。
error.hotkey|Shortcut unavailable. Choose another in General settings.|快捷键不可用，请在通用设置中更换。
error.login|Login item couldn’t be changed. Check System Settings.|无法修改登录项，请检查系统设置。
merge.title|Return to 30 items?|回到 30 条历史？
merge.detail|This also removes the %ld oldest unsaved items. Remaining favorites are kept.|此操作还会移除最旧的 %ld 条非收藏记录，其余收藏将保留。
delete|Delete|删除
cancel|Cancel|取消
close|Close|关闭
apply|Apply|应用
general|General|通用
privacy|Privacy|隐私
appearance|Appearance|外观
about|About|关于
general.subtitle|Small routines. A little less friction.|把常用的动作，放在顺手的位置。
history.subtitle|Keep what matters, with room for the next fragment.|留下常用片段，也为新内容留一点空间。
privacy.subtitle|Your fragments stay on this Mac.|片段只留在这台 Mac 上。
appearance.subtitle|Quiet surfaces. Clear fragments.|让片段清晰，让光影安静。
permissions.subtitle|Each permission has a separate purpose.|每一项权限，都有清楚的用途。
about.subtitle|Fragments, kept.|片影，落定。
launchAtLogin|Launch at Login|登录时启动
shortcut|Global Shortcut|全局快捷键
shortcut.record|Press shortcut…|按下快捷键…
language|Language|语言
system|System|跟随系统
poll|Capture Interval|采集间隔
general.note|Control+V opens the compact panel at the bottom right of the current screen. The menu bar icon is hidden by default. Copy a fragment, then press Command+V in the destination app. Capture observes the latest clipboard state; very rapid copies may be missed.|默认 Control+V 在当前屏幕右下角唤出紧凑面板，菜单栏图标默认隐藏。复制片段后，在目标应用按 Command+V 粘贴。采集观察剪贴板的最新状态，快速连续复制可能遗漏。
retention|Keep up to 30 items, including favorites. When all 30 are saved, keep 5 additional recent items. History survives restarts and doesn’t expire by age.|常规保留 30 条，包含收藏；全部收藏后，额外保留最近 5 条。重启后仍可使用，不按天数过期。
capacity|Encrypted Payload|加密载荷
databaseSize|Database File|数据库文件
limits|Text and rich text: 1 MiB combined. All formats and items: 32 MiB per capture. Images: 40 MP. Shared encrypted payload budget: 200 MiB. Database free pages and transaction space are additional.|文本与富文本合计上限 1 MiB；单次所有项目和格式合计 32 MiB；图片上限 4,000 万像素。共享加密载荷预算 200 MiB，数据库空闲页与事务空间另计。
clearUnsaved|Clear Unsaved History|清空非收藏历史
clearAll|Clear All History|清空全部历史
clearAll.title|Clear all history?|清空全部历史？
clearAll.detail|All fragments, including favorites, will be deleted. The current system clipboard is unaffected.|将删除全部片段，包含收藏。系统当前剪贴板不受影响。
clearUnsaved.detail|Unsaved history will be deleted. Your favorites and current system clipboard are kept.|将删除非收藏历史，收藏和当前系统剪贴板将保留。
delete.note|Deleting history does not clear the current clipboard. Deletion cannot remove system backups, APFS snapshots, or copies held by other apps.|删除历史不会清空当前剪贴板，也无法删除系统备份、APFS 快照或其他应用持有的副本。
clearClipboard|Clear Current Clipboard|清空当前剪贴板
clearClipboard.detail|Only the current system clipboard will be cleared. Saved history is unaffected.|仅清空系统当前剪贴板，不删除已保存的历史。
privacy.capture|Recording starts only after you enable it. Quit Shiying to stop recording; existing history remains encrypted on this Mac.|仅在你开启后持续记录剪贴板。退出拾影即可停止记录，已有历史仍加密保存在本机。
excludedApps|Excluded Applications|排除应用
editExcluded|Edit Bundle IDs…|编辑 Bundle ID…
addApplication|Add Application…|添加应用…
exclusion.note|The observed frontmost app is only a possible source. Exclusions cannot reliably identify every clipboard owner or secret.|前台应用只是可能来源，排除规则无法可靠识别所有剪贴板来源或敏感内容。
excluded.edit.detail|One application bundle ID per line. This list is editable, including suggested password managers.|每行一个应用的 Bundle ID。可以编辑建议排除的密码管理器名单。
privacy.encryption|Content, file URLs and previews use AES-GCM with a local, non-synchronizing Keychain key. The database still contains IDs, timestamps, types, sizes, favorite flags and keyed fingerprints. No accounts, uploads, analytics, or third-party runtime dependencies.|内容、文件 URL 与预览使用 AES-GCM 加密，密钥保存在本机非同步钥匙串。数据库仍包含 ID、时间、类型、大小、收藏标志及密钥指纹。无需账号，无上传、遥测和第三方运行时依赖。
privacy.sensitive|Concealed and transient clipboard markers are skipped. Unmarked passwords, tokens or identity documents can still be recorded. Locking clears decrypted previews and pauses capture; unlocking starts a new baseline.|跳过 concealed、transient 等敏感标记。未标记的密码、令牌或证件内容仍可能被记录。锁屏时清除解密预览并暂停采集，解锁后建立新基线。
openStorage|Open Storage Folder|打开存储文件夹
theme|Theme|应用外观
glass|Glass Style|玻璃方案
light|Light|浅色
dark|Dark|深色
adaptive|Adaptive|随境
ink|Clear Ink|清透墨字
textSize|Text Size|文字大小
preview.detail|Text stays sharp. Light stays quiet.|文字清楚，光影克制。
clarity|Background Clarity|背景清晰度
diffused|Diffused|柔和
clear|Clear|清晰
clarity.note|Adjusts a background-only diffusion layer over native Liquid Glass. Text stays sharp. Reduced Transparency uses an opaque surface.|调节原生 Liquid Glass 上的背景散焦层，文字始终保持清晰。降低透明度时使用不透明底色。
restoreAppearance|Restore Appearance Defaults|恢复默认外观
clipboardAccess|Clipboard Access|剪贴板访问
permission.allowed|Clipboard: Always Allow|剪贴板：始终允许
permission.required|Clipboard: access needs attention|剪贴板：需要处理访问权限
permission.detail|For continuous capture, choose Always Allow for Shiying in Privacy & Security → Paste from Other Apps. Ask and Deny stop background reads to avoid recurring prompts. Existing history stays usable.|持续记录需在隐私与安全性 → 从其他 App 粘贴中，将拾影设为始终允许。询问或拒绝时停止后台读取，避免反复弹窗；仍可使用已有历史。
requestClipboard|Request Clipboard Access|请求剪贴板访问
clipboardSettings|Open Clipboard Settings|打开剪贴板设置
login.enabled|Login item enabled|登录项已启用
login.approval|Approval needed in System Settings|需在系统设置中批准
login.disabled|Login item disabled|登录项未启用
loginSettings|Open Login Items Settings|打开登录项设置
retryStorage|Retry Storage and Permissions|重试存储与权限
about.story|“拾” gathers a fragment; “影” is an impression left behind. Copying keeps an impression. Pasting gives it another place to settle.|“拾”是收取片段，“影”是原物留下的映像。复制如拾影，粘贴则让影像在另一处落定，轻盈而含蓄。
about.technology|Native Swift 6 and AppKit. System SQLite, CryptoKit, Keychain and ImageIO. Single process. No web renderer or bundled fonts.|原生 Swift 6 与 AppKit。复用系统 SQLite、CryptoKit、Keychain 和 ImageIO。单进程，无网页渲染器或内嵌字体。
about.website|Development build. A release website and Developer ID notarization have not been configured.|开发版本，尚未配置发布官网、Developer ID 签名与公证。
diagnostics|Diagnostics|诊断
diagnostics.detail|Preview basic version and status information before copying. Clipboard content, search queries and file paths are excluded.|复制前预览版本与状态信息，不包含剪贴板正文、搜索词或文件路径。
copyDiagnostics|Preview Diagnostics…|预览诊断信息…
onboarding.title|Welcome to 拾影·Shiying|欢迎使用拾影·Shiying
onboarding.detail|Shiying continuously records supported clipboard content after you enable it. Keep 30 items including favorites, plus 5 recent items when all 30 are saved. History persists across restarts without age expiry.\n\nContent is encrypted in ~/Library/Application Support/com.shiying.mac with a key in Keychain. IDs, times, types and sizes remain metadata. Your clipboard may contain passwords or tokens; filtering cannot detect every secret. Delete history in Settings or quit Shiying to stop recording at any time. Clearing history does not clear the current clipboard. Nothing is uploaded.\n\nContinuous capture needs Always Allow for clipboard access. Copy a fragment from Shiying, then press Command+V in the destination app.|开启后，拾影会持续记录支持的剪贴板内容。常规保留 30 条（包含收藏），全收藏时额外保留最近 5 条；重启保留，不按天数过期。\n\n内容加密保存在 ~/Library/Application Support/com.shiying.mac，密钥位于钥匙串。ID、时间、类型、大小等仍为元数据。剪贴板可能含密码或令牌，过滤无法识别全部秘密。可随时在设置中删除历史，或退出拾影停止记录；清空历史不会清空当前剪贴板。没有内容上传。\n\n持续记录需将剪贴板权限设为始终允许；在拾影中复制片段后，到目标应用按 Command+V 粘贴。
later|Not Now|暂不开启
open|Open 拾影·Shiying|打开拾影·Shiying
quit|Quit 拾影·Shiying|退出拾影·Shiying
expanded|Expanded|已展开
collapsed|Collapsed|已收起
edit|Edit|编辑
undo|Undo|撤销
cut|Cut|剪切
selectAll|Select All|全选'''
strings = {}
for line in rows.splitlines():
    key,en,zh = line.split('|')
    strings[key] = {'extractionState':'manual','localizations': {lang: {'stringUnit': {'state':'translated','value': value.replace('\\n','\n')}} for lang,value in [('en',en),('zh-Hans',zh)]}}
root = Path(__file__).resolve().parent.parent
(root/'Shiying/Resources/Localizable.xcstrings').write_text(json.dumps({'sourceLanguage':'en','strings':strings,'version':'1.0'},ensure_ascii=False,indent=2)+'\n')
