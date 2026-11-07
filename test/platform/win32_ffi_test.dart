/// Windows FFI 集成冒烟：验证 user32/gdi32 绑定与真实系统交互。
/// 仅在 Windows 上运行。
library;

import 'package:bluedot_clicker/platform/platform_automation.dart';
import 'package:bluedot_clicker/platform/win32/gdi32.dart' as gdi;
import 'package:bluedot_clicker/platform/win32/user32.dart' as u32;
import 'package:bluedot_clicker/platform/windows_automation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

    test('GetCursorPos 返回虚拟桌面范围内坐标（多屏可为负）', () {
      final (x, y) = u32.cursorPos();
      final (vx, vy, vw, vh) = u32.virtualScreenRect();
      expect(x, inInclusiveRange(vx, vx + vw - 1));
      expect(y, inInclusiveRange(vy, vy + vh - 1));
    });

    test('屏幕尺寸为正', () {
      expect(u32.screenW(), greaterThan(0));
      expect(u32.screenH(), greaterThan(0));
    });

    test('GDI 全屏截屏覆盖整个虚拟桌面并返回原点', () {
      final cap = gdi.captureScreen();
      final (vx, vy, vw, vh) = u32.virtualScreenRect();
      final hasVirtual = vw > 0 && vh > 0;
      expect(cap.width, hasVirtual ? vw : u32.screenW());
      expect(cap.height, hasVirtual ? vh : u32.screenH());
      expect((cap.x, cap.y), hasVirtual ? (vx, vy) : (0, 0));
      expect(cap.bgra.length, cap.width * cap.height * 4);
      // 真实屏幕不应是纯黑帧（统计非零字节）
      final nonZero = cap.bgra.where((b) => b != 0).length;
      expect(nonZero, greaterThan(0), reason: '截屏不应为全黑');
    });

    test('GDI 区域截屏（100x80 区域）', () {
      final cap = gdi.captureScreen(region: const RectPx(0, 0, 100, 80));
      expect(cap.width, 100);
      expect(cap.height, 80);
      expect(cap.bgra.length, 100 * 80 * 4);
    });

    test('鼠标模拟：移动+点击当前位置不抛异常', () async {
      final (x, y) = u32.cursorPos();
      u32.moveAbsolute(x, y);
      u32.clickAt(x, y); // 在原位点击，无副作用
      final (x2, y2) = u32.cursorPos();
      // 绝对坐标经 16 位归一化后再由系统换算回像素，存在 ±1px 量化误差；
      // 多屏/负坐标下更明显，故断言允许 1px 偏差（本用例目的是"不抛异常"）
      expect((x2 - x).abs(), lessThanOrEqualTo(1));
      expect((y2 - y).abs(), lessThanOrEqualTo(1));
    });

    test('窗口/热键查询接口可调用（FFI 绑定有效）', () {
      // 仅验证符号存在且可调用，不断言具体值（与系统当前状态相关）
      expect(u32.ownForegroundWindow(), isA<int>());
      expect(u32.isKeyDown(u32.vkF10), isA<bool>());
      expect(const WindowsAutomation().isKeyDown(u32.vkF10), isA<bool>());
    });

    group('clampRegionToScreen 区域钳制（越界不崩溃）', () {
      test('正常区域原样通过', () {
        expect(gdi.clampRegionToScreen(10, 20, 100, 80, 1920, 1080), (10, 20, 100, 80));
      });

      test('起点越出屏幕：钳到边缘并取 1 像素，不抛 ArgumentError', () {
        // 修复前：w.clamp(1, sw - x) 在 x>=sw 时因上界为负抛错，截屏整个报废
        expect(gdi.clampRegionToScreen(5000, 5000, 50, 50, 1920, 1080), (1919, 1079, 1, 1));
      });

      test('负起点与超大宽高：钳到屏幕内', () {
        expect(gdi.clampRegionToScreen(-20, -20, 5000, 5000, 1920, 1080), (0, 0, 1920, 1080));
      });

      test('虚拟桌面负原点（副屏在主屏左侧）：负坐标区域原样保留', () {
        // 虚拟桌面 (-1920,0,3840,1080)：副屏区域不应被钳到 0
        expect(
          gdi.clampRegionToScreen(-1500, 100, 400, 300, 3840, 1080, originX: -1920),
          (-1500, 100, 400, 300),
        );
        // 越过虚拟桌面左边界时钳到原点（-1920），而不是主屏 0
        expect(
          gdi.clampRegionToScreen(-2000, 100, 400, 300, 3840, 1080, originX: -1920),
          (-1920, 100, 400, 300),
        );
        // 越过右边界时收缩宽度
        expect(
          gdi.clampRegionToScreen(1800, 100, 400, 300, 3840, 1080, originX: -1920),
          (1800, 100, 120, 300),
        );
      });

      test('虚拟桌面负 Y 原点（副屏在主屏上方）同样保留负起点', () {
        expect(
          gdi.clampRegionToScreen(100, -800, 300, 200, 1920, 2160, originY: -1080),
          (100, -800, 300, 200),
        );
      });
    });

    test('GDI 越界区域截屏不抛异常（区域被钳制）', () {
      final cap = gdi.captureScreen(region: const RectPx(5000, 5000, 100, 100));
      expect(cap.width, 1);
      expect(cap.height, 1);
      expect(cap.bgra.length, 4);
    });

    test('负 X 区域截屏返回请求尺寸与负原点（需副屏在主屏左侧）', () {
      final (vx, vy, vw, vh) = u32.virtualScreenRect();
      if (vx >= 0) {
        // 单屏或副屏在右侧：本机没有负 X 可测，仅验证钳制基准
        return;
      }
      final cap = gdi.captureScreen(region: RectPx(vx + 10, vy + 10, 40, 30));
      expect((cap.x, cap.y), (vx + 10, vy + 10), reason: '采集原点应保留负坐标');
      expect((cap.width, cap.height), (40, 30), reason: '负坐标区域不应被钳成主屏内容');
    });

  group('绝对坐标归一化（虚拟桌面）', () {
    test('单屏：左上角映射 0，右下角映射 65535', () {
      expect(u32.normalizeVirtual(0, 0, (0, 0, 1920, 1080)), (0, 0));
      expect(
        u32.normalizeVirtual(1919, 1079, (0, 0, 1920, 1080)),
        (65535, 65535),
      );
    });

    test('副屏在主屏左侧（负原点）：主屏右边缘映射到 65535', () {
      const rect = (-1920, 0, 3840, 1080);
      expect(u32.normalizeVirtual(-1920, 0, rect), (0, 0));
      expect(u32.normalizeVirtual(1919, 1079, rect), (65535, 65535));
    });

    test('负坐标落在虚拟桌面内：归一化值随坐标单调递增', () {
      const rect = (-1920, 0, 3840, 1080);
      final (leftMost, _) = u32.normalizeVirtual(-1, 0, rect);
      final (zero, _) = u32.normalizeVirtual(0, 0, rect);
      expect(leftMost, greaterThan(0));
      expect(leftMost, lessThan(65535));
      expect(zero, greaterThan(leftMost));
      // x=-1 应位于虚拟桌面中点附近（主屏左边界）
      expect(zero - leftMost, closeTo(65535 / 3839, 1));
    });

    test('虚拟桌面外的坐标被钳制到边界，不产生负数/越界值', () {
      const rect = (-1920, 0, 3840, 1080);
      expect(u32.normalizeVirtual(-99999, -99999, rect), (0, 0));
      expect(u32.normalizeVirtual(99999, 99999, rect), (65535, 65535));
    });

    test('退化尺寸（1×1）不除零', () {
      expect(u32.normalizeVirtual(10, 10, (0, 0, 1, 1)), (0, 0));
    });
  });
}
