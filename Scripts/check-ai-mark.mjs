#!/usr/bin/env node
/**
 * COVA-142 显式标识扫描器（iOS 端）
 *
 * 验收判据不是「代码里写了字符串」，而是三条：
 *   ① 每一处呈现曲目/作品的界面，AI 标识命中 改前 0 → 改后 ≥1；
 *   ② 摘掉**任意一个**共享组件的标识，扫描必须**点名报出**受它影响的具体界面，
 *      而不是整体变绿/整体变红——只验「全都有了」验不出组件是否真被调用；
 *   ③ 文案一致：L1 必须是「AI 生成」四字，不许出现「AI 创作」。
 *
 * 用法：
 *   node Scripts/check-ai-mark.mjs                    # 扫工作树
 *   node Scripts/check-ai-mark.mjs --rev 17229f3      # 扫基线（改前）
 *   node Scripts/check-ai-mark.mjs --mutate <相对路径>  # 反证：真删该文件里的标识行、跑扫描、复原
 *
 * 退出码：0 全过 / 1 有界面缺标识或文案违规 / 2 用法或复原失败。
 *
 * 两个建模要点（不这么做必然假绿）：
 *   1. **先剥 Swift 注释再计数**。注释里为讲清规则也写了「AI 生成」，
 *      不剥会把说明文字当命中。
 *   2. **调用点与组件是两件事，必须分别验**。7 处走 `CovaListRow` 的界面，
 *      文件里没有任何徽标字面量——标识由组件渲染。所以每处声明
 *      `call`（自己文件里必须有的接线）+ `deps`（组件里必须有的渲染）。
 *      只验「组件里有渲染」会漏掉「某个调用点忘了传参」；
 *      只验「调用点传了参」会漏掉「组件把渲染删了」。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/* ---------- 文案常量（法条口径，不许自创） ---------- */
const L1 = 'AI 生成';
const L2 = '本作品由 Cova AI 生成';
const L3 = '本作品由 Cova AI（CovaLink）使用人工智能技术生成合成。';
const EN = 'AI-generated';
const FORBIDDEN = ['AI 创作', 'AI创作'];

const UI = 'Packages/CovaUI/Sources/CovaUI';
const FEAT = 'Packages/CovaFeature/Sources/CovaFeature';

/** 共享组件的接线契约：组件里必须同时有「接收 aiOrigin」与「渲染徽标」两件事。 */
const LISTROW_COMPONENT = `${UI}/CovaComponents.swift`;
const LISTROW_NEEDLES = ['aiOrigin != nil', 'AIOriginBadge(aiOrigin)'];

/**
 * 一处界面 = 用户能看见曲目/作品的呈现面。
 *  - call : 本文件里必须出现的接线片段（证明这一处真的把标识接上了）
 *  - deps : 标识来自共享组件时，组件文件里必须出现的渲染片段
 *  - kind : 'call' 走组件 / 'direct' 本文件直接渲染
 *  - level: 该处应达到的层级
 */
const SURFACES = [
  {
    id: 'ios-01', name: '曲库列表', file: `${FEAT}/LibraryView.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-02', name: '搜索结果列表', file: `${FEAT}/SearchTabView.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-03', name: '歌单详情曲目行', file: `${FEAT}/DetailViews.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-04', name: '曲目详情 sheet', file: `${FEAT}/DetailViews.swift`, level: 'L2', kind: 'direct',
    region: ['AIOriginNotice(.aiGenerated'], call: ['AIOriginNotice(.aiGenerated'],
  },
  {
    id: 'ios-05', name: '收藏列表（库曲 + 生成笔记合并 feed）', file: `${FEAT}/CollectionsViews.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-06', name: '艺人主页曲目', file: `${FEAT}/ArtistHomeView.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-07', name: '我的作品行', file: `${FEAT}/WorksListView.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-08', name: '创作台结果行', file: `${FEAT}/StudioCreateView.swift`, level: 'L1', kind: 'call',
    call: ['aiOrigin: .aiGenerated'], deps: [LISTROW_COMPONENT],
  },
  {
    id: 'ios-09a', name: '首页 · 最近播放卡（RecentPlayCard）', file: `${FEAT}/HomeView.swift`, level: 'L1', kind: 'direct',
    region: ['struct RecentPlayCard', 'struct HomeTrackCard'], call: ['AIOriginCoverBadge(.aiGenerated)'],
  },
  {
    id: 'ios-09b', name: '首页 · 新歌卡（HomeTrackCard）', file: `${FEAT}/HomeView.swift`, level: 'L1', kind: 'direct',
    region: ['struct HomeTrackCard', 'struct HomeWorkCard'], call: ['AIOriginCoverBadge(.aiGenerated)'],
  },
  {
    id: 'ios-09c', name: '首页 · 你的创作卡（HomeWorkCard）', file: `${FEAT}/HomeView.swift`, level: 'L1', kind: 'direct',
    region: ['struct HomeWorkCard', 'MARK: - 01 §6'], call: ['AIOriginCoverBadge(.aiGenerated)'],
  },
  {
    id: 'ios-10a', name: '迷你播放条（常驻）', file: `${FEAT}/PlayerViews.swift`, level: 'L1', kind: 'direct',
    region: ['public struct MiniPlayerView', 'public struct PlayerView'], call: ['AIOriginBadge(.aiGenerated)'],
  },
  {
    id: 'ios-10b', name: '全屏播放器曲目信息区', file: `${FEAT}/PlayerViews.swift`, level: 'L2', kind: 'direct',
    region: ['public struct PlayerView', null], call: ['AIOriginNotice(.aiGenerated'],
  },
  {
    id: 'ios-11', name: 'AI 会话候选卡（双 Demo）', file: `${FEAT}/AISessionDetailView.swift`, level: 'L1', kind: 'direct',
    region: ['func candidateCard(', 'func candidateCover('], call: ['AIOriginBadge(.aiGenerated)'],
  },
  {
    id: 'ios-12', name: '分享歌单页曲目列表', file: `${FEAT}/SharedPlaylistView.swift`, level: 'L1', kind: 'direct',
    region: ['private func trackList', null], call: ['AIOriginBadge(.aiGenerated)'],
  },
  {
    id: 'ios-13', name: '创作台 · 选择作品源列表', file: `${FEAT}/StudioCreateView.swift`, level: 'L1', kind: 'direct',
    region: ['List(session.studioCreateSources', 'static func operationLabel'], call: ['AIOriginBadge(.aiGenerated)'],
  },
  {
    id: 'ios-14', name: '作品歌词面板', file: `${FEAT}/WorksListView.swift`, level: 'L2', kind: 'direct',
    region: ['private func lyricsPanel', null], call: ['AIOriginNotice(.aiGenerated'],
  },
];

/* ---------- 剥注释 ---------- */
function stripComments(text) {
  let out = text.replace(/\/\*[\s\S]*?\*\//g, '');
  // 行注释：只剥 `//` 到行尾，保留 `https://` 这类（先占位再还原）
  out = out.replace(/https?:\/\//g, '\u0000URL\u0000');
  out = out.replace(/(^|[^:])\/\/[^\n]*/g, '$1');
  return out.replace(/\u0000URL\u0000/g, 'https://');
}

function readSource(rel, rev) {
  if (rev) return execFileSync('git', ['show', `${rev}:${rel}`], { cwd: ROOT, encoding: 'utf8' });
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

function sliceRegion(text, region) {
  if (!region) return text;
  const [from, to] = region;
  const start = text.indexOf(from);
  if (start < 0) return ''; // 锚点找不到 = 结构变了 ⇒ fail-closed 按缺标识处理
  if (!to) return text.slice(start);
  const end = text.indexOf(to, start);
  return end < 0 ? text.slice(start) : text.slice(start, end);
}

function countAll(text, needles) {
  let total = 0;
  const per = {};
  for (const n of needles) {
    const hits = text.split(n).length - 1;
    per[n] = hits;
    total += hits;
  }
  return { total, per };
}

function evaluate(rev) {
  const rows = [];
  for (const s of SURFACES) {
    const raw = readSource(s.file, rev);
    const body = stripComments(sliceRegion(raw, s.region || null));
    // 命中口径：本文件里出现的**接线符号**次数（`aiOrigin: .aiGenerated` / `AIOriginBadge(` …）。
    // 不数字面量「AI 生成」——字面量只在 AIMark.swift 里有一份（单一来源），
    // 各调用点用符号，把「有没有接线」和「文案写没写对」当成两件事分别验。
    const own = countAll(body, s.call || []);

    // 接线：声明的每个符号都必须出现（空串是占位，跳过）
    const callHits = (s.call || []).map((n) => ({ needle: n, hits: body.split(n).length - 1, empty: n === '' }));
    const callOk = callHits.every((c) => c.empty || c.hits > 0);

    // 依赖：共享组件里的渲染片段
    const depDetail = [];
    let depOk = true;
    for (const dep of s.deps || []) {
      const depBody = stripComments(readSource(dep, rev));
      const need = dep === LISTROW_COMPONENT ? LISTROW_NEEDLES : [];
      const missing = need.filter((n) => !depBody.includes(n));
      depDetail.push({ dep, missing });
      if (missing.length) depOk = false;
    }

    // 层级：L2 界面必须用整句组件（AIOriginNotice），L1 用徽标族。
    // 同时校验组件侧的文案常量确实是 L2 —— 防止有人把 Notice 改成渲染 L1。
    const textOk = s.level === 'L2'
      ? (body.includes('AIOriginNotice(') && stripComments(readSource(`${UI}/AIMark.swift`, rev)).includes('level2 = "本作品由 Cova AI 生成"'))
      : true;

    const total = own.total;
    rows.push({
      id: s.id, name: s.name, file: s.file + (s.region ? `（片段 ${s.region[0]}）` : ''),
      level: s.level, kind: s.kind, own: total, callOk, depDetail, depOk, textOk,
      ok: total > 0 && callOk && depOk && textOk,
    });
  }
  return rows;
}

/* ---------- 反证 ---------- */
function mutate(target) {
  const abs = path.join(ROOT, target);
  const original = fs.readFileSync(abs, 'utf8');
  const before = crypto.createHash('sha256').update(original).digest('hex');

  const MARK = /AIOrigin(Badge|Notice|CoverBadge)|aiOrigin: \.aiGenerated/;
  const stripped = original.split('\n').filter((line) => !MARK.test(line)).join('\n');
  if (stripped === original) {
    console.error(`✖ 反证失败：${target} 里找不到可删除的标识行`);
    process.exit(2);
  }

  fs.writeFileSync(abs, stripped);
  let rows;
  try {
    rows = evaluate(null);
  } finally {
    fs.writeFileSync(abs, original);
  }

  const afterHash = crypto.createHash('sha256').update(fs.readFileSync(abs, 'utf8')).digest('hex');
  if (before !== afterHash) {
    console.error(`✖ 复原失败：${target} sha256 ${before} → ${afterHash}，请手工检查`);
    process.exit(2);
  }

  const missing = rows.filter((r) => !r.ok);
  console.log(`\n== 反证：摘掉 ${target} 里的标识 ==`);
  console.log(`复原校验：sha256 ${before.slice(0, 12)} 一致 ✔`);
  console.log(`缺标识界面：${missing.length} / ${rows.length}`);
  for (const r of missing) {
    const why = [];
    if (r.own === 0) why.push('命中 0');
    if (!r.callOk) why.push('调用点未接线');
    if (!r.depOk) why.push('组件渲染缺失');
    console.log(`  ✖ ${r.id} ${r.name}  ← ${why.join('、')}（${r.file}）`);
  }
  const ok = rows.filter((r) => r.ok);
  console.log(`仍命中：${ok.length} / ${rows.length}（${ok.map((r) => r.id).join(' ') || '无'}）`);
  return missing.length;
}

/* ---------- 主流程 ---------- */
const argv = process.argv.slice(2);
const revIdx = argv.indexOf('--rev');
const rev = revIdx >= 0 ? argv[revIdx + 1] : null;
const mutIdx = argv.indexOf('--mutate');

if (mutIdx >= 0) process.exit(mutate(argv[mutIdx + 1]) > 0 ? 0 : 1);

const rows = evaluate(rev);
console.log(`\n== iOS · AI 生成显式标识扫描（${rev ? `git ${rev}` : '工作树'}）==`);
console.log(`${'编号'.padEnd(10)}${'命中'.padEnd(6)}${'层级'.padEnd(6)}${'形态'.padEnd(8)}界面`);
for (const r of rows) {
  const mark = r.ok ? '✔' : '✖';
  console.log(`${r.id.padEnd(10)}${String(r.own).padEnd(6)}${r.level.padEnd(6)}${(r.kind === 'call' ? '组件接线' : '本文件').padEnd(8)}${mark} ${r.name}`);
}

/* 文案一致性：禁词只在「标识语境」判违规；
   非标识语境（会员权益表、清理说明等既有文案）如实列出但不拦。
   依据：客户端不在本单自创/改动营销文案，词表收口归 142 统一裁定。 */
const MARK_CONTEXT = /AIMarkText|AIOrigin|AI 生成|本作品由 Cova AI/;
const forbiddenHits = [];
const nonMarkHits = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['.git', '.build', '.swiftpm', 'docs', 'design'].includes(entry.name)) continue;
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) { walk(abs); continue; }
    if (!entry.name.endsWith('.swift')) continue;
    const rel = path.relative(ROOT, abs);
    if (rel === 'Scripts/check-ai-mark.mjs') continue;
    const lines = stripComments(fs.readFileSync(abs, 'utf8')).split('\n');
    for (const bad of FORBIDDEN) {
      lines.forEach((line, i) => {
        if (!line.includes(bad)) return;
        // 禁词常量自身的定义行不算违规（它就是「禁词的唯一定义处」，
        // 和扫描脚本里的常量同性质；判它违规等于让守卫不能存在）。
        if (line.includes('forbidden =')) return;
        const at = `${rel}:${i + 1}: ${bad}｜${line.trim()}`;
        if (MARK_CONTEXT.test(line)) forbiddenHits.push(at); else nonMarkHits.push(at);
      });
    }
  }
}
walk(path.join(ROOT, 'Packages'));
walk(path.join(ROOT, 'Cova'));

const missing = rows.filter((r) => !r.ok);
const totalHits = rows.reduce((s, r) => s + r.own, 0);
console.log(`\n界面总数：${rows.length}`);
console.log(`达标：${rows.length - missing.length}    缺标识/不达标：${missing.length}`);
console.log(`本文件标识命中总计：${totalHits}`);
console.log(`禁用词「AI 创作」（标识语境）：${forbiddenHits.length === 0 ? '0（合规）' : `${forbiddenHits.length} 处`}`);
for (const f of forbiddenHits) console.log(`  ✖ ${f}`);
console.log(`非标识语境的「AI 创作」：${nonMarkHits.length} 处（不计违规，列出备查）`);
for (const f of nonMarkHits) console.log(`  · ${f}`);

if (missing.length || forbiddenHits.length) { console.log('\n✖ 不通过'); process.exit(1); }
console.log('\n✔ 通过');
