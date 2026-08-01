#!/usr/bin/env python3
"""check-test-docs.py 的可执行自测（Python stdlib unittest）。

覆盖：合规注册、匿名 body、缺 doc、缺背景/变更/日期、拆行注册、
Golden dispatcher、同一条多注册行、注释/字符串/import 不误判。
"""

import importlib.util
import os
import tempfile
import unittest

# 检查器文件名含连字符（check-test-docs.py），不能直接 import，改用文件路径加载。
def _load_checker():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-test-docs.py")
    spec = importlib.util.spec_from_file_location("check_test_docs", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load checker from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ctd = _load_checker()


def check_source(source):
    """把源码写入临时 .hs 文件并运行检查器，返回违规消息列表。"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "SampleTest.hs")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(source)
        violations = ctd.check_file(path)
        return [str(v) for v in violations]


GOOD_DOC = """-- | 规格：有完整文档的测试。
-- 背景：验证门禁放行合法注册。
-- 变更记录：- 2026-08-01: 补充自测覆盖。
"""

MODULE_HEADER = """module SampleTest (tests) where

import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "sample"
"""


class CompliantRegistration(unittest.TestCase):
    def test_single_documented_registration_passes(self):
        source = MODULE_HEADER + "  [testCase \"documented\" documentedTest]\n" + GOOD_DOC + "documentedTest :: Assertion\ndocumentedTest = pure ()\n"
        self.assertEqual(check_source(source), [])


class AnonymousBody(unittest.TestCase):
    def test_lambda_body_is_rejected(self):
        source = MODULE_HEADER + '  [testCase "anonymous" (\\_ -> pure ())]\n'
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("匿名 testCase", problems[0])


class MissingDoc(unittest.TestCase):
    def test_undocumented_binding_is_rejected(self):
        source = MODULE_HEADER + '  [testCase "missing docs" undocumentedTest]\nundocumentedTest :: Assertion\nundocumentedTest = pure ()\n'
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("缺少 `-- |` 文档块", problems[0])


class DocRequirements(unittest.TestCase):
    def test_missing_background_is_rejected(self):
        doc = "-- | 规格：只有规格没有背景。\n-- 变更记录：- 2026-08-01: 补充自测覆盖。\n"
        source = MODULE_HEADER + '  [testCase "no background" noBackground]\n' + doc + "noBackground :: Assertion\nnoBackground = pure ()\n"
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("缺少 `背景：`", problems[0])

    def test_missing_changelog_is_rejected(self):
        doc = "-- | 规格：只有背景没有变更记录。\n-- 背景：验证缺变更记录被拒。\n"
        source = MODULE_HEADER + '  [testCase "no changelog" noChangelog]\n' + doc + "noChangelog :: Assertion\nnoChangelog = pure ()\n"
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("缺少 `变更记录：`", problems[0])

    def test_missing_dated_entry_is_rejected(self):
        doc = "-- | 规格：变更记录没有日期条目。\n-- 背景：验证缺日期被拒。\n-- 变更记录：- 忘了写日期。\n"
        source = MODULE_HEADER + '  [testCase "no date" noDate]\n' + doc + "noDate :: Assertion\nnoDate = pure ()\n"
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("缺少 `- YYYY-MM-DD:` 日期条目", problems[0])

    def test_missing_spec_is_rejected(self):
        doc = "-- | 背景：只有背景没有规格说明。\n-- 变更记录：- 2026-08-01: 补充自测覆盖。\n"
        source = MODULE_HEADER + '  [testCase "no spec" noSpec]\n' + doc + "noSpec :: Assertion\nnoSpec = pure ()\n"
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("缺少行为规格说明", problems[0])


class SplitRegistration(unittest.TestCase):
    def test_testcase_keyword_split_from_title_is_rejected(self):
        source = MODULE_HEADER + "  [testCase\n    \"split title\" documentedTest]\n" + GOOD_DOC + "documentedTest :: Assertion\ndocumentedTest = pure ()\n"
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("拆行注册", problems[0])

    def test_title_split_from_body_is_rejected(self):
        source = MODULE_HEADER + "  [testCase \"split body\"\n    documentedTest]\n" + GOOD_DOC + "documentedTest :: Assertion\ndocumentedTest = pure ()\n"
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("拆行注册", problems[0])


class GoldenDispatcher(unittest.TestCase):
    def test_dispatcher_targets_are_checked(self):
        source = (
            "module SampleTest (dispatchTests) where\n"
            "import Test.Tasty\n"
            "import Test.Tasty.HUnit\n"
            "dispatchTests :: TestTree\n"
            "dispatchTests = testGroup \"dispatch\" [testCase \"runs scenario\" (replayOf \"a\")]\n"
            "replayOf :: String -> Assertion\n"
            "replayOf scenario = case scenario of\n"
            '  "a" -> runA\n'
            "  other -> error other\n"
            "runA :: Assertion\n"
            "runA = pure ()\n"
        )
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("`runA` 紧邻声明前缺少 `-- |` 文档块", problems[0])

    def test_dispatcher_with_documented_targets_passes(self):
        source = (
            "module SampleTest (dispatchTests) where\n"
            "import Test.Tasty\n"
            "import Test.Tasty.HUnit\n"
            "dispatchTests :: TestTree\n"
            "dispatchTests = testGroup \"dispatch\" [testCase \"runs scenario\" (replayOf \"a\")]\n"
            "replayOf :: String -> Assertion\n"
            "replayOf scenario = case scenario of\n"
            '  "a" -> runA\n'
            "  other -> error other\n"
            + GOOD_DOC
            + "runA :: Assertion\n"
            "runA = pure ()\n"
        )
        self.assertEqual(check_source(source), [])


class SameLineMultipleRegistrations(unittest.TestCase):
    def test_both_registrations_are_checked(self):
        source = (
            MODULE_HEADER
            + '  [testCase "documented" documentedTest, testCase "undocumented" undocumentedTest]\n'
            + GOOD_DOC
            + "documentedTest :: Assertion\ndocumentedTest = pure ()\n"
            + "undocumentedTest :: Assertion\nundocumentedTest = pure ()\n"
        )
        problems = check_source(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("`undocumentedTest`", problems[0])


class NoFalsePositives(unittest.TestCase):
    def test_comment_mentioning_testcase_is_ignored(self):
        source = MODULE_HEADER + "  [testCase \"documented\" documentedTest]\n" + GOOD_DOC + "documentedTest :: Assertion\ndocumentedTest = pure ()\n-- testCase in a comment is not a registration\n"
        self.assertEqual(check_source(source), [])

    def test_string_literal_mentioning_testcase_is_ignored(self):
        source = (
            MODULE_HEADER
            + '  [testCase "documented" documentedTest]\n'
            + GOOD_DOC
            + "documentedTest :: Assertion\n"
            + 'documentedTest = assertBool "testCase inside a string" True\n'
        )
        self.assertEqual(check_source(source), [])

    def test_import_line_is_ignored(self):
        source = MODULE_HEADER + "  [testCase \"documented\" documentedTest]\n" + GOOD_DOC + "documentedTest :: Assertion\ndocumentedTest = pure ()\n"
        source = source.replace("import Test.Tasty\n", "import Test.Tasty\nimport Test.Tasty.QuickCheck (testProperty)\n")
        self.assertEqual(check_source(source), [])

    def test_testproperty_registration_passes_with_doc(self):
        source = (
            "module SampleTest (props) where\n"
            "import Test.Tasty\n"
            "import Test.Tasty.QuickCheck (testProperty)\n"
            "props :: TestTree\n"
            "props = testGroup \"props\" [testProperty \"round trips\" roundTrips]\n"
            + GOOD_DOC
            + "roundTrips :: Property\n"
            "roundTrips = property True\n"
        )
        self.assertEqual(check_source(source), [])


if __name__ == "__main__":
    unittest.main()
