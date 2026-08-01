module Yuki.N.DiffTest
  ( diffTests,
    diffMiddle,
    diffEnds,
    diffAll,
    diffSame,
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
    [ testCase "rewrites the middle with three lines of context" diffMiddle,
      testCase "splits far-apart changes into two hunks" diffEnds,
      testCase "replaces everything" diffAll,
      testCase "identical files produce an empty diff" diffSame,
      testProperty "same input produces an empty diff" unifiedIdenticalInput,
      testProperty "append-only changes add lines and never delete" unifiedAppendOnly,
      testProperty "different inputs always produce a non-empty diff" unifiedDifferenceNonEmpty
    ]

diffMiddle :: Assertion
diffMiddle =
  unified "f.txt" (numbered "l5") (numbered "X") @?= Text.unlines expected
 where
  numbered replacement = Text.unlines (["l1", "l2", "l3", "l4", replacement, "l6", "l7", "l8", "l9", "l10"] :: [Text])
  expected =
    [ "--- a/f.txt",
      "+++ b/f.txt",
      "@@ -2,7 +2,7 @@",
      " l2",
      " l3",
      " l4",
      "-l5",
      "+X",
      " l6",
      " l7",
      " l8"
    ]

diffEnds :: Assertion
diffEnds =
  unified "f.txt" (numbered "l1" "l10") (numbered "X" "Y") @?= Text.unlines expected
 where
  numbered head' last' = Text.unlines ([head', "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", last'] :: [Text])
  expected =
    [ "--- a/f.txt",
      "+++ b/f.txt",
      "@@ -1,4 +1,4 @@",
      "-l1",
      "+X",
      " l2",
      " l3",
      " l4",
      "@@ -7,4 +7,4 @@",
      " l7",
      " l8",
      " l9",
      "-l10",
      "+Y"
    ]

diffAll :: Assertion
diffAll =
  unified "f.txt" "a\nb\n" "x\ny\nz\n"
    @?= Text.unlines ["--- a/f.txt", "+++ b/f.txt", "@@ -1,2 +1,3 @@", "-a", "-b", "+x", "+y", "+z"]

diffSame :: Assertion
diffSame = unified "f.txt" "same\nfile\n" "same\nfile\n" @?= ""

unifiedIdenticalInput :: Property
unifiedIdenticalInput =
  forAll genText $ \content ->
    unified "note.md" content content === ""

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
                all
                  (\line -> Text.isPrefixOf " " line || Text.isPrefixOf "+" line)
                  contentLines
                  .&&. removals === 0
                  .&&. additions === length appended

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
