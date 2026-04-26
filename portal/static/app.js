/* Cluster Control Plane - Frontend Application */

// ── Theme ─────────────────────────────────────────────────────────
function toggleTheme() {
  const isDark = document.documentElement.getAttribute('data-theme') !== 'light';
  const next = isDark ? 'light' : 'dark';
  applyTheme(next);
  localStorage.setItem('theme', next);
}

function applyTheme(theme) {
  const btn = document.getElementById('theme-toggle');
  if (theme === 'light') {
    document.documentElement.setAttribute('data-theme', 'light');
    if (btn) btn.textContent = '☀️';
  } else {
    document.documentElement.removeAttribute('data-theme');
    if (btn) btn.textContent = '🌙';
  }
}

(function initTheme() {
  const saved = localStorage.getItem('theme') || 'dark';
  applyTheme(saved);
})();

// ── State ──────────────────────────────────────────────────────────
let selectedNodes = new Set();
let expandMode = 'batch';
let shrinkMode = 'batch';
let shrinkTarget = 'job';
let pendingConfirmAction = null;
let activeLogExecutionId = null;
let historyExecutions = [];
let historyCurrentPage = 1;
const HISTORY_PAGE_SIZE = 5;
let historySortField = 'created_at';
let historySortDir = 'desc';

// ── SocketIO ───────────────────────────────────────────────────────
const socket = io();

socket.on('connected', () => {
  document.getElementById('connection-status').className = 'status-indicator connected';
  document.getElementById('connection-status').textContent = '● Connected';
});

socket.on('disconnect', () => {
  document.getElementById('connection-status').className = 'status-indicator disconnected';
  document.getElementById('connection-status').textContent = '● Disconnected';
});

socket.on('log_line', (data) => {
  const el = document.getElementById('log-content');
  el.textContent += data.line + '\n';
  if (document.getElementById('log-follow').checked) {
    el.scrollTop = el.scrollHeight;
  }
});

socket.on('log_ended', (data) => {
  const el = document.getElementById('log-content');
  el.textContent += '\n--- Log stream ended ---\n';
});

socket.on('log_error', (data) => {
  const el = document.getElementById('log-content');
  el.textContent += '\n[ERROR] ' + (data.error || 'Unknown error') + '\n';
});

// ── Panel Navigation ───────────────────────────────────────────────
function switchPanel(panelId) {
  document.querySelectorAll('.panel').forEach(p => {
    p.classList.remove('active');
    p.classList.add('hidden');
  });
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));

  document.getElementById(panelId).classList.remove('hidden');
  document.getElementById(panelId).classList.add('active');
  const tab = document.querySelector(`.tab[data-panel="${panelId}"]`);
  if (tab) tab.classList.add('active');

  if (panelId === 'inventory') refreshInventory();
  if (panelId === 'history') refreshHistory();
}

// ── Inventory ──────────────────────────────────────────────────────
let inventoryNodes = [];
let inventorySortCol = null;
let inventorySortDir = 'asc';

async function refreshInventory() {
  const loading = document.getElementById('inventory-loading');
  const error = document.getElementById('inventory-error');
  const table = document.getElementById('inventory-table');

  loading.classList.remove('hidden');
  error.classList.add('hidden');
  table.classList.add('hidden');

  try {
    const res = await fetch('/api/inventory');
    const data = await res.json();

    if (data.error) {
      error.textContent = data.error;
      error.classList.remove('hidden');
      loading.classList.add('hidden');
      return;
    }

    inventoryNodes = data.nodes;

    table.classList.remove('hidden');
    loading.classList.add('hidden');
    renderInventory();
  } catch (e) {
    error.textContent = 'Failed to load inventory: ' + e.message;
    document.getElementById('inventory-error').classList.remove('hidden');
    loading.classList.add('hidden');
  }
}

function sortInventory(col) {
  if (inventorySortCol === col) {
    inventorySortDir = inventorySortDir === 'asc' ? 'desc' : 'asc';
  } else {
    inventorySortCol = col;
    inventorySortDir = 'asc';
  }
  renderInventory();
}

function getNodeSortValue(node, col) {
  switch (col) {
    case 'node_name': return node.node_name;
    case 'role': return node.role;
    case 'slurm_state': return node.slurm_state || '';
    case 'slurm_partitions': return node.slurm_partitions.join(', ');
    case 'cpus': return node.slurm_present ? node.slurm_cpus : -1;
    case 'openstack': return node.openstack_compute_registered
      ? node.openstack_compute_status + '/' + node.openstack_compute_state : '';
    case 'notes': return node.notes.join('; ');
    default: return '';
  }
}

function renderInventory() {
  const body = document.getElementById('inventory-body');

  // Update sort indicators in headers
  document.querySelectorAll('#inventory-table thead th[data-sort]').forEach(th => {
    const col = th.dataset.sort;
    const indicator = th.querySelector('.sort-indicator');
    if (indicator) {
      if (col === inventorySortCol) {
        indicator.textContent = inventorySortDir === 'asc' ? ' ▲' : ' ▼';
        th.classList.add('sorted');
      } else {
        indicator.textContent = ' ⇅';
        th.classList.remove('sorted');
      }
    }
  });

  let nodes = [...inventoryNodes];
  if (inventorySortCol) {
    nodes.sort((a, b) => {
      const av = getNodeSortValue(a, inventorySortCol);
      const bv = getNodeSortValue(b, inventorySortCol);
      const cmp = typeof av === 'number' && typeof bv === 'number'
        ? av - bv
        : String(av).localeCompare(String(bv));
      return inventorySortDir === 'asc' ? cmp : -cmp;
    });
  }

  body.innerHTML = '';
  for (const node of nodes) {
    const tr = document.createElement('tr');
    const isSelected = selectedNodes.has(node.node_name);
    tr.innerHTML = `
      <td><input type="checkbox" class="node-checkbox" value="${node.node_name}" ${isSelected ? 'checked' : ''} onchange="toggleNodeSelection(this)"></td>
      <td><strong>${node.node_name}</strong></td>
      <td><span class="role-badge"><span class="dot role-${node.role}"></span>${formatRole(node.role)}</span></td>
      <td>${node.slurm_state || '—'}</td>
      <td>${node.slurm_partitions.join(', ') || '—'}</td>
      <td>${node.slurm_present ? node.slurm_alloc_cpus + '/' + node.slurm_cpus : '—'}</td>
      <td>${formatOpenStack(node)}</td>
    `;
    body.appendChild(tr);
  }

  updateSelectedNodesDisplay();
}

function formatRole(role) {
  const labels = {
    slurm_worker: 'Slurm Worker',
    openstack_compute: 'OpenStack Compute',
    transition: 'Transition',
    conflict: 'Conflict',
    unknown: 'Unknown',
  };
  return labels[role] || role;
}

function formatOpenStack(node) {
  if (!node.openstack_compute_registered) return '—';
  const stateClass = node.openstack_compute_state === 'up' ? 'completed' : 'failed';
  return `<span class="status-badge ${stateClass}">${node.openstack_compute_status} / ${node.openstack_compute_state}</span>`;
}

// ── Node Selection ─────────────────────────────────────────────────
function toggleNodeSelection(checkbox) {
  if (checkbox.checked) {
    selectedNodes.add(checkbox.value);
  } else {
    selectedNodes.delete(checkbox.value);
  }
  updateSelectedNodesDisplay();
}

function toggleSelectAll(checkbox) {
  document.querySelectorAll('.node-checkbox').forEach(cb => {
    cb.checked = checkbox.checked;
    if (checkbox.checked) selectedNodes.add(cb.value);
    else selectedNodes.delete(cb.value);
  });
  updateSelectedNodesDisplay();
}

function updateSelectedNodesDisplay() {
  const shrinkDisplay = document.getElementById('shrink-selected-nodes');
  const warning = document.getElementById('shrink-node-warning');
  const expandDisplay = document.getElementById('expand-selected-nodes');
  const placeholder = '<em>Select nodes from the inventory on the left</em>';

  if (selectedNodes.size === 0) {
    shrinkDisplay.innerHTML = placeholder;
    warning.classList.add('hidden');
    if (expandDisplay) expandDisplay.innerHTML = placeholder;
  } else {
    const nodeList = Array.from(selectedNodes).join(', ');
    shrinkDisplay.textContent = nodeList;
    warning.classList.remove('hidden');
    if (expandDisplay) expandDisplay.textContent = nodeList;
  }
}

// ── Operations ─────────────────────────────────────────────────────
function setExpandMode(mode) {
  expandMode = mode;
  document.querySelectorAll('.operations-pane .ops-card:first-child .mode-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.mode === mode);
  });
  document.getElementById('expand-direct-warning').classList.toggle('hidden', mode !== 'direct');
  document.getElementById('expand-batch-fields').classList.toggle('hidden', mode === 'direct');
  document.getElementById('expand-direct-fields').classList.toggle('hidden', mode !== 'direct');
}

function setShrinkMode(mode) {
  shrinkMode = mode;
  document.querySelectorAll('.operations-pane .ops-card:last-child [data-mode]').forEach(b => {
    b.classList.toggle('active', b.dataset.mode === mode);
  });
  document.getElementById('shrink-direct-warning').classList.toggle('hidden', mode !== 'direct');
  document.getElementById('shrink-partition-group').classList.toggle('hidden', mode === 'direct');
  setShrinkTarget(shrinkTarget);
}

function setShrinkTarget(target) {
  shrinkTarget = target;
  document.querySelectorAll('.operations-pane .ops-card:last-child [data-target]').forEach(b => {
    b.classList.toggle('active', b.dataset.target === target);
  });
  document.getElementById('shrink-job-group').classList.toggle('hidden', target !== 'job');
  document.getElementById('shrink-nodes-group').classList.toggle('hidden', target !== 'nodes');
}

function submitExpand() {
  const partition = document.getElementById('expand-partition').value || 'all';
  const occupyNum = parseInt(document.getElementById('expand-num').value) || 1;

  if (expandMode === 'direct') {
    const nodes = Array.from(selectedNodes);
    if (nodes.length === 0) {
      alert('Please select nodes from the Inventory tab');
      return;
    }
    showConfirmation(
      'Confirm Direct Expand',
      `<p>You are about to run an <strong>expand</strong> operation in <strong>direct mode</strong>.</p>
       <p>This bypasses Slurm scheduling and runs directly on the headnode.</p>
       <ul>
         <li>Nodes: <strong>${nodes.join(', ')}</strong></li>
       </ul>
       <p class="warning" style="margin-top:0.75rem">⚠ Direct mode should only be used when partition capacity is unavailable.</p>`,
      () => doExpand(partition, occupyNum, nodes)
    );
  } else {
    doExpand(partition, occupyNum, []);
  }
}

async function doExpand(partition, occupyNum, nodes) {
  try {
    const body = { mode: expandMode, partition, occupy_num: occupyNum };
    if (nodes && nodes.length) body.selected_nodes = nodes;

    const res = await fetch('/api/operations/expand', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (data.error) {
      alert('Expand failed: ' + data.error);
    } else {
      switchPanel('history');
      viewLogs(data.id, data.status || 'running');
    }
  } catch (e) {
    alert('Request failed: ' + e.message);
  }
}

function submitShrink() {
  const partition = shrinkMode === 'direct'
    ? null
    : (document.getElementById('shrink-partition').value || 'all');
  const jobId = shrinkTarget === 'job' ? document.getElementById('shrink-job-id').value : null;
  const nodes = shrinkTarget === 'nodes' ? Array.from(selectedNodes) : [];

  if (shrinkTarget === 'job' && !jobId) {
    alert('Please enter a Job ID');
    return;
  }
  if (shrinkTarget === 'nodes' && nodes.length === 0) {
    alert('Please select nodes from the Inventory tab');
    return;
  }

  const targetDesc = shrinkTarget === 'job'
    ? `Job ID: <strong>${jobId}</strong>`
    : `Nodes: <strong>${nodes.join(', ')}</strong>`;

  const isDirectOrNodeSelect = shrinkMode === 'direct' || shrinkTarget === 'nodes';

  if (isDirectOrNodeSelect) {
    showConfirmation(
      'Confirm Shrink Operation',
      `<p>You are about to <strong>shrink</strong> (remove OpenStack compute nodes).</p>
       <ul>
         <li>Mode: <strong>${shrinkMode}</strong></li>
         <li>Target: ${targetDesc}</li>
         ${partition ? `<li>Partition: <strong>${partition}</strong></li>` : ''}
       </ul>
       ${shrinkMode === 'direct' ? '<p class="warning" style="margin-top:0.75rem">⚠ Direct mode bypasses Slurm scheduling.</p>' : ''}
       ${shrinkTarget === 'nodes' ? '<p class="warning" style="margin-top:0.75rem">⚠ Ensure all selected nodes are currently OpenStack computes. Mixed selections will be rejected.</p>' : ''}`,
      () => doShrink(partition, jobId, nodes)
    );
  } else {
    doShrink(partition, jobId, nodes);
  }
}

async function doShrink(partition, jobId, nodes) {
  try {
    const body = { mode: shrinkMode };
    if (partition) body.partition = partition;
    if (jobId) body.job_id = jobId;
    if (nodes.length) body.selected_nodes = nodes;

    const res = await fetch('/api/operations/shrink', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (data.error) {
      alert('Shrink failed: ' + data.error);
    } else {
      switchPanel('history');
      viewLogs(data.id, data.status || 'running');
    }
  } catch (e) {
    alert('Request failed: ' + e.message);
  }
}

// ── History ────────────────────────────────────────────────────────
async function refreshHistory() {
  const body = document.getElementById('history-body');
  const error = document.getElementById('history-error');
  const pagination = document.getElementById('history-pagination');
  error.classList.add('hidden');

  try {
    const res = await fetch('/api/executions');
    const data = await res.json();

    if (data.error) {
      error.textContent = data.error;
      error.classList.remove('hidden');
      return;
    }

    if (!data.executions || data.executions.length === 0) {
      historyExecutions = [];
      historyCurrentPage = 1;
      body.innerHTML = '<tr><td colspan="8" class="empty-state">No executions yet</td></tr>';
      pagination.classList.add('hidden');
      return;
    }

    historyExecutions = data.executions;
    historyCurrentPage = 1;
    renderHistoryPage();
  } catch (e) {
    error.textContent = 'Failed to load history: ' + e.message;
    error.classList.remove('hidden');
  }
}

function getExecSortValue(exec, field) {
  switch (field) {
    case 'id': return exec.id;
    case 'operation': return exec.operation || '';
    case 'mode': return exec.mode || '';
    case 'status': return exec.status || '';
    case 'slurm_job_id': return exec.slurm_job_id || '';
    case 'target_nodes': {
      const nodes = Array.isArray(exec.target_nodes) ? exec.target_nodes : [];
      return nodes.length ? nodes.join(', ') : (exec.occupy_num ? String(exec.occupy_num) : '');
    }
    case 'created_at': return exec.created_at || '';
    default: return '';
  }
}

function sortHistory(field) {
  if (historySortField === field) {
    historySortDir = historySortDir === 'asc' ? 'desc' : 'asc';
  } else {
    historySortField = field;
    historySortDir = 'asc';
  }
  historyCurrentPage = 1;
  renderHistoryPage();
}

function renderHistoryPage() {
  const body = document.getElementById('history-body');
  const pagination = document.getElementById('history-pagination');
  const pageInfo = document.getElementById('history-page-info');
  const prevButton = document.getElementById('history-prev');
  const nextButton = document.getElementById('history-next');

  // Update sort indicators
  document.querySelectorAll('#history-table thead th[data-sort]').forEach(th => {
    const col = th.dataset.sort;
    const indicator = th.querySelector('.sort-indicator');
    if (indicator) {
      if (col === historySortField) {
        indicator.textContent = historySortDir === 'asc' ? ' ▲' : ' ▼';
        th.classList.add('sorted');
      } else {
        indicator.textContent = ' ⇅';
        th.classList.remove('sorted');
      }
    }
  });

  if (historyExecutions.length === 0) {
    body.innerHTML = '<tr><td colspan="8" class="empty-state">No executions yet</td></tr>';
    pagination.classList.add('hidden');
    return;
  }

  // Sort
  let sorted = [...historyExecutions];
  sorted.sort((a, b) => {
    const av = getExecSortValue(a, historySortField);
    const bv = getExecSortValue(b, historySortField);
    const cmp = String(av).localeCompare(String(bv), undefined, { numeric: true });
    return historySortDir === 'asc' ? cmp : -cmp;
  });

  const totalPages = Math.max(1, Math.ceil(sorted.length / HISTORY_PAGE_SIZE));
  historyCurrentPage = Math.min(Math.max(historyCurrentPage, 1), totalPages);

  const startIndex = (historyCurrentPage - 1) * HISTORY_PAGE_SIZE;
  const pageItems = sorted.slice(startIndex, startIndex + HISTORY_PAGE_SIZE);

  body.innerHTML = '';
  for (const exec of pageItems) {
    const tr = document.createElement('tr');
    const targetNodes = Array.isArray(exec.target_nodes) ? exec.target_nodes : [];
    tr.innerHTML = `
      <td><code>${exec.id}</code></td>
      <td>${exec.operation}</td>
      <td>${exec.mode}</td>
      <td><span class="status-badge ${exec.status}">${exec.status}</span></td>
      <td>${exec.slurm_job_id || '—'}</td>
      <td>${targetNodes.length ? targetNodes.join(', ') : (exec.occupy_num ? exec.occupy_num + ' nodes' : '—')}</td>
      <td>${formatTime(exec.created_at)}</td>
      <td>
        <button class="btn btn-secondary btn-sm" onclick="viewLogs('${exec.id}', '${exec.status}')">Logs</button>
      </td>
    `;
    body.appendChild(tr);
  }

  pageInfo.textContent = `Page ${historyCurrentPage} of ${totalPages}`;
  prevButton.disabled = historyCurrentPage === 1;
  nextButton.disabled = historyCurrentPage === totalPages;
  pagination.classList.toggle('hidden', totalPages <= 1);
}

function changeHistoryPage(direction) {
  const nextPage = historyCurrentPage + direction;
  const totalPages = Math.max(1, Math.ceil(historyExecutions.length / HISTORY_PAGE_SIZE));
  if (nextPage < 1 || nextPage > totalPages) {
    return;
  }

  historyCurrentPage = nextPage;
  renderHistoryPage();
}

function formatTime(isoStr) {
  if (!isoStr) return '—';
  try {
    const d = new Date(isoStr);
    return d.toLocaleString();
  } catch { return isoStr; }
}

// ── Log Viewer ─────────────────────────────────────────────────────
async function viewLogs(executionId, status) {
  const viewer = document.getElementById('log-viewer');
  const content = document.getElementById('log-content');
  const execIdEl = document.getElementById('log-exec-id');

  if (activeLogExecutionId && activeLogExecutionId !== executionId) {
    socket.emit('unsubscribe_logs', { execution_id: activeLogExecutionId });
    activeLogExecutionId = null;
  }

  execIdEl.textContent = executionId;
  content.textContent = '';
  viewer.classList.remove('hidden');

  if (status === 'running' || status === 'pending') {
    // Live streaming
    content.textContent = 'Connecting to live log stream...\n';
    activeLogExecutionId = executionId;
    socket.emit('subscribe_logs', { execution_id: executionId });
  } else {
    // Completed log replay
    activeLogExecutionId = null;
    content.textContent = 'Loading logs...\n';
    try {
      const res = await fetch(`/api/executions/${executionId}/logs`);
      const data = await res.json();
      content.textContent = data.logs || '[No logs available]';
    } catch (e) {
      content.textContent = '[Failed to load logs: ' + e.message + ']';
    }
  }
}

function closeLogViewer() {
  if (activeLogExecutionId) {
    socket.emit('unsubscribe_logs', { execution_id: activeLogExecutionId });
    activeLogExecutionId = null;
  }
  document.getElementById('log-viewer').classList.add('hidden');
}

// ── Confirmation Modal ─────────────────────────────────────────────
function showConfirmation(title, bodyHtml, action) {
  document.getElementById('confirm-title').textContent = title;
  document.getElementById('confirm-body').innerHTML = bodyHtml;
  document.getElementById('confirm-modal').classList.remove('hidden');
  pendingConfirmAction = action;
}

function confirmAction() {
  const action = pendingConfirmAction;
  closeModal();
  if (action) {
    action();
  }
}

function closeModal() {
  document.getElementById('confirm-modal').classList.add('hidden');
  pendingConfirmAction = null;
}

function initializeOperationsForm() {
  setExpandMode(expandMode);
  setShrinkMode(shrinkMode);
  setShrinkTarget(shrinkTarget);
}

document.addEventListener('DOMContentLoaded', initializeOperationsForm);

// ── Init ───────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  refreshInventory();
});
