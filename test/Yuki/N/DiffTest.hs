-- | unified diff 生成器测试
--
-- 覆盖：相同输入的空输出、追加-only 补丁的加法单调性、中段替换的对称行，以及三条可证明的
-- QuickCheck 不变量（相同输入为空、追加不产生删除行、存在差异则输出非空）。
-- 边界：不覆盖真实文件系统；全部为内存文本。
-- 变更记录：
--   - 2026-08-01: 新增 Diff 不变量与基础形状的回归覆盖。
module Yuki.N.DiffTest
  ( diffTests,
    unifiedReplacesMiddle,
    unifiedIdenticalInput,
    unifiedAppendOnly,
    unifiedDifferenceNonEmpty,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Test.QuickCheck
  ( Gen,
    Property,
    counterexample,
    elements,
    forAll,
    listOf,
    suchThat,
    (.&&.),
    (===),
    (==>),
  )
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)
import Yuki.N.Diff (unified)

diffTests :: TestTree
diffTests =
  testGroup
    "unified diff"
    [ testCase "replaces a changed middle line with -/+ pairs" unifiedReplacesMiddle,
      testProperty "same input produces an empty diff" unifiedIdenticalInput,
      testProperty "append-only changes add lines and never delete" unifiedAppendOnly,
      testProperty "different inputs always produce a non-empty diff" unifiedDifferenceNonEmpty
    ]

-- | 规格：中段单行替换产生包含 "-b" 与 "+x" 内容行的补丁。
-- 背景：unified 输出被审计/展示消费；替换行形状错误会让人类与工具都读错变更。
-- 变更记录：- 2026-08-01: 补充 Diff 基础替换形状的回归覆盖。
unifiedReplacesMiddle :: Assertion
unifiedReplacesMiddle =
  let output = unified "note.md" "a\nb\nc" "a\nx\nc"
      contentLines = drop 1 (Text.lines output)
   in sequence_
        [ assertBool "replacement must not be empty" (not (Text.null output)),
          assertBool "removed line is marked with -" (any (Text.isPrefixOf "-b") contentLines),
          assertBool "added line is marked with +" (any (Text.isPrefixOf "+x") contentLines)
        ]

-- | 规格：任意输入与自身比较时 unified 输出为空串。
-- 背景：相同输入的零 hunk 是 diff 的根基契约；非空输出会污染审计差异。
-- 变更记录：- 2026-08-01: 补充 Diff 相同输入不变量的属性覆盖。
unifiedIdenticalInput :: Property
unifiedIdenticalInput =
  forAll genText $ \content ->
    unified "note.md" content content === ""

-- | 规格：旧文本是新文本的前缀时，补丁只含 ' ' 与 '+' 行，且 '+' 行数等于追加行数。
-- 背景：追加-only 是日志/档案追加写入的常见形态；出现 '-' 行代表前缀匹配被破坏。
-- 变更记录：- 2026-08-01: 补充 Diff 追加单调性的属性覆盖。
unifiedAppendOnly :: Property
unifiedAppendOnly =
  forAll genText $ \old ->
    forAll genText $ \extra ->
      let appended = Text.lines extra
          new =
            old
              <> ( if Text.null old || "\n" `Text.isSuffixOf` old
                     then ""
                     else "\n"
                 )
              <> extra
          output = unified "note.md" old new
          -- 输出形如 ["--- a/p", "+++ b/p", "@@ ...", 内容行...]；跳过两行文件头
          contentLines = filter isContent (drop 2 (Text.lines output))
          additions = length (filter (Text.isPrefixOf "+") contentLines)
          removals = length (filter (Text.isPrefixOf "-") contentLines)
          isContent line =
            Text.isPrefixOf " " line
              || Text.isPrefixOf "+" line
              || Text.isPrefixOf "-" line
       in counterexample (Text.unpack output) $
            if null appended
              then output === ""
              else
                ( all
                    (\line -> Text.isPrefixOf " " line || Text.isPrefixOf "+" line)
                    contentLines
                )
                  .&&. removals === 0
                  .&&. additions === length appended

-- | 规格：行序列不同时输出必然非空。
-- 背景：hunk 折叠可能把可见变更压没；空输出会掩盖真实差异（仅尾随换行差异不在行序列中体现，属行级 diff 的既有语义）。
-- 变更记录：- 2026-08-01: 补充 Diff 差异非空的属性覆盖。
unifiedDifferenceNonEmpty :: Property
unifiedDifferenceNonEmpty =
  forAll genText $ \old ->
    forAll genText $ \new ->
      let output = unified "note.md" old new
       in counterexample (Text.unpack output) $
            (Text.lines old /= Text.lines new) ==>
              output /= ""

-- | 受控文本生成器：避免无界输入拖慢属性测试。
genText :: Gen Text
genText =
  suchThat
    (Text.pack <$> listOf (elements ['a' .. 'd']))
    ((<= 12) . Text.length)
