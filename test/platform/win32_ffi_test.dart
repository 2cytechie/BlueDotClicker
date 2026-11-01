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

    test('GetCursorPos 返回屏幕范围内坐标', () {
      final (x, y) = u32.cursorPos();
      expect(x, inInclusiveRange(0, u32.screenW()));
      expect(y, inInclusiveRange(0, u32.screenH()));
    });

    test('屏幕尺寸为正', () {
      expect(u32.screenW(), greaterThan(0));
      expect(u32.screenH(), greaterThan(0));
    });

    test('GDI 全屏截屏返回正确尺寸的 BGRA 数据', () {
      final cap = gdi.captureScreen();
      expect(cap.width, u32.screenW());
      expect(cap.height, u32.screenH());
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
      expect(x2, x);
      expect(y2, y);
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
    });

    test('GDI 越界区域截屏不抛异常（区域被钳制）', () {
      final cap = gdi.captureScreen(region: const RectPx(5000, 5000, 100, 100));
      expect(cap.width, 1);
      expect(cap.height, 1);
      expect(cap.bgra.length, 4);
    });
}
