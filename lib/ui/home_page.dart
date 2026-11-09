import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/blueprint.dart';
import '../models/node_types.dart';
import '../services/script_package.dart';
import '../state/providers.dart';
import 'common.dart';

/// 首页：功能入口 + 脚本管理
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final automation = ref.watch(automationProvider);
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题区
                const PageHeader(title: '蓝点器', subtitle: 'Windows 自动化 · 蓝图工作流'),
                // 平台不支持提示
                if (!automation.isSupported) ...[
                  const _UnsupportedBanner(),
                  const SizedBox(height: 16),
                ],
                // 功能入口卡片：宽窗口等宽铺满，窄窗口自动换行
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 760;
                    final cards = const [
                      _EntryCard(
                        title: '蓝图编辑器',
                        desc: '拖拽节点搭建自动化工作流',
                        icon: Icons.account_tree_outlined,
                        color: NodeCategory.logic,
                        route: '/editor',
                      ),
                      _EntryCard(
                        title: '录制回放',
                        desc: '录制键鼠操作，回放或供蓝图「执行录制」节点调用',
                        icon: Icons.fiber_manual_record_rounded,
                        color: NodeCategory.media,
                        route: '/recordings',
                      ),
                    ];
                    if (wide) {
                      return Row(
                        children: [
                          for (final (i, card) in cards.indexed) ...[
                            if (i > 0) const SizedBox(width: 14),
                            Expanded(child: card),
                          ],
                        ],
                      );
                    }
                    return Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: cards
                          .map((c) => SizedBox(width: 260, child: c))
                          .toList(),
                    );
                  },
                ),
                const SizedBox(height: 28),
                // 我的脚本
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '我的脚本',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _importScript(context, ref),
                      icon: const Icon(Icons.upload_file_rounded, size: 18),
                      label: const Text('导入'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: () => _createScript(context, ref),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新建'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const _ScriptList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 新建脚本：输入名称 → 查重 → 创建含开始节点的脚本 → 保存 → 进编辑器
  Future<void> _createScript(BuildContext context, WidgetRef ref) async {
    final name = await _promptName(context, title: '新建脚本', hint: '输入脚本名称');
    if (name == null || !context.mounted) return;
    final storage = ref.read(scriptStorageProvider);
    if (await storage.exists(name)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已存在同名脚本，请换一个名称')));
      return;
    }
    final s = BlueprintScript(name: name)
      ..nodes['n_start'] = BPNode(id: 'n_start', type: 'start', x: 80, y: 80);
    await storage.save(s);
    await ref.read(scriptListProvider.notifier).refresh();
    if (!context.mounted) return;
    ref.read(currentScriptProvider.notifier).open(s);
    ref.read(appNavProvider.notifier).go(AppTab.editor);
  }

  /// 导入脚本：按文件头分流 ZIP 包（.bpc.zip）与纯 JSON（.bpc.json）
  Future<void> _importScript(BuildContext context, WidgetRef ref) async {
    const group = XTypeGroup(label: '脚本包', extensions: ['zip', 'json']);
    final f = await openFile(
      acceptedTypeGroups: const [group],
      confirmButtonText: '导入',
    );
    if (f == null || !context.mounted) return;
    try {
      final bytes = await f.readAsBytes();
      final fallback = f.name.replaceAll(
        RegExp(r'\.bpc\.zip$|\.zip$|\.bpc\.json$|\.json$', caseSensitive: false),
        '',
      );
      final pkg = ScriptPackage();
      final result = ScriptPackage.isZipBytes(bytes)
          ? await pkg.importZip(bytes, fallbackName: fallback)
          : await pkg.importJson(
              utf8.decode(bytes, allowMalformed: true),
              fallbackName: fallback,
            );
      await ref.read(scriptListProvider.notifier).refresh();
      // 导入的 zip 会把内嵌录制写入本机录制目录；录制列表是全局缓存
      // （启动时 IndexedStack 已构建录制页触发加载），不刷新会让蓝图
      // 「执行录制」节点误判新导入的录制「已删除」
      ref.invalidate(recordingsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_importSummary(result))));
    } on PackageException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败：${e.message}')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导入失败：文件不是有效的脚本或脚本包')));
    }
  }

  /// 通用名称输入对话框
  Future<String?> _promptName(
    BuildContext context, {
    required String title,
    String? initial,
    String? hint,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial, hint: hint),
    );
    return (result == null || result.isEmpty) ? null : result;
  }
}

/// 名称输入对话框。
/// controller 生命周期跟随对话框元素：showDialog 的 future 在 pop 时即完成，
/// 而对话框 pop 动画仍在播放——若此时 dispose controller，动画帧中 TextField
/// 仍会访问已销毁的 controller 并抛断言。State.dispose（元素卸载）才是正确时机。
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, this.initial, this.hint});

  final String title;
  final String? initial;
  final String? hint;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint, labelText: '名称'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 平台不支持自动化时的警示条
class _UnsupportedBanner extends StatelessWidget {
  const _UnsupportedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.moonWhite,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: AppColors.inkSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前平台暂不支持自动化执行，可正常编辑脚本',
              style: TextStyle(fontSize: 13, color: AppColors.inkSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 功能入口卡片
class _EntryCard extends ConsumerWidget {
  final String title;
  final String desc;
  final IconData icon;
  final NodeCategory color;
  final String route;

  const _EntryCard({
    required this.title,
    required this.desc,
    required this.icon,
    required this.color,
    required this.route,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: AppColors.moonWhite,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => ref.read(appNavProvider.notifier).go(switch (route) {
          '/editor' => AppTab.editor,
          '/recordings' => AppTab.recordings,
          _ => AppTab.home,
        }),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color.color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.inkSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.inkSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 脚本列表（含加载/错误/空态）
class _ScriptList extends ConsumerWidget {
  const _ScriptList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(scriptListProvider);
    return list.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => SectionCard(
        title: '加载失败',
        icon: Icons.error_outline_rounded,
        child: Column(
          children: [
            Text('$e', style: TextStyle(color: AppColors.danger, fontSize: 13)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => ref.read(scriptListProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
      data: (scripts) {
        if (scripts.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppColors.moonWhite,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.note_add_rounded,
                  size: 40,
                  color: AppColors.inkSecondary,
                ),
                const SizedBox(height: 10),
                Text(
                  '还没有脚本，点击右上角「新建」创建第一个蓝图，或导入 .bpc.zip / .bpc.json 文件',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.inkSecondary, fontSize: 13),
                ),
              ],
            ),
          );
        }
        return SectionCard(
          title: '共 ${scripts.length} 个脚本',
          icon: Icons.folder_open_rounded,
          child: Column(
            children: [
              for (final s in scripts)
                _ScriptRow(script: s, isLast: s == scripts.last),
            ],
          ),
        );
      },
    );
  }
}

/// 单个脚本行
class _ScriptRow extends ConsumerWidget {
  final BlueprintScript script;
  final bool isLast;

  const _ScriptRow({required this.script, required this.isLast});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = script;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const Icon(
                Icons.hub_outlined,
                size: 20,
                color: AppColors.peacock,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        color: AppColors.ink,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmtTime(s.updatedAt)} · ${s.nodes.length} 个节点',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _rowAction(
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                onTap: () => _openEditor(context, ref),
              ),
              _rowAction(
                icon: Icons.drive_file_rename_outline_rounded,
                tooltip: '重命名',
                onTap: () => _rename(context, ref),
              ),
              _rowAction(
                icon: Icons.copy_rounded,
                tooltip: '复制',
                onTap: () => _duplicate(context, ref),
              ),
              _rowAction(
                icon: Icons.ios_share_rounded,
                tooltip: '导出',
                onTap: () => _export(context, ref),
              ),
              _rowAction(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                color: AppColors.danger,
                onTap: () => _delete(context, ref),
              ),
            ],
          ),
        ),
        if (!isLast) const Divider(),
      ],
    );
  }

  Widget _rowAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      color: color ?? AppColors.inkSecondary,
      tooltip: tooltip,
      onPressed: onTap,
    );
  }

  void _openEditor(BuildContext context, WidgetRef ref) {
    ref.read(currentScriptProvider.notifier).open(script);
    ref.read(appNavProvider.notifier).go(AppTab.editor);
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await _prompt(context, title: '重命名脚本', initial: script.name);
    if (name == null) return;
    // 重命名为已有名会静默覆盖另一脚本的磁盘文件，必须在落盘前拦截
    final storage = ref.read(scriptStorageProvider);
    if (name != script.name && await storage.exists(name)) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已存在同名脚本，请换一个名称')));
      }
      return;
    }
    final cur = ref.read(currentScriptProvider);
    await storage.rename(script, name);
    await ref.read(scriptListProvider.notifier).refresh();
    // 重命名/删除影响的是 currentScript 指向的旧对象；不关闭的话，
    // 侧边栏「蓝图」会载入旧名对象并可能把已删脚本"复活"回磁盘
    if (cur != null && cur.name == script.name) {
      ref.read(currentScriptProvider.notifier).close();
    }
  }

  Future<void> _duplicate(BuildContext context, WidgetRef ref) async {
    await ref
        .read(scriptStorageProvider)
        .duplicate(script, '${script.name} 副本');
    await ref.read(scriptListProvider.notifier).refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制脚本')));
  }

  /// 导出为 ZIP 包（内嵌被引用的录制与模板图片）
  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final PackageBuildResult result;
    try {
      result = await ScriptPackage().build(script);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
      return;
    }
    if (!result.missing.isEmpty) {
      if (!context.mounted) return;
      final cont = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('存在缺失的录制/模板'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('以下引用在本机找不到，导出后对应节点可能无法执行：'),
                const SizedBox(height: 8),
                for (final id in result.missing.recordings)
                  Text('录制：$id', style: const TextStyle(fontSize: 12)),
                for (final t in result.missing.templates)
                  Text('模板：$t', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                const Text('继续导出将只打包已存在的项，蓝图中的引用会原样保留。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续导出'),
            ),
          ],
        ),
      );
      if (cont != true) return;
    }
    if (!context.mounted) return;
    final p = await getSaveLocation(
      suggestedName: '${script.name}.bpc.zip',
      acceptedTypeGroups: const [
        XTypeGroup(label: '脚本包', extensions: ['zip']),
      ],
    );
    if (p == null || !context.mounted) return;
    try {
      await File(p.path).writeAsBytes(result.bytes, flush: true);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出到 ${p.path}')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导出失败')));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除脚本'),
        content: Text('确定删除「${script.name}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final cur = ref.read(currentScriptProvider);
    await ref.read(scriptStorageProvider).delete(script.name);
    await ref.read(scriptListProvider.notifier).refresh();
    // 删除当前打开的脚本后关闭引用，避免侧边栏「蓝图」把已删脚本"复活"
    if (cur != null && cur.name == script.name) {
      ref.read(currentScriptProvider.notifier).close();
    }
  }
}

String _importSummary(PackageImportResult r) {
  final parts = <String>[
    if (r.recordingsAdded > 0) '录制新增 ${r.recordingsAdded}',
    if (r.recordingsReused > 0) '录制复用 ${r.recordingsReused}',
    if (r.recordingsRemapped > 0) '录制重映射 ${r.recordingsRemapped}',
    if (r.templatesAdded > 0) '模板新增 ${r.templatesAdded}',
    if (r.templatesReused > 0) '模板复用 ${r.templatesReused}',
  ];
  final detail = parts.isEmpty ? '' : '（${parts.join('，')}）';
  final dangling = r.hasDangling
      ? '；仍有 ${r.danglingRecordings.length} 个录制、'
            '${r.danglingTemplates.length} 个模板在本机找不到'
      : '';
  return '导入成功：${r.scriptName}$detail$dangling';
}

String _fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 行内通用名称输入对话框（供脚本行复用）
Future<String?> _prompt(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial),
  );
  return (result == null || result.isEmpty) ? null : result;
}
