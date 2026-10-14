#!/usr/bin/env python3
"""architecture_gate.py 中 R8 规则（main 启动时序与危险操作）的自动回归测试。"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

# 将 tests 目录加入 sys.path，以便导入 architecture_gate
ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tests"))

from architecture_gate import check_entry_r8  # noqa: E402


class ArchitectureGateR8Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _write_entry(self, content: str) -> Path:
        p = self.tmp_path / "main.cpp"
        p.write_text(content, encoding="utf-8")
        return p

    def test_current_production_entries_pass(self) -> None:
        """保证当前仓库实际的 Mac 与 iOS 生产入口文件均能通过 R8 启动时序门禁。"""
        mac_entry = ROOT_DIR / "src" / "entry" / "mac" / "main.cpp"
        ios_entry = ROOT_DIR / "src" / "entry" / "ios" / "main.cpp"

        self.assertTrue(mac_entry.is_file(), f"Mac 入口文件不存在: {mac_entry}")
        self.assertTrue(ios_entry.is_file(), f"iOS 入口文件不存在: {ios_entry}")

        self.assertTrue(check_entry_r8(mac_entry), "Mac 生产入口未通过 R8 门禁")
        self.assertTrue(check_entry_r8(ios_entry), "iOS 生产入口未通过 R8 门禁")

    def test_direct_dangerous_ops_before_identity_rejected(self) -> None:
        """保证在 main() 中直接于 applyApplicationIdentity 之前调用 QSettings、QStandardPaths 或 openDatabase 会被明确拒绝。"""
        cases = [
            ("QSettings", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    QSettings settings;
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("QStandardPaths", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    QString path = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("openDatabase", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    openDatabase();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("openDatabase with whitespace", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    openDatabase  ();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 出现在身份设置之前应被拒绝，但被放行")

    def test_dangerous_helper_called_before_identity_rejected(self) -> None:
        """保证含有危险操作的辅助函数如果在 applyApplicationIdentity 之前被调用会被明确拒绝。"""
        code = """
            void loadSettings() {
                QSettings s;
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "危险辅助函数在身份设置前调用应被拒绝")

    def test_dangerous_helper_with_whitespace_and_comments_rejected(self) -> None:
        """保证辅助函数调用中包含空格、换行以及去除注释后的形式仍被正确识别并拒绝提前调用。"""
        cases = [
            ("trailing spaces before paren", """
                void loadSettings() { QSettings s; }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    loadSettings  ();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("newline before paren", """
                void loadSettings() { QSettings s; }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    loadSettings
                    ();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("comment between name and paren", """
                void loadSettings() { QSettings s; }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    loadSettings /* inline comment */ ();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 形式的辅助调用应被识别并拒绝，但被放行")

    def test_safe_helper_before_and_dangerous_helper_after_identity_passes(self) -> None:
        """保证不含危险操作的辅助函数在身份设置前调用，且含危险操作的辅助函数在身份设置后调用时能够合法通过，不产生误报。"""
        code = """
            void safe() {}
            void loadSettings() { QSettings s; }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                safe();
                McpPaths::applyApplicationIdentity();
                loadSettings();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "合法安全的辅助调用在身份设置前、危险辅助调用在身份设置后应通过，但被拒绝")

    def test_helper_defined_after_main_checked_correctly(self) -> None:
        """保证辅助函数定义在 main() 之后且带合法前置声明时，其危险操作仍能被准确分析并阻止提前调用。"""
        code = """
            void loadSettings();

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }

            void loadSettings() {
                QSettings s;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "main 之后定义的危险辅助函数在身份设置前调用应被拒绝")

    def test_includes_comments_strings_do_not_cause_false_positives(self) -> None:
        """保证在 #include、注释及字符串字面量中出现 QSettings 等关键词不会导致误判或误报。"""
        code = """
            #include <QSettings>
            #include <QStandardPaths>

            // QSettings in single-line comment
            /* QStandardPaths in block comment */

            void safe() {
                const char* s = "QSettings in string literal";
                int val = 42;
            }

            int main(int argc, char** argv) {
                // QSettings in main comment
                const char* msg = "openDatabase( in string";
                QGuiApplication app(argc, argv);
                safe();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "仅在 include、注释和字符串中含关键词的安全代码应通过，但被误报拒绝")

    def test_lambda_identity_cannot_bypass_top_level_check(self) -> None:
        """保证在未执行的 lambda 或嵌套代码块中定义身份初始化不能冒充顶层已执行的身份设置。"""
        code = """
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                auto setup = [] { McpPaths::applyApplicationIdentity(); };
                QSettings s;
                setup();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "lambda 内部延迟的身份设置不能作为顶层合法时序通过")

    def test_function_name_substring_not_misidentified(self) -> None:
        """保证具有相同前缀或子串名称的辅助函数（如 safe_func vs safe）不会被错误混淆或误判。"""
        code = """
            void safe() {}
            void safe_dangerous() { QSettings s; }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                safe();
                McpPaths::applyApplicationIdentity();
                safe_dangerous();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "安全函数 safe() 调用不应被 safe_dangerous 混淆判定为危险提前调用")

    def test_namespace_helper_before_identity_rejected(self) -> None:
        """保证匿名命名空间、具名命名空间与嵌套命名空间中定义的危险辅助函数提前调用均被明确拒绝。"""
        cases = [
            ("anonymous namespace", """
                namespace {
                    void loadSettings() { QSettings s; }
                }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    loadSettings();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("named namespace with qualified call", """
                namespace startup {
                    void loadSettings() { QSettings s; }
                }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    startup::loadSettings();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("nested namespace with qualified call", """
                namespace outer {
                    namespace inner {
                        void loadSettings() { QSettings s; }
                    }
                }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    outer::inner::loadSettings();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("c++17 nested namespace syntax", """
                namespace outer::inner {
                    void loadSettings() { QSettings s; }
                }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    outer::inner::loadSettings();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 中定义的危险函数提前调用应被拒绝，但被放行")

    def test_namespace_safe_helper_before_and_dangerous_after_passes(self) -> None:
        """保证命名空间内的安全辅助函数在身份设置前调用，且危险函数在身份设置后调用时合法通过。"""
        code = """
            namespace startup {
                void safe() {}
                void loadSettings() { QSettings s; }
            }
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                startup::safe();
                McpPaths::applyApplicationIdentity();
                startup::loadSettings();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "命名空间内安全函数提前调用、危险函数后调用的合法代码应通过，但被拒绝")

    def test_helper_defined_after_main_in_namespace_with_declaration(self) -> None:
        """保证在命名空间中具有前置声明且定义在 main 之后的危险辅助函数，提前调用仍被准确拦截。"""
        code = """
            namespace startup {
                void loadSettings();
            }
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                startup::loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
            namespace startup {
                void loadSettings() {
                    QSettings s;
                }
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "命名空间中后定义的危险辅助函数提前调用应被拒绝，但被放行")

    def test_function_overloads_both_orders_rejected(self) -> None:
        """保证同名重载中包含危险实现时，无论先定义危险还是先定义安全重载，提前调用均被保守拒绝。"""
        cases = [
            ("dangerous overload first", """
                void loadSettings() { QSettings s; }
                void loadSettings(int) {}
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    loadSettings();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("safe overload first", """
                void loadSettings(int) {}
                void loadSettings() { QSettings s; }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    loadSettings();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 存在危险重载，提前调用应被拒绝，但被放行")

    def test_all_safe_overloads_pass(self) -> None:
        """保证同名重载的所有实现均为安全时，在身份设置前调用合法通过，不造成误报。"""
        code = """
            void loadSettings() {}
            void loadSettings(int a) { (void)a; }
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                loadSettings();
                loadSettings(42);
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "全部安全的同名重载在身份设置前调用应合法通过，但被拒绝")

    def test_different_namespaces_same_name_not_confused(self) -> None:
        """保证不同命名空间中的同名函数不相互混淆，安全命名空间内的提前调用不被其他命名空间的危险实现误报。"""
        code1 = """
            namespace safe_ns {
                void helper() {}
            }
            namespace dang_ns {
                void helper() { QSettings s; }
            }
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                safe_ns::helper();
                McpPaths::applyApplicationIdentity();
                dang_ns::helper();
                return 0;
            }
        """
        p1 = self._write_entry(code1)
        self.assertTrue(check_entry_r8(p1), "调用 safe_ns::helper() 不应被 dang_ns::helper() 混淆误报")

        code2 = """
            void helper() {}
            namespace dang_ns {
                void helper() { QSettings s; }
            }
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                helper();
                McpPaths::applyApplicationIdentity();
                dang_ns::helper();
                return 0;
            }
        """
        p2 = self._write_entry(code2)
        self.assertTrue(check_entry_r8(p2), "调用全局 helper() 不应被 dang_ns::helper() 混淆误报")

    def test_indirect_call_forwarding_intercepted(self) -> None:
        """保证经由辅助函数转调危险操作或跨命名空间转调危险函数时，提前调用仍被深度拦截。"""
        cases = [
            ("global helper forwarding", """
                void dangerousAction() { QSettings s; }
                void intermediateHelper() { dangerousAction(); }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    intermediateHelper();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("cross namespace forwarding", """
                namespace core {
                    void initConfig() { QSettings s; }
                }
                namespace startup {
                    void setup() { core::initConfig(); }
                }
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    startup::setup();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 转调危险操作，提前调用应被拦截，但被放行")

    def test_conditional_and_compound_identity_rejected(self) -> None:
        """保证无大括号 if/else、循环、短路表达式与三目运算符中包装的身份设置不能冒充独立无条件语句。"""
        cases = [
            ("if without braces", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    if (false) McpPaths::applyApplicationIdentity();
                    QSettings s;
                    return 0;
                }
            """),
            ("else branch", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    if (true) {} else McpPaths::applyApplicationIdentity();
                    QSettings s;
                    return 0;
                }
            """),
            ("short circuit AND", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    false && (McpPaths::applyApplicationIdentity(), true);
                    QSettings s;
                    return 0;
                }
            """),
            ("short circuit OR", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    true || (McpPaths::applyApplicationIdentity(), true);
                    QSettings s;
                    return 0;
                }
            """),
            ("ternary conditional", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    false ? McpPaths::applyApplicationIdentity() : (void)0;
                    QSettings s;
                    return 0;
                }
            """),
            ("while loop", """
                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    while (false) McpPaths::applyApplicationIdentity();
                    QSettings s;
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 属于条件或复合包装形式，应被拒绝，但被放行")

    def test_independent_identity_with_whitespace_and_comments_passes(self) -> None:
        """保证顶层独立、无条件的身份初始化在包含合法空格、换行、去注释后空白等正常形式下均能通过。"""
        code = """
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                /* 重要：先应用应用身份 */
                McpPaths
                    ::
                    applyApplicationIdentity
                    (
                    )
                    ;
                QSettings s;
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "带合法换行、注释与空白的顶层独立身份设置语句应通过，但被拒绝")

    def test_comment_stripping_preserves_token_separation(self) -> None:
        """保证代码清洗阶段移除块注释时保留必要词法分隔，不因删除注释导致两个标识符拼接成一个。"""
        code = """
            void/*comment*/safe() {}
            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                safe();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "注释位于类型与函数名之间时，清洗后应保留词法分隔并正确识别函数名")

    def test_nested_namespace_lookup_outer_dangerous_function_rejected(self) -> None:
        """保证嵌套命名空间内的函数调用外层命名空间中定义的危险函数时，提前调用被准确识别并拒绝。"""
        code = """
            namespace outer {
                void loadSettings() { QSettings s; }

                namespace inner {
                    void prepare() { loadSettings(); }
                }
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                outer::inner::prepare();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "内层 prepare() 调用外层危险 loadSettings()，提前调用应被拒绝")

    def test_nested_namespace_lookup_shadowing_prefers_inner_safe_function(self) -> None:
        """保证嵌套命名空间内存在同名安全函数时，非限定短名调用优先命中内层安全函数（遮蔽外层同名危险函数），提前调用合法通过。"""
        code = """
            namespace outer {
                void loadSettings() { QSettings s; }

                namespace inner {
                    void loadSettings() {}
                    void prepare() { loadSettings(); }
                }
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                outer::inner::prepare();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "内层存在同名安全函数遮蔽外层危险函数时，提前调用应通过")

    def test_qualified_name_prefix_conflict_not_falsely_rejected(self) -> None:
        """保证调用形如 safe_ns::startup::loadSettings() 时，不会被错误匹配为同名后缀 startup::loadSettings() 而误报。"""
        code = """
            namespace startup {
                void loadSettings() { QSettings s; }
            }

            namespace safe_ns::startup {
                void loadSettings() {}
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                safe_ns::startup::loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "调用 safe_ns::startup::loadSettings() 不应被 startup::loadSettings() 误判拒绝")

    def test_qualified_name_prefix_conflict_in_helper_transfer(self) -> None:
        """保证经由辅助函数转调 safe_ns::startup::loadSettings() 时，也不会被误报拦截。"""
        code = """
            namespace startup {
                void loadSettings() { QSettings s; }
            }

            namespace safe_ns::startup {
                void loadSettings() {}
            }

            void safeHelper() {
                safe_ns::startup::loadSettings();
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                safeHelper();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "辅助函数转调 safe_ns::startup::loadSettings() 应合法通过")

    def test_global_qualified_call_supported(self) -> None:
        """保证前导 :: 的全局限定调用（::outer::inner::loadSettings()）在支持范围内被正确解析。"""
        code = """
            namespace outer::inner {
                void loadSettings() { QSettings s; }
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                ::outer::inner::loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "全局限定调用 ::outer::inner::loadSettings() 危险操作提前应被拦截")

    def test_unsupported_using_declaration_rejected_with_diagnostic(self) -> None:
        """保证身份设置前出现 using 符号声明时，给出明确的不支持诊断并拒绝放行。"""
        code = """
            namespace startup {
                void loadSettings() { QSettings s; }
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                using startup::loadSettings;
                loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "using 符号声明无法可靠解析启动时序，应拒绝放行")

    def test_unsupported_using_namespace_rejected_with_diagnostic(self) -> None:
        """保证身份设置前出现 using namespace 指令时，给出明确的不支持诊断并拒绝放行。"""
        code = """
            namespace startup {
                void loadSettings() { QSettings s; }
            }

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                using namespace startup;
                loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "using namespace 指令无法可靠解析启动时序，应拒绝放行")

    def test_unsupported_namespace_alias_rejected_with_diagnostic(self) -> None:
        """保证出现 namespace 别名定义时，给出明确的不支持诊断并拒绝放行。"""
        code = """
            namespace startup {
                void loadSettings() { QSettings s; }
            }
            namespace st = startup;

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                st::loadSettings();
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertFalse(check_entry_r8(p), "namespace 别名无法可靠解析启动时序，应拒绝放行")

    def test_using_type_alias_allowed(self) -> None:
        """保证合法的 using 类型别名（带等号 =）正常允许，不产生误报。"""
        code = """
            using MyInt = int;

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                MyInt a = 1;
                (void)a;
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "using 类型别名语法应合法通过，不应误报拒绝")

    def test_class_with_member_function_rejected(self) -> None:
        """保证入口定义包含成员函数实现的 class/struct 时（包括普通方法、static、const、noexcept、override 等限定符修饰），因轻量门禁不支持解析类作用域而明确拒绝。"""
        cases = [
            ("simple method", """
                struct Helper {
                    void run() { QSettings s; }
                };

                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    Helper h;
                    h.run();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("static noexcept method", """
                struct Startup {
                    static void prepare() noexcept {
                        QSettings s;
                    }
                };

                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    Startup::prepare();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("const method", """
                struct Worker {
                    void process() const {
                        QSettings s;
                    }
                };

                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    Worker w;
                    w.process();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("const noexcept method", """
                struct Runner {
                    void execute() const noexcept {
                        QSettings s;
                    }
                };

                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    Runner r;
                    r.execute();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
            ("virtual override method", """
                struct Base {
                    virtual ~Base() = default;
                    virtual void init() = 0;
                };
                struct Derived : Base {
                    void init() override {
                        QSettings s;
                    }
                };

                int main(int argc, char** argv) {
                    QGuiApplication app(argc, argv);
                    Derived d;
                    d.init();
                    McpPaths::applyApplicationIdentity();
                    return 0;
                }
            """),
        ]
        for name, code in cases:
            with self.subTest(case=name):
                p = self._write_entry(code)
                self.assertFalse(check_entry_r8(p), f"{name} 类内包含成员函数实现应被拒绝，但被放行")

    def test_plain_data_struct_allowed(self) -> None:
        """保证不含成员函数实现的纯数据 struct 合法通过，不产生误报。"""
        code = """
            struct StartupConfig {
                int mode;
                const char* tag;
            };

            int main(int argc, char** argv) {
                QGuiApplication app(argc, argv);
                StartupConfig cfg{1, "test"};
                (void)cfg;
                McpPaths::applyApplicationIdentity();
                return 0;
            }
        """
        p = self._write_entry(code)
        self.assertTrue(check_entry_r8(p), "纯数据 struct 应合法通过，不应误报拒绝")


if __name__ == "__main__":
    unittest.main()

