/* Sykli Workbench — static SPA.
   All presentation (color, glyph, label) is derived from `status` + `identityType`
   through the grammar maps below. Nothing presentational is stored server-side. */

'use strict';

/* ---------------------------------------------------------------- state */

var S = {
  doc: null,          // /api/state .data document
  fetchError: null,   // string when the state fetch failed
  view: 'graph',      // active tab
  selected: null,     // {kind: node|member|work|run, id} | null
  log: [],            // activity entries prepended after gate actions
  gateOverrides: {},  // gateId -> 'approved' | 'rejected'
  gateError: null,    // inline error under gate actions
  reasonOpen: false,  // Add-reason input visible
  rawOpen: false      // Raw output expanded
};

/* ------------------------------------------------------- grammar maps */

var COLORS = {
  green: '#5E8C6A', red: '#B14A3E', amber: '#BE8E36',
  cyan: '#2B7B83', grey: '#9C9A92',
  ink: '#1C1C1A', body: '#3A3A36', mut: '#6E6D67', faint: '#9A988F'
};

/* state -> semantic color (the single source of truth) */
var STATE_KEY = {
  passed: 'green', valid: 'green', complete: 'green', online: 'green',
  ok: 'green', approved: 'green', cleared: 'green', kept: 'green', pass: 'green',
  failed: 'red', blocked: 'red', fail: 'red', rejected: 'red',
  criteria_failure: 'red', violated: 'red', invalid: 'red',
  waiting: 'amber', waiting_gate: 'amber', partial: 'amber', wait: 'amber',
  unverified: 'amber',
  active: 'cyan', running: 'cyan',
  skipped: 'grey', away: 'grey', skip: 'grey', none: 'grey',
  pending: 'grey', unsupported: 'grey', unknown: 'grey', offline: 'grey'
};

function scol(state) {
  var k = STATE_KEY[state];
  return k ? COLORS[k] : COLORS.mut;
}

/* identityType / node type -> geometry (always ink) */
var GLYPH = {
  task: 'glyph-task', gate: 'glyph-gate',
  human: 'glyph-human', agent: 'glyph-agent',
  daemon: 'glyph-daemon', ci: 'glyph-ci', reviewer: 'glyph-human'
};

function glyph(type) {
  return '<span class="glyph ' + (GLYPH[type] || 'glyph-task') + '"></span>';
}

/* ----------------------------------------------------------- helpers */

function esc(v) {
  return String(v === null || v === undefined ? '' : v).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

function runLabel(id) {
  if (id === null || id === undefined) return '—';
  var m = /^run-(.+)$/.exec(String(id));
  return m ? '#' + m[1] : String(id);
}

function nowHM() {
  var d = new Date();
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return p(d.getHours()) + ':' + p(d.getMinutes());
}

function isSel(kind, id) {
  return S.selected && S.selected.kind === kind && String(S.selected.id) === String(id);
}

function selAttrs(kind, id) {
  return ' data-sel-kind="' + esc(kind) + '" data-sel-id="' + esc(id) + '"';
}

function graphNodes() { return (S.doc && S.doc.graph && S.doc.graph.nodes) || []; }
function graphEdges() { return (S.doc && S.doc.graph && S.doc.graph.edges) || []; }

function gateStatus(g) { return S.gateOverrides[g.id] || g.status || 'waiting'; }

function gateById(id) {
  var gs = (S.doc.gates || []);
  for (var i = 0; i < gs.length; i++) if (gs[i].id === id) return gs[i];
  return null;
}

function currentActor() {
  var actor = (S.doc && S.doc.currentActor) || {};
  return {
    ref: actor.ref || 'member:local',
    label: actor.name || actor.id || actor.ref || 'local'
  };
}

/* effective node status (gate nodes follow local gate overrides) */
function nodeStatus(n) {
  if (n.type === 'gate') {
    var g = gateById(n.id);
    return g ? gateStatus(g) : (S.gateOverrides[n.id] || n.status);
  }
  return n.status;
}

function workTitle(id) {
  var ws = (S.doc.workItems || []);
  for (var i = 0; i < ws.length; i++) if (ws[i].id === id) return ws[i].title;
  return id;
}

/* edge state: broken if the source failed, ran if both ends executed,
   inactive otherwise (downstream that never ran). */
function incomingEdge(nodeId) {
  var edges = graphEdges(), nodes = graphNodes();
  var e = null;
  for (var i = 0; i < edges.length; i++) if (edges[i].to === nodeId) { e = edges[i]; break; }
  if (!e) return null;
  var src = null, dst = null;
  for (var j = 0; j < nodes.length; j++) {
    if (nodes[j].id === e.from) src = nodes[j];
    if (nodes[j].id === nodeId) dst = nodes[j];
  }
  var ss = src ? nodeStatus(src) : null;
  var ds = dst ? nodeStatus(dst) : null;
  var executed = { passed: 1, failed: 1, cached: 1, running: 1 };
  var kind;
  if (ss === 'failed') kind = 'broken';
  else if (executed[ss] && executed[ds]) kind = 'ran';
  else kind = 'inactive';
  return { kind: kind };
}

var EDGE_ARROW = { ran: COLORS.faint, broken: COLORS.red, inactive: '#BFBDB4' };

/* -------------------------------------------------------------- boot */

function boot() {
  fetch('/api/state')
    .then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    })
    .then(function (j) {
      if (!j || j.ok !== true || !j.data) {
        throw new Error((j && j.error && j.error.message) || 'malformed state envelope');
      }
      S.doc = j.data;
      render();
    })
    .catch(function (e) {
      S.fetchError = String((e && e.message) || e);
      render();
    });
}

function fit() {
  var f = document.getElementById('frame');
  if (!f) return;
  var s = Math.min(window.innerWidth / 1280, window.innerHeight / 760);
  f.style.transform = 'scale(' + s + ')';
}
window.addEventListener('resize', fit);

/* ------------------------------------------------------------ render */

function render() {
  var root = document.getElementById('frame');
  if (S.fetchError || !S.doc) {
    root.innerHTML = errorHTML();
  } else {
    root.innerHTML = stripHTML() + tabsHTML() + centerHTML() + railHTML();
  }
  fit();
}

function errorHTML() {
  return '' +
    '<div class="err-frame"><div class="err-box">' +
      '<div class="err-title">SYKLI WORKBENCH</div>' +
      '<div class="err-line">could not load state from /api/state</div>' +
      '<div class="err-detail">' + esc(S.fetchError || 'no state document') + '</div>' +
      '<div class="err-hint">start the workbench server in this repo, then reload.</div>' +
    '</div></div>';
}

/* -------------------------------------------------------- status strip */

function stripHTML() {
  var d = S.doc;
  var repo = d.repo || {};
  var team = d.team || {};
  var run = d.latestRun || {};
  var contract = d.contract || {};

  var cells = [];
  var cVal = contract.valid ? 'valid' : 'invalid';
  cells.push({ label: 'CONTRACT', value: cVal, color: scol(cVal) });
  cells.push({
    label: 'RUN',
    value: (runLabel(run.id) + ' ' + (run.status || '')).trim() || '—',
    color: scol(run.status)
  });
  cells.push({ label: 'EVIDENCE', value: run.evidenceStatus || '—', color: scol(run.evidenceStatus) });

  var g = (d.gates || [])[0];
  if (g) {
    var gs = gateStatus(g);
    var gv = gs === 'approved' ? 'cleared' : gs;
    cells.push({ label: 'GATE', value: gv, color: scol(gv) });
  } else {
    cells.push({ label: 'GATE', value: '—', color: COLORS.mut });
  }
  cells.push({
    label: 'TEAM',
    value: team.online !== undefined ? team.online + ' online' : '—',
    color: COLORS.cyan
  });

  var cellsHTML = cells.map(function (c) {
    return '<div class="strip-cell">' +
      '<span class="cell-label">' + esc(c.label) + '</span>' +
      '<span class="cell-value" style="color:' + c.color + '">' + esc(c.value) + '</span>' +
    '</div>';
  }).join('');

  return '' +
    '<header class="strip">' +
      '<div class="strip-brand">' +
        '<img src="./fs-mark.png" alt="False Systems">' +
        '<span class="wordmark">SYKLI</span>' +
      '</div>' +
      '<div class="strip-repo">' +
        '<span class="repo-name">' + esc(repo.name || '—') + '</span>' +
        '<span class="repo-branch">' + esc(repo.branch || '') + (repo.dirty ? ' · dirty' : '') + '</span>' +
      '</div>' +
      '<div class="strip-team">' +
        '<span class="team-glyph"></span>' +
        '<span>team <strong>' + esc(team.id || '—') + '</strong></span>' +
      '</div>' +
      '<div class="strip-cells">' + cellsHTML + '</div>' +
    '</header>';
}

/* --------------------------------------------------------------- tabs */

function failedNodeCount() {
  return graphNodes().filter(function (n) { return n.status === 'failed'; }).length;
}

function tabsHTML() {
  var d = S.doc;
  var defs = [
    { v: 'graph', label: 'Graph', count: null },
    { v: 'runs', label: 'Runs', count: (d.evidence || []).length },
    { v: 'failures', label: 'Failures', count: failedNodeCount() },
    { v: 'work', label: 'Work', count: (d.workItems || []).length },
    { v: 'gates', label: 'Gates', count: (d.gates || []).length },
    { v: 'evidence', label: 'Evidence', count: (d.evidence || []).length },
    { v: 'agent', label: 'Agent', count: (d.agentCalls || []).length },
    { v: 'activity', label: 'Activity', count: null }
  ];
  return '<nav class="tabs">' + defs.map(function (t) {
    var active = S.view === t.v;
    return '<div class="tab' + (active ? ' active' : '') + '" data-tab="' + t.v + '">' +
      '<span>' + esc(t.label) + '</span>' +
      (t.count !== null && t.count !== undefined
        ? '<span class="tab-count">' + esc(t.count) + '</span>' : '') +
    '</div>';
  }).join('') + '</nav>';
}

/* -------------------------------------------------------------- center */

function centerTitles() {
  var d = S.doc;
  var run = d.latestRun || {};
  var contract = d.contract || {};
  var team = d.team || {};
  var primary = primaryFailureNode();
  var t = {
    graph:    ['EXECUTION GRAPH', 'declared structure + runtime state', 'contract v' + (contract.version || '?')],
    runs:     ['RUNS', 'recorded executions', 'latest ' + runLabel(run.id)],
    failures: ['FAILURE', 'run ' + runLabel(run.id), primary ? (primary.failureClass || 'failed') : 'none'],
    work:     ['WORK', 'team execution intents', (d.workItems || []).length + ' active'],
    gates:    ['GATES', 'permission-aware approvals', waitingGateCount() + ' waiting'],
    evidence: ['EVIDENCE', 'semantic run records', (d.evidence || []).length + ' runs'],
    agent:    ['AGENT CONSOLE', 'audit of agent tool calls', agentCallers()],
    activity: ['ACTIVITY', 'factual execution history', team.id || '']
  };
  return t[S.view] || t.graph;
}

function waitingGateCount() {
  return (S.doc.gates || []).filter(function (g) { return gateStatus(g) === 'waiting'; }).length;
}

function agentCallers() {
  var seen = {}, out = [];
  (S.doc.agentCalls || []).forEach(function (a) {
    if (a.caller && !seen[a.caller]) { seen[a.caller] = 1; out.push(a.caller); }
  });
  return out.join(' · ');
}

function primaryFailureNode() {
  var id = (S.doc.latestRun || {}).primaryFailureNodeId;
  if (!id) return null;
  var ns = graphNodes();
  for (var i = 0; i < ns.length; i++) if (ns[i].id === id) return ns[i];
  return null;
}

function centerHTML() {
  var t = centerTitles();
  var body;
  switch (S.view) {
    case 'graph': body = graphHTML(); break;
    case 'failures': body = failuresHTML(); break;
    case 'work': body = workHTML(); break;
    case 'gates': body = gatesHTML(); break;
    case 'runs':
    case 'evidence': body = runsHTML(); break;
    case 'agent': body = agentHTML(); break;
    case 'activity': body = activityHTML(); break;
    default: body = graphHTML();
  }
  return '' +
    '<main class="center">' +
      '<div class="center-head">' +
        '<span class="head-left">' + esc(t[0]) + ' · ' + esc(t[1]) + '</span>' +
        '<span class="head-right">' + esc(t[2]) + '</span>' +
      '</div>' +
      '<div class="center-body' + (S.view === 'graph' ? ' is-graph' : '') + '">' + body + '</div>' +
    '</main>';
}

/* ------------------------------------------------------- graph (hero) */

function nodeMetaLines(n) {
  var st = nodeStatus(n);
  var m = [];
  if (n.type === 'gate') {
    m.push({ t: (n.approvers || []).join(' / ') || '—', c: COLORS.mut });
    m.push({
      t: 'run ' + runLabel(n.runId) + ' · evidence ' +
         (n.evidence === 'complete' ? '✓' : (n.evidence || '—')),
      c: COLORS.faint
    });
  } else if (st === 'failed') {
    m.push({ t: n.failureClass || 'failed', c: COLORS.red });
    m.push({
      t: (n.requester || '—') + ' → ' + (n.executor || '—') +
         (n.duration ? ' · ' + n.duration : ''),
      c: COLORS.mut
    });
  } else if (st === 'skipped' || st === 'blocked') {
    m.push({ t: n.blockedBy ? 'blocked by ' + n.blockedBy : (n.reason || st), c: COLORS.faint });
    m.push({ t: 'evidence ' + (n.evidence || 'none'), c: COLORS.grey });
  } else {
    m.push({ t: 'ran on ' + (n.executor || '—'), c: COLORS.mut });
    m.push({ t: (n.duration || '—') + ' · evidence ' + (n.evidence || '—'), c: COLORS.faint });
  }
  if (n.mandateOutcome) {
    m.push({ t: 'MANDATE ' + n.mandateOutcome, c: scol(n.mandateOutcome) });
  }
  return m;
}

function graphHTML() {
  var nodes = graphNodes();
  var tiles = nodes.map(function (n, i) {
    var st = nodeStatus(n);
    var col = scol(st);
    var selected = isSel('node', n.id);
    var e = incomingEdge(n.id);

    var conn = '';
    if (e) {
      conn = '<div class="gconn"><div class="gconn-inner">' +
        '<div class="gconn-line edge-' + e.kind + '"></div>' +
        '<span class="gconn-arrow" style="border-color:' + EDGE_ARROW[e.kind] + '"></span>' +
      '</div></div>';
    }

    var meta = nodeMetaLines(n).map(function (l) {
      return '<span style="color:' + l.c + '">' + esc(l.t) + '</span>';
    }).join('');

    return '<div class="gnode-wrap">' + conn +
      '<div class="gnode' + (selected ? ' selected' : '') + '"' + selAttrs('node', n.id) + '>' +
        '<div class="gnode-head">' +
          '<span class="gnode-rank">' + String(i + 1).padStart(2, '0') + '</span>' +
          glyph(n.type) +
          '<span class="dot' + (st === 'running' ? ' pulse' : '') + '" style="background:' + col + '"></span>' +
        '</div>' +
        '<div class="gnode-body">' +
          '<span class="gnode-id">' + esc(n.id) + '</span>' +
          '<div class="gnode-typeline">' +
            '<span class="gnode-type">' + esc(n.type) + '</span>' +
            '<span class="gnode-status" style="color:' + col + '">' + esc(st) + '</span>' +
          '</div>' +
          '<div class="gnode-meta">' + meta + '</div>' +
        '</div>' +
      '</div>' +
    '</div>';
  }).join('');

  return '' +
    '<div class="graph-wrap">' +
      '<div class="graph-toolbar">' +
        '<span class="flow-label">EXECUTION FLOW · LEFT → RIGHT</span>' +
        '<div class="edge-legend">' +
          '<span class="lg"><span class="lg-line edge-ran"></span>ran</span>' +
          '<span class="lg"><span class="lg-line edge-broken"></span>broken</span>' +
          '<span class="lg"><span class="lg-line edge-inactive"></span>inactive</span>' +
        '</div>' +
      '</div>' +
      '<div class="canvas"><div class="flow">' + tiles + '</div></div>' +
    '</div>';
}

/* ----------------------------------------------------------- failures */

function failuresHTML() {
  var run = S.doc.latestRun || {};
  var primary = primaryFailureNode();
  if (!primary && failedNodeCount() === 0) {
    return '<div class="fail-wrap"><div class="knows-label">NO FAILURES</div>' +
      '<div class="knows-row"><span class="dash">—</span>' +
      '<span class="txt">The latest run has no failed tasks.</span></div></div>';
  }
  var downstream = graphNodes().filter(function (n) {
    return (n.status === 'skipped' || n.status === 'blocked') &&
           primary && n.blockedBy === primary.id;
  }).map(function (n) { return n.id; });

  var retry = primary && primary.retryHint === 'no' ? 'probably not useful'
            : primary && primary.retryHint ? primary.retryHint : '—';

  var knows = [];
  if (primary) {
    knows.push('The task ran. The command completed.');
    knows.push('The declared success criteria did not pass.');
    downstream.forEach(function (id) {
      knows.push('Downstream ' + id + ' was skipped because ' + primary.id + ' failed.');
    });
    if (primary.mandateOutcome) {
      knows.push('Mandate outcome: ' + primary.mandateOutcome + '.');
    }
  }

  return '' +
    '<div class="fail-wrap">' +
      '<div class="fail-title-row">' +
        '<span class="fail-mark">×</span>' +
        '<span class="fail-title">Run ' + esc(runLabel(run.id)) + ' failed</span>' +
      '</div>' +
      '<div class="fact-grid">' +
        '<div class="fact-cell"><div class="fact-label">PRIMARY FAILURE</div>' +
          '<div class="fact-value">' + esc(primary ? primary.id : '—') + '</div></div>' +
        '<div class="fact-cell"><div class="fact-label">FAILURE CLASS</div>' +
          '<div class="fact-value" style="color:' + COLORS.red + '">' +
          esc(primary ? (primary.failureClass || 'failed') : '—') + '</div></div>' +
        '<div class="fact-cell"><div class="fact-label">RETRY</div>' +
          '<div class="fact-value plain">' + esc(retry) + '</div></div>' +
        '<div class="fact-cell"><div class="fact-label">DOWNSTREAM SKIPPED</div>' +
          '<div class="fact-value" style="color:' + COLORS.grey + '">' +
          esc(downstream.join(', ') || '—') + '</div></div>' +
      '</div>' +
      '<div class="knows-label">WHAT SYKLI KNOWS</div>' +
      knows.map(function (k) {
        return '<div class="knows-row"><span class="dash">—</span>' +
          '<span class="txt">' + esc(k) + '</span></div>';
      }).join('') +
      '<div class="fail-next">' +
        '<div class="next-label">NEXT</div>' +
        '<div class="next-text">Inspect contract and changed files.</div>' +
      '</div>' +
    '</div>';
}

/* ---------------------------------------------------------------- work */

function workHTML() {
  var items = S.doc.workItems || [];
  return '<div class="card-col">' + items.map(function (w) {
    var selected = isSel('work', w.id);
    return '<div class="card' + (selected ? ' selected' : '') + '"' + selAttrs('work', w.id) + '>' +
      '<div class="card-head">' +
        '<span class="card-title">' + esc(w.title) + '</span>' +
        '<span class="card-status" style="color:' + scol(w.status) + '">' + esc(w.status) + '</span>' +
      '</div>' +
      '<div class="card-facts">' +
        '<span>owner · ' + esc(w.owner || '—') + '</span>' +
        '<span>reviewer · ' + esc(w.reviewer || '—') + '</span>' +
        '<span>runs · ' + esc(w.runs !== undefined ? w.runs : '—') + '</span>' +
        (w.reason ? '<span style="color:' + scol(w.reason) + '">' + esc(w.reason) + '</span>' : '') +
      '</div>' +
    '</div>';
  }).join('') + '</div>';
}

/* --------------------------------------------------------------- gates */

function gatesHTML() {
  var gates = S.doc.gates || [];
  return '<div class="card-col">' + gates.map(function (g) {
    var st = gateStatus(g);
    var col = scol(st);
    var selected = isSel('node', g.id);
    var waiting = (g.waitingFor || []).map(function (w) { return w.name; }).join(', ') || '—';
    return '<div class="card' + (selected ? ' selected' : '') + '"' + selAttrs('node', g.id) + '>' +
      '<div class="card-head">' +
        '<span class="gate-diamond" style="background:' + col + '"></span>' +
        '<span class="card-title-mono">' + esc(g.id) + '</span>' +
        '<span class="card-status" style="color:' + col + '">' + esc(st) + '</span>' +
      '</div>' +
      '<div class="card-line first">waiting for · ' + esc(waiting) + '</div>' +
      '<div class="card-line">run ' + esc(runLabel(g.runId)) +
        ' · requested by ' + esc(g.requester || '—') +
        ' · evidence ' + esc(g.evidence || '—') + '</div>' +
    '</div>';
  }).join('') + '</div>';
}

/* -------------------------------------------------- runs / evidence */

function evidenceById(runId) {
  var es = S.doc.evidence || [];
  for (var i = 0; i < es.length; i++) if (String(es[i].runId) === String(runId)) return es[i];
  return null;
}

function runsHTML() {
  var entries = S.doc.evidence || [];
  return '<div class="card-col">' + entries.map(function (e) {
    var selected = isSel('run', e.runId);
    var evLabel = e.complete ? 'complete' : 'partial';
    var v5 = '';
    if (e.auditVerdict) {
      v5 += '<span style="color:' + scol(e.auditVerdict) + '">audit ' + esc(e.auditVerdict) + '</span>';
    }
    if (e.mandates) {
      var mCol = /violated/.test(e.mandates) ? COLORS.red : COLORS.green;
      v5 += '<span style="color:' + mCol + '">mandates ' + esc(e.mandates) + '</span>';
    }
    return '<div class="card' + (selected ? ' selected' : '') + '"' + selAttrs('run', e.runId) + '>' +
      '<div class="run-head">' +
        '<span class="run-id">Run ' + esc(runLabel(e.runId)) + '</span>' +
        '<span class="run-status" style="color:' + scol(e.status) + '">' + esc(e.status) + '</span>' +
        '<span class="run-ev" style="color:' + scol(evLabel) + '">evidence ' + esc(evLabel) + '</span>' +
      '</div>' +
      '<div class="run-facts">' +
        '<span>contract v' + esc(e.contractVersion) + '</span>' +
        '<span>tasks ' + esc(e.tasks) + '</span>' +
        '<span style="color:' + (e.failed ? COLORS.red : COLORS.mut) + '">failed ' + esc(e.failed) + '</span>' +
        '<span style="color:' + (e.skipped ? COLORS.grey : COLORS.mut) + '">skipped ' + esc(e.skipped) + '</span>' +
        v5 +
      '</div>' +
      '<div class="run-actions">' +
        '<button class="chip-btn" data-act="open-run" data-id="' + esc(e.runId) + '">Open run</button>' +
        '<button class="chip-btn" data-act="copy-json" data-id="' + esc(e.runId) + '">Copy JSON</button>' +
        '<button class="chip-btn accent" data-act="copy-bundle" data-id="' + esc(e.runId) + '">Copy agent bundle</button>' +
      '</div>' +
    '</div>';
  }).join('') + '</div>';
}

/* ---------------------------------------------------------------- agent */

function agentHTML() {
  var calls = S.doc.agentCalls || [];
  var label = 'MCP TOOL CALLS' + (agentCallers() ? ' · ' + agentCallers().toUpperCase() : '');
  return '' +
    '<div class="agent-wrap">' +
      '<div class="agent-label">' + esc(label) + '</div>' +
      '<div class="agent-table">' + calls.map(function (a) {
        var mark, markColor;
        if (a.result === 'ok') { mark = '✓'; markColor = COLORS.green; }
        else if (a.result === 'pending') { mark = '○'; markColor = COLORS.grey; }
        else { mark = '×'; markColor = COLORS.red; }
        var changed, changedColor;
        if (a.changedState === true) { changed = 'state +'; changedColor = COLORS.cyan; }
        else if (a.changedState === false) { changed = 'read-only'; changedColor = COLORS.faint; }
        else { changed = 'pending'; changedColor = COLORS.grey; }
        return '<div class="agent-row">' +
          '<span class="a-mark" style="color:' + markColor + '">' + mark + '</span>' +
          '<span class="a-tool">' + esc(a.tool) + '</span>' +
          '<span class="a-time">' + esc(a.time || '—') + '</span>' +
          '<span class="a-caller">' + esc(a.caller || '—') + '</span>' +
          '<span class="a-ref">' + esc(a.ref || '') + '</span>' +
          '<span class="a-changed" style="color:' + changedColor + '">' + changed + '</span>' +
        '</div>';
      }).join('') + '</div>' +
    '</div>';
}

/* ------------------------------------------------------------- activity */

function activityHTML() {
  var entries = S.log.concat(S.doc.activity || []);
  return '<div class="act-list">' + entries.map(function (ev) {
    var color = ev.kind ? scol(ev.kind) : COLORS.body;
    return '<div class="act-row">' +
      '<span class="act-time">' + esc(ev.time || '') + '</span>' +
      '<span class="act-text" style="color:' + color + '">' + esc(ev.text) + '</span>' +
    '</div>';
  }).join('') + '</div>';
}

/* ---------------------------------------------------------- right rail */

function railHTML() {
  return '' +
    '<aside class="rail">' +
      '<div class="insp-head">INSPECTOR</div>' +
      '<div class="insp-body">' + inspectorHTML() + '</div>' +
      teamRailHTML() +
    '</aside>';
}

function teamRailHTML() {
  var team = S.doc.team || {};
  var members = S.doc.members || [];
  var rows = members.map(function (m) {
    var selected = isSel('member', m.id);
    var col = scol(m.status);
    var work = m.currentWork
      ? ' · ' + (m.identityType === 'daemon' ? 'running ' : '') + m.currentWork
      : '';
    return '<div class="team-row' + (selected ? ' selected' : '') + '"' + selAttrs('member', m.id) + '>' +
      '<span class="glyph-slot">' + glyph(m.identityType) + '</span>' +
      '<div class="t-main">' +
        '<div class="t-name-line">' +
          '<span class="t-name">' + esc(m.name) + '</span>' +
          '<span class="t-type">' + esc(m.identityType) + '</span>' +
        '</div>' +
        '<div class="t-state" style="color:' + col + '">' + esc(m.status + work) + '</div>' +
      '</div>' +
      '<span class="dot' + (m.status === 'running' ? ' pulse' : '') + '" style="background:' + col + '"></span>' +
    '</div>';
  }).join('');

  return '' +
    '<div class="team-rail">' +
      '<div class="team-head">' +
        '<span class="th-label">TEAM</span>' +
        '<span class="th-count">' + esc(team.online) + ' online · ' + esc(team.total) + ' total</span>' +
      '</div>' +
      '<div class="team-list">' + rows + '</div>' +
    '</div>';
}

/* ------------------------------------------------------------ inspector */

function fld(label, value, opts) {
  opts = opts || {};
  var style = opts.color ? ' style="color:' + opts.color + '"' : '';
  return '<div class="fld">' +
    '<span class="fld-label">' + esc(label) + '</span>' +
    '<span class="fld-value' + (opts.mono ? ' mono' : '') + '"' + style + '>' + esc(value) + '</span>' +
  '</div>';
}

function inspHeader(tag, title, statusLabel, statusColor) {
  return '' +
    '<div class="insp-tag">' + esc(tag) + '</div>' +
    '<div class="insp-title-row">' +
      '<span class="insp-title">' + esc(title) + '</span>' +
      '<span class="insp-state">' +
        '<span class="dot" style="background:' + statusColor + '"></span>' +
        '<span class="lbl" style="color:' + statusColor + '">' + esc(statusLabel) + '</span>' +
      '</span>' +
    '</div>';
}

function meaningHTML(text) {
  if (!text) return '';
  return '<div class="meaning"><div class="blk-label">MEANING</div>' +
    '<div class="blk-text">' + esc(text) + '</div></div>';
}

function nextHTML(text) {
  if (!text) return '';
  return '<div class="next-block"><div class="next-label">NEXT</div>' +
    '<div class="next-text">' + esc(text) + '</div></div>';
}

function rawHTML(obj) {
  var pre = S.rawOpen
    ? '<pre class="raw-pre">' + esc(JSON.stringify(obj, null, 2)) + '</pre>'
    : '';
  return '<div class="raw-row">' +
    '<span class="raw-label">Raw output</span>' +
    '<button class="raw-toggle" data-act="toggle-raw">' + (S.rawOpen ? 'hide' : 'show') + '</button>' +
  '</div>' + pre;
}

function permsHTML(allowed, notAllowed) {
  if (!(allowed || []).length && !(notAllowed || []).length) return '';
  return '<div class="perms">' +
    '<div class="perm-label ok">ALLOWED</div>' +
    '<div class="chip-row allowed">' + (allowed || []).map(function (p) {
      return '<span class="perm-chip ok">' + esc(p) + '</span>';
    }).join('') + '</div>' +
    '<div class="perm-label no">NOT ALLOWED</div>' +
    '<div class="chip-row">' + (notAllowed || []).map(function (p) {
      return '<span class="perm-chip no">' + esc(p) + '</span>';
    }).join('') + '</div>' +
  '</div>';
}

/* v5 mandate block for agent/daemon members */
function mandateHTML(m) {
  if (!m) return '';
  var lines = [];
  (m.scope || []).forEach(function (s) { lines.push('scope ' + s); });
  var b = m.budget || {};
  if (b.diffLines !== undefined) lines.push('budget diff ≤ ' + b.diffLines + ' lines');
  if (b.wallClockMs !== undefined) lines.push('budget wall clock ≤ ' + b.wallClockMs + ' ms');
  Object.keys(b).forEach(function (k) {
    if (k !== 'diffLines' && k !== 'wallClockMs') lines.push('budget ' + k + ' ≤ ' + b[k]);
  });
  var net = m.network === false
    ? '<div class="mline" style="color:' + COLORS.red + '">network denied</div>'
    : m.network === true
      ? '<div class="mline" style="color:' + COLORS.green + '">network allowed</div>'
      : '';
  return '<div class="mandate-block">' +
    '<div class="blk-label">MANDATE</div>' +
    lines.map(function (l) { return '<div class="mline">' + esc(l) + '</div>'; }).join('') +
    net +
  '</div>';
}

function legendHTML() {
  var rows = [
    ['task', 'Task'], ['gate', 'Gate'], ['human', 'Human'],
    ['agent', 'Agent'], ['daemon', 'Daemon'], ['ci', 'CI runner']
  ];
  return '' +
    '<div class="legend-intro">Select a node, gate, work item, run, or team member to inspect its execution state.</div>' +
    '<div class="legend-label">NODE GRAMMAR</div>' +
    rows.map(function (r) {
      return '<div class="legend-row"><span class="glyph-slot">' + glyph(r[0]) + '</span>' +
        '<span class="lg-name">' + esc(r[1]) + '</span></div>';
    }).join('');
}

function inspectorHTML() {
  var sel = S.selected;
  if (!sel) return legendHTML();

  if (sel.kind === 'node') {
    var n = null;
    graphNodes().forEach(function (x) { if (x.id === sel.id) n = x; });
    if (!n) {
      // gate cards select kind "node" too; fall back to the gates list
      var gOnly = gateById(sel.id);
      return gOnly ? gateInspector(gOnly, null) : legendHTML();
    }
    if (n.type === 'gate') return gateInspector(gateById(n.id) || n, n);
    return taskInspector(n);
  }
  if (sel.kind === 'member') {
    var m = null;
    (S.doc.members || []).forEach(function (x) { if (x.id === sel.id) m = x; });
    return m ? memberInspector(m) : legendHTML();
  }
  if (sel.kind === 'work') {
    var w = null;
    (S.doc.workItems || []).forEach(function (x) { if (x.id === sel.id) w = x; });
    return w ? workInspector(w) : legendHTML();
  }
  if (sel.kind === 'run') {
    var e = evidenceById(sel.id);
    return e ? runInspector(e) : legendHTML();
  }
  return legendHTML();
}

function taskInspector(n) {
  var st = n.status;
  var col = scol(st);
  var fields = '', meaning = '', next = '', raw = '';

  if (st === 'failed') {
    fields =
      fld('FAILURE', n.failureClass || 'failed', { mono: 1, color: COLORS.red }) +
      fld('RETRY', n.retryHint || '—') +
      fld('REQUESTED BY', n.requester || '—') +
      fld('RAN ON', n.executor || '—', { mono: 1 }) +
      (n.workItemId ? fld('WORK ITEM', workTitle(n.workItemId)) : '') +
      fld('EVIDENCE', n.evidence || '—', { color: scol(n.evidence) });
    meaning = 'The task ran. The command completed. The declared success criteria did not pass.';
    next = 'Inspect contract and changed files.';
    raw = rawHTML(n);
  } else if (st === 'skipped' || st === 'blocked') {
    fields =
      fld('REASON', n.reason || st, { mono: 1, color: COLORS.grey }) +
      (n.blockedBy ? fld('BLOCKED BY', n.blockedBy, { mono: 1 }) : '') +
      fld('EVIDENCE', n.evidence || 'none', { color: scol(n.evidence || 'none') });
    meaning = 'Not executed. An upstream dependency failed before this task could run.';
    next = n.blockedBy ? 'Resolve ' + n.blockedBy + ', then re-run.' : '';
  } else {
    fields =
      fld('REQUESTED BY', n.requester || '—') +
      fld('RAN ON', n.executor || '—', { mono: 1 }) +
      fld('DURATION', n.duration || '—', { mono: 1 }) +
      fld('EVIDENCE', n.evidence || '—');
    meaning = 'Task ran and met its declared success criteria.';
    raw = rawHTML(n);
  }

  if (n.mandateOutcome) {
    fields += fld('MANDATE', n.mandateOutcome, { mono: 1, color: scol(n.mandateOutcome) });
  }

  return inspHeader('TASK', n.id, st, col) + fields + meaningHTML(meaning) + nextHTML(next) + raw;
}

function gateInspector(g, node) {
  var st = gateStatus(g);
  var col = scol(st);
  var waiting = (g.waitingFor || []).map(function (w) {
    return w.name + ' (' + w.role + (w.status && w.status !== '—' ? ', ' + w.status : '') + ')';
  }).join(' · ') || (node && (node.approvers || []).join(' · ')) || '—';

  var fields =
    fld('WAITING FOR', waiting) +
    fld('REQUESTED BY', g.requester || '—') +
    fld('RUN', runLabel(g.runId || (node && node.runId)), { mono: 1 }) +
    fld('EVIDENCE', g.evidence || '—', { color: scol(g.evidence) });

  var meaning;
  if (st === 'waiting') {
    meaning = 'Execution is paused for human approval. An agent may not clear this gate.';
  } else if (st === 'approved') {
    meaning = 'Approved by Yair. Run resumed.';
  } else {
    meaning = 'Rejected by Yair. Run halted.';
  }

  var actions = '';
  if (st === 'waiting') {
    var evNote = 'ACTIONS · EVIDENCE ' + String(g.evidence || 'unknown').toUpperCase();
    actions =
      '<div class="actions">' +
        '<div class="act-label">' + esc(evNote) + '</div>' +
        '<div class="action-row">' +
          '<button class="btn approve" data-act="approve" data-id="' + esc(g.id) + '">Approve</button>' +
          '<button class="btn reject" data-act="reject" data-id="' + esc(g.id) + '">Reject</button>' +
          '<button class="btn quiet" data-act="toggle-reason">Add reason</button>' +
        '</div>' +
        (S.reasonOpen
          ? '<div class="reason-row"><input class="reason-input" id="gate-reason" type="text" ' +
            'placeholder="reason for rejection" autocomplete="off"></div>'
          : '') +
        (S.gateError
          ? '<div class="gate-err">' + esc(S.gateError) + '</div>'
          : '') +
      '</div>';
  }

  return inspHeader('GATE', g.id, st, col) + fields + meaningHTML(meaning) + actions;
}

function memberInspector(m) {
  var col = scol(m.status);
  var type = m.identityType;
  var tag = { human: 'HUMAN', agent: 'AGENT', daemon: 'DAEMON', ci: 'CI RUNNER', reviewer: 'REVIEWER' }[type] || 'MEMBER';
  var fields, meaning;

  if (type === 'agent') {
    fields =
      fld('ROLE', m.role || '—') +
      (m.currentWork ? fld('CURRENT WORK', m.currentWork) : '') +
      fld('TRUST SCOPE', m.trust || '—', { mono: 1 });
    meaning = 'An agent participant. It may run and inspect, but cannot approve human gates.';
  } else if (type === 'daemon') {
    fields =
      fld('ROLE', m.role || '—') +
      (m.machine ? fld('MACHINE', m.machine, { mono: 1 }) : '') +
      (m.currentWork ? fld('RUNNING', m.currentWork, { mono: 1 }) : '') +
      fld('TRUST SCOPE', m.trust || '—', { mono: 1 });
    meaning = 'A local execution daemon. Reports status and uploads evidence.';
  } else if (type === 'ci') {
    fields =
      fld('ROLE', m.role || '—') +
      fld('TRUST SCOPE', m.trust || '—', { mono: 1 });
    meaning = 'A CI runner. Executes declared tasks; holds no approval authority.';
  } else {
    fields =
      fld('ROLE', m.role || '—') +
      (m.responsibility ? fld('CURRENT RESPONSIBILITY', m.responsibility) : '') +
      (m.recent ? fld('RECENT ACTIONS', m.recent) : '') +
      fld('TRUST SCOPE', m.trust || '—', { mono: 1 });
    meaning = 'A human participant with approval authority within this team.';
  }

  var nonHuman = type !== 'human' && type !== 'reviewer';
  return inspHeader(tag, m.name, m.status, col) +
    fields +
    meaningHTML(meaning) +
    (nonHuman ? mandateHTML(m.mandate) : '') +
    (nonHuman ? permsHTML(m.allowed, m.notAllowed) : '');
}

function workInspector(w) {
  var col = scol(w.status);
  var fields =
    fld('INTENT', w.intent || w.title) +
    (w.participants ? fld('PARTICIPANTS', w.participants) : '') +
    (w.runList ? fld('RUNS', w.runList, { mono: 1 }) : fld('RUNS', w.runs !== undefined ? w.runs : '—', { mono: 1 })) +
    fld('EVIDENCE', w.evidence || '—', { color: scol(w.evidence) }) +
    (w.reason ? fld(w.status === 'waiting_gate' ? 'WAITING ON' : 'BLOCKED BY', w.reason,
      { mono: 1, color: scol(w.status === 'waiting_gate' ? 'waiting' : 'failed') }) : '');
  return inspHeader('WORK ITEM', w.title, w.status, col) + fields +
    meaningHTML('A team-owned execution intent. Tracks runs, participants, and evidence toward completion.');
}

function runInspector(e) {
  var col = scol(e.status);
  var latest = S.doc.latestRun || {};
  var primary = e.failed && String(e.runId) === String(latest.id)
    ? (latest.primaryFailureNodeId || '—') : '—';

  var fields =
    fld('CONTRACT', 'v' + e.contractVersion, { mono: 1 }) +
    fld('TASKS', String(e.tasks), { mono: 1 }) +
    fld('FAILED', String(e.failed), { mono: 1, color: e.failed ? COLORS.red : COLORS.mut }) +
    fld('SKIPPED', String(e.skipped), { mono: 1, color: e.skipped ? COLORS.grey : COLORS.mut }) +
    fld('EVIDENCE', e.complete ? 'complete' : 'partial', { color: scol(e.complete ? 'complete' : 'partial') }) +
    fld('PRIMARY FAILURE', primary, { mono: 1 }) +
    (e.auditVerdict ? fld('AUDIT', e.auditVerdict, { mono: 1, color: scol(e.auditVerdict) }) : '') +
    (e.mandates ? fld('MANDATES', e.mandates,
      { mono: 1, color: /violated/.test(e.mandates) ? COLORS.red : COLORS.green }) : '');

  var actions =
    '<div class="actions">' +
      '<div class="act-label">EVIDENCE ACTIONS</div>' +
      '<div class="action-row">' +
        '<button class="btn" data-act="open-run" data-id="' + esc(e.runId) + '">Open run</button>' +
        '<button class="btn quiet" data-act="copy-json" data-id="' + esc(e.runId) + '">Copy JSON</button>' +
        '<button class="btn accent" data-act="copy-bundle" data-id="' + esc(e.runId) + '">Copy agent bundle</button>' +
      '</div>' +
    '</div>';

  return inspHeader('RUN', 'Run ' + runLabel(e.runId), e.status, col) + fields +
    meaningHTML('A recorded execution against the contract.') + actions;
}

/* --------------------------------------------------------- interactions */

document.addEventListener('click', function (ev) {
  var actEl = ev.target.closest ? ev.target.closest('[data-act]') : null;
  if (actEl) { handleAction(actEl); return; }

  var tabEl = ev.target.closest ? ev.target.closest('[data-tab]') : null;
  if (tabEl) {
    S.view = tabEl.getAttribute('data-tab');
    render();
    return;
  }

  var selEl = ev.target.closest ? ev.target.closest('[data-sel-kind]') : null;
  if (selEl) {
    S.selected = {
      kind: selEl.getAttribute('data-sel-kind'),
      id: selEl.getAttribute('data-sel-id')
    };
    S.rawOpen = false;
    S.reasonOpen = false;
    S.gateError = null;
    render();
  }
});

function handleAction(el) {
  var act = el.getAttribute('data-act');
  var id = el.getAttribute('data-id');

  if (act === 'approve') {
    var approveActor = currentActor();
    gatePost(id, 'approve', { actor: approveActor.ref, actorLabel: approveActor.label });
  } else if (act === 'reject') {
    var input = document.getElementById('gate-reason');
    var reason = input ? input.value : '';
    var rejectActor = currentActor();
    gatePost(id, 'reject', { actor: rejectActor.ref, actorLabel: rejectActor.label, reason: reason });
  } else if (act === 'toggle-reason') {
    S.reasonOpen = !S.reasonOpen;
    render();
    var ri = document.getElementById('gate-reason');
    if (ri) ri.focus();
  } else if (act === 'toggle-raw') {
    S.rawOpen = !S.rawOpen;
    render();
  } else if (act === 'open-run') {
    S.selected = { kind: 'run', id: id };
    S.view = 'runs';
    S.rawOpen = false;
    render();
  } else if (act === 'copy-json') {
    var e = evidenceById(id);
    copyText(JSON.stringify(e || {}, null, 2), el);
  } else if (act === 'copy-bundle') {
    copyText(agentBundle(id), el);
  }
}

function gatePost(id, action, body) {
  fetch('/api/gates/' + encodeURIComponent(id) + '/' + action, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  })
    .then(function (res) {
      if (res.ok) {
        applyGateDecision(id, action, body);
        return;
      }
      return res.json()
        .catch(function () { return null; })
        .then(function (j) {
          S.gateError = (j && j.error && j.error.message) || ('gate ' + action + ' failed · HTTP ' + res.status);
          render();
        });
    })
    .catch(function (e) {
      S.gateError = 'gate ' + action + ' failed · ' + String((e && e.message) || e);
      render();
    });
}

function applyGateDecision(id, action, body) {
  var t = nowHM();
  S.gateError = null;
  S.reasonOpen = false;
  if (action === 'approve') {
    S.gateOverrides[id] = 'approved';
    S.log = [
      { time: t, text: 'run resumed', kind: 'ok' },
      { time: t, text: (body.actorLabel || body.actor) + ' approved ' + id, kind: 'ok' }
    ].concat(S.log);
  } else {
    S.gateOverrides[id] = 'rejected';
    var text = (body.actorLabel || body.actor) + ' rejected ' + id +
      (body.reason ? ' · ' + body.reason : '') + ' · run halted';
    S.log = [{ time: t, text: text, kind: 'fail' }].concat(S.log);
  }
  render();
}

/* agent-oriented evidence bundle (what an agent needs, no logs/source) */
function agentBundle(runId) {
  var e = evidenceById(runId) || {};
  var latest = S.doc.latestRun || {};
  var lines = [
    'sykli run ' + runId,
    'status: ' + (e.status || 'unknown'),
    'contract: v' + e.contractVersion,
    'tasks: ' + e.tasks + ' · failed: ' + e.failed + ' · skipped: ' + e.skipped,
    'evidence: ' + (e.complete ? 'complete' : 'partial')
  ];
  if (e.auditVerdict) lines.push('audit: ' + e.auditVerdict);
  if (e.mandates) lines.push('mandates: ' + e.mandates);
  if (e.failed && String(runId) === String(latest.id) && latest.primaryFailureNodeId) {
    lines.push('primary failure: ' + latest.primaryFailureNodeId);
    var node = null;
    graphNodes().forEach(function (n) { if (n.id === latest.primaryFailureNodeId) node = n; });
    if (node && node.failureClass) lines.push('failure class: ' + node.failureClass);
    if (node && node.mandateOutcome) lines.push('mandate outcome: ' + node.mandateOutcome);
  }
  lines.push('next: sykli evidence explain --run ' + runId + ' --for-agent');
  return lines.join('\n');
}

function copyText(text, el) {
  function done() {
    if (!el) return;
    var prev = el.textContent;
    el.textContent = 'copied';
    setTimeout(function () { el.textContent = prev; }, 1200);
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
  } else {
    fallbackCopy(text);
    done();
  }
}

function fallbackCopy(text) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (e) { /* clipboard unavailable */ }
  document.body.removeChild(ta);
}

boot();
