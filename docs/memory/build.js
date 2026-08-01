#!/usr/bin/env node
// 将 Mem/*.md 渲染为单一 HTML 阅读文件
// 流程：md 源 → 注入标题锚点 → marked CLI 转换 → 拼装（目录 + 样式）
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const os = require('os');

const dir = __dirname;
const order = ['README.md', '01-印象.md', '02-工作记忆.md', '03-长期记忆.md', '04-生命周期.md', '05-演进方向.md'];
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-html-'));
const markedBin = 'npx';

function slugify(text) {
  return text
    .replace(/[`*_~[\]()]/g, '')
    .trim()
    .replace(/\s+/g, '-')
    .replace(/[^\w\u4e00-\u9fa5-]/g, '');
}
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const docs = order.map((file) => {
  const src = fs.readFileSync(path.join(dir, file), 'utf8');
  const headings = [];
  const body = src.split('\n').map((line) => {
    const m = /^(#{1,4})\s+(.*)$/.exec(line);
    if (m) {
      const slug = slugify(m[2]);
      headings.push({ level: m[1].length, text: m[2], slug });
      return `${m[1]} <a id="${file}-${slug}"></a>${m[2]}`;
    }
    return line;
  });
  const mdPath = path.join(tmpDir, file.replace('.md', '.md'));
  fs.writeFileSync(mdPath, body.join('\n'));
  const html = execFileSync(markedBin, ['-y', 'marked', '--gfm', '-i', mdPath], { encoding: 'utf8' });
  return { file, headings, html };
});

// ---- 目录 ----
let toc = '<nav class="toc"><div class="toc-title">目录</div>';
for (const doc of docs) {
  const first = doc.headings.find((h) => h.level === 1);
  toc += `<div class="toc-file"><a href="#${doc.file}-${first.slug}">${escapeHtml(first.text)}</a></div><ul>`;
  for (const h of doc.headings) {
    if (h.level === 1) continue;
    toc += `<li class="toc-${h.level}"><a href="#${doc.file}-${h.slug}">${escapeHtml(h.text)}</a></li>`;
  }
  toc += '</ul>';
}
toc += '</nav>';

// ---- 正文 ----
let articles = '';
for (const doc of docs) {
  articles += `<article data-file="${doc.file}">\n${doc.html}\n</article>\n`;
}

const css = `
:root {
  --paper: #eef0e7;
  --paper-deep: #d0dac6;
  --ink: #1e211c;
  --ink-soft: #3a3e36;
  --quiet: #575b4d;
  --line: rgba(30, 33, 28, 0.14);
  --accent: #3c4a37;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background: var(--paper);
  color: var(--ink);
  font-family: "Songti SC", "Noto Serif CJK SC", "Source Han Serif SC", "STSong", Georgia, serif;
  font-size: 16.5px;
  line-height: 1.78;
}
.wrap { max-width: 880px; margin: 0 auto; padding: 0 28px 120px; }
header.masthead {
  text-align: center;
  padding: 72px 24px 28px;
  border-bottom: 1px solid var(--line);
  margin-bottom: 40px;
}
header.masthead h1 { font-size: 30px; margin: 0 0 10px; letter-spacing: 0.12em; }
header.masthead .sub { color: var(--quiet); font-size: 14px; letter-spacing: 0.06em; }
header.masthead .seal {
  display: inline-block;
  width: 14px; height: 14px;
  background: var(--accent);
  margin-right: 10px;
  vertical-align: 1px;
}
nav.toc {
  background: var(--paper-deep);
  padding: 26px 30px;
  margin: 0 0 48px;
  border-radius: 2px;
}
nav.toc .toc-title { font-weight: 700; letter-spacing: 0.2em; font-size: 14px; margin-bottom: 14px; }
nav.toc .toc-file { margin: 12px 0 4px; font-weight: 700; }
nav.toc .toc-file a { color: var(--ink); }
nav.toc ul { list-style: none; margin: 2px 0 6px; padding-left: 0; }
nav.toc li { margin: 3px 0; }
nav.toc li.toc-3 { padding-left: 1.2em; font-size: 14.5px; }
nav.toc li.toc-4 { padding-left: 2.4em; font-size: 14px; color: var(--quiet); }
nav.toc a { color: var(--ink-soft); text-decoration: none; }
nav.toc a:hover { color: var(--accent); text-decoration: underline; }
article { margin-bottom: 72px; }
article + article { border-top: 1px solid var(--line); padding-top: 56px; }
article h1 { font-size: 25px; margin: 0 0 18px; padding-bottom: 10px; border-bottom: 2px solid var(--ink); }
article h2 { font-size: 20px; margin-top: 2em; padding-bottom: 4px; border-bottom: 1px solid var(--line); }
article h3 { font-size: 17px; margin-top: 1.8em; color: var(--ink-soft); }
article h4 { font-size: 15.5px; margin-top: 1.6em; color: var(--ink-soft); }
article p { margin: 0.85em 0; }
article a { color: var(--accent); text-decoration: none; }
article a:hover { text-decoration: underline; }
article strong { font-weight: 700; }
article ul, article ol { padding-left: 1.6em; }
article li { margin: 0.35em 0; }
article li > ul, article li > ol { margin: 0.3em 0; }
article blockquote {
  margin: 1.2em 0;
  padding: 0.6em 1.2em;
  border-left: 3px solid var(--accent);
  background: rgba(60, 74, 55, 0.06);
  color: var(--ink-soft);
}
article blockquote p { margin: 0.4em 0; }
article code {
  font-family: "SF Mono", Menlo, Consolas, monospace;
  font-size: 0.86em;
  background: rgba(30, 33, 28, 0.07);
  padding: 0.12em 0.4em;
  border-radius: 3px;
}
article pre {
  background: #23261f;
  color: #d8dccf;
  padding: 16px 20px;
  border-radius: 3px;
  overflow-x: auto;
  line-height: 1.6;
  font-size: 13.5px;
}
article pre code { background: none; padding: 0; color: inherit; font-size: inherit; }
article table {
  border-collapse: collapse;
  width: 100%;
  margin: 1.2em 0;
  font-size: 14.5px;
  line-height: 1.6;
}
article th, article td {
  border: 1px solid var(--line);
  padding: 7px 12px;
  text-align: left;
  vertical-align: top;
}
article th { background: var(--paper-deep); font-weight: 700; }
article tr:nth-child(even) td { background: rgba(30, 33, 28, 0.03); }
article hr { border: none; border-top: 1px solid var(--line); margin: 2.2em 0; }
.backtop {
  position: fixed;
  right: 24px;
  bottom: 24px;
  background: var(--ink);
  color: var(--paper);
  border: none;
  border-radius: 2px;
  padding: 8px 14px;
  font-size: 13px;
  cursor: pointer;
  opacity: 0.75;
}
.backtop:hover { opacity: 1; }
@media (max-width: 640px) {
  body { font-size: 15px; }
  header.masthead { padding-top: 44px; }
  .wrap { padding: 0 16px 100px; }
}
@media print {
  nav.toc, .backtop { display: none; }
  article + article { border-top: none; padding-top: 0; page-break-before: always; }
}
`;

const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>YUKI.N 记忆与印象设计</title>
<style>${css}</style>
</head>
<body>
<div class="wrap">
<header class="masthead">
  <h1><span class="seal"></span>YUKI.N 记忆与印象设计</h1>
  <div class="sub">印象 · 工作记忆 · 任务档案 · 经验流 · 记忆库 — 全部设计文档（合并阅读版）</div>
</header>
${toc}
${articles}
</div>
<button class="backtop" onclick="window.scrollTo({top:0,behavior:'smooth'})">回到顶部</button>
</body>
</html>
`;

const out = path.join(dir, 'Mem-记忆与印象设计.html');
fs.writeFileSync(out, html);
console.log('written:', out, fs.statSync(out).size, 'bytes');
