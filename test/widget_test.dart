// 占位测试：阻止 CI 里 flutter create 生成引用 MyApp 模板的 widget_test.dart。
// 真正的测试在 smoke_test.dart。
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
