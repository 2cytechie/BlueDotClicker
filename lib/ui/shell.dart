import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../state/providers.dart';
import 'editor/editor_page.dart';
import 'home_page.dart';
import 'recording_page.dart';

/// 应用布局壳：编辑器全屏显示，其余页面为「左侧导航栏 + 右侧内容区」。
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(appNavProvider);
    if (tab == AppTab.editor) {
      return const EditorPage();
    }
    return Scaffold(
      body: Row(
        children: [
          const _SideNav(),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(
              index: switch (tab) {
                AppTab.home => 0,
                AppTab.recordings => 1,
                AppTab.editor => 0,
              },
              children: const [HomePage(), RecordingPage()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNav extends ConsumerWidget {
  const _SideNav();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 88,
      color: AppColors.moonWhite,
      child: Column(
        children: [
          const SizedBox(height: 20),
          // 应用标识
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.peacock,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.hub_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 6),
          const Text(
            '蓝点器',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w400,
              color: AppColors.inkSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          const _NavItem(
            icon: Icons.home_rounded,
            label: '首页',
            tab: AppTab.home,
          ),
          const _NavItem(
            icon: Icons.account_tree_rounded,
            label: '蓝图',
            tab: AppTab.editor,
          ),
          const _NavItem(
            icon: Icons.fiber_manual_record_rounded,
            label: '录制',
            tab: AppTab.recordings,
          ),
        ],
      ),
    );
  }
}

class _NavItem extends ConsumerWidget {
  const _NavItem({required this.icon, required this.label, required this.tab});

  final IconData icon;
  final String label;
  final AppTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appNavProvider) == tab;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
      child: Material(
        color: selected ? AppColors.peacock : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => ref.read(appNavProvider.notifier).go(tab),
          child: Container(
            width: 68,
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: selected ? Colors.white : AppColors.inkSecondary,
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w300,
                    color: selected ? Colors.white : AppColors.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
