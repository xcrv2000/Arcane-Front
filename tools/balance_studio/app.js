(function () {
  const state = {
    data: null,
    sourcePath: "",
    designerDocPath: "",
    selectedId: "",
    compareId: "",
    filter: "all",
    search: "",
    dirty: false,
    saving: false,
    error: "",
    apiBase: "",
    offline: false
  };

  const defaultApiBases = Array.from({ length: 20 }, (_, index) => `http://127.0.0.1:${8765 + index}`);

  const fieldGroups = [
    {
      title: "基础",
      fields: [
        { path: "id", label: "id", type: "text", readonly: true, note: "稳定标识，改动会影响任务引用与美术 id。" },
        { path: "name", label: "名称", type: "text" },
        { path: "short_name", label: "短名", type: "text" },
        { path: "role", label: "定位", type: "text" },
        { path: "kind", label: "类型", type: "select", options: ["unit", "spell"] },
        { path: "tags", label: "标签（逗号分隔）", type: "tag-list", wide: true, note: "可同时填写系列与机制标签；支持中文或英文逗号。" },
        { path: "cost", label: "费用", type: "number", step: 1 },
        { path: "color", label: "颜色", type: "color" },
        { path: "trial_note", label: "用途说明", type: "textarea", wide: true }
      ]
    },
    {
      title: "生物战斗",
      kind: "unit",
      fields: [
        { path: "count", label: "生成数量", type: "number", step: 1 },
        { path: "hp", label: "生命", type: "number", step: 1 },
        { path: "damage", label: "攻击力", type: "number", step: 1 },
        { path: "attack_cooldown", label: "攻击间隔 秒", type: "number", step: 0.05 },
        { path: "range", label: "射程 逻辑单位", type: "number", step: 0.1 },
        { path: "speed", label: "速度 逻辑单位/秒", type: "number", step: 0.1 },
        { path: "radius", label: "基础半径", type: "number", step: 0.05 },
        { path: "shape", label: "占位形状", type: "select", options: ["circle", "square", "triangle"] },
        { path: "aoe_radius", label: "攻击 AOE 半径", type: "number", step: 0.1, optional: true },
        { path: "target_base_only", label: "只攻击基地", type: "checkbox", optional: true }
      ]
    },
    {
      title: "法术战斗",
      kind: "spell",
      fields: [
        { path: "damage", label: "对单位伤害", type: "number", step: 1 },
        { path: "base_damage", label: "对基地伤害", type: "number", step: 1 },
        { path: "radius", label: "范围半径", type: "number", step: 0.1 },
        { path: "spell_mode", label: "法术模式", type: "select", options: ["single", "area", "line"] }
      ]
    },
    {
      title: "任务",
      fields: [
        { path: "task.type", label: "任务类型", type: "text" },
        { path: "task.summary", label: "任务说明", type: "textarea", wide: true },
        { path: "task.progress_label", label: "进度标签", type: "text", optional: true },
        { path: "task.watch_card_id", label: "监听卡牌 id", type: "select-card", optional: true },
        { path: "task.target", label: "目标值", type: "number", step: 1 },
        { path: "task.target_text", label: "目标显示", type: "text", optional: true },
        { path: "task.window", label: "时间窗口 秒", type: "number", step: 0.1, optional: true },
        { path: "task.hp_ratio", label: "血量比例阈值", type: "number", step: 0.0001, optional: true }
      ]
    },
    {
      title: "进化",
      fields: [
        { path: "evolution.id", label: "进化 id", type: "text" },
        { path: "evolution.name", label: "进化名称", type: "text" },
        { path: "evolution.short_name", label: "进化短名", type: "text" },
        { path: "evolution.summary", label: "进化说明", type: "textarea", wide: true }
      ]
    }
  ];

  const overrideFields = [
    { key: "cost", label: "费用", type: "number", step: 1 },
    { key: "count", label: "数量", type: "number", step: 1 },
    { key: "hp", label: "生命", type: "number", step: 1 },
    { key: "damage", label: "攻击力/伤害", type: "number", step: 1 },
    { key: "base_damage", label: "基地伤害", type: "number", step: 1 },
    { key: "attack_cooldown", label: "攻击间隔", type: "number", step: 0.05 },
    { key: "range", label: "射程", type: "number", step: 0.1 },
    { key: "speed", label: "速度", type: "number", step: 0.1 },
    { key: "radius", label: "半径", type: "number", step: 0.05 },
    { key: "aoe_radius", label: "AOE 半径", type: "number", step: 0.1 },
    { key: "multi_target_count", label: "同时目标数", type: "number", step: 1 },
    { key: "aura_interval", label: "光环间隔", type: "number", step: 0.1 },
    { key: "aura_radius", label: "光环半径", type: "number", step: 0.1 },
    { key: "aura_damage", label: "光环伤害", type: "number", step: 1 },
    { key: "spell_mode", label: "法术模式", type: "select", options: ["single", "area", "line"] }
  ];

  const dom = {};

  document.addEventListener("DOMContentLoaded", () => {
    Object.assign(dom, {
      sourceLine: document.getElementById("sourceLine"),
      reloadBtn: document.getElementById("reloadBtn"),
      saveBtn: document.getElementById("saveBtn"),
      openDocBtn: document.getElementById("openDocBtn"),
      closeDocBtn: document.getElementById("closeDocBtn"),
      fieldDialog: document.getElementById("fieldDialog"),
      fieldDocs: document.getElementById("fieldDocs"),
      searchInput: document.getElementById("searchInput"),
      cardList: document.getElementById("cardList"),
      editorHeader: document.getElementById("editorHeader"),
      editorForm: document.getElementById("editorForm"),
      metricsPanel: document.getElementById("metricsPanel"),
      comparePanel: document.getElementById("comparePanel"),
      overviewPanel: document.getElementById("overviewPanel"),
      warningsPanel: document.getElementById("warningsPanel"),
      toast: document.getElementById("toast")
    });

    dom.reloadBtn.addEventListener("click", loadData);
    dom.saveBtn.addEventListener("click", saveData);
    dom.openDocBtn.addEventListener("click", () => dom.fieldDialog.showModal());
    dom.closeDocBtn.addEventListener("click", () => dom.fieldDialog.close());
    dom.searchInput.addEventListener("input", (event) => {
      state.search = event.target.value.trim();
      render();
    });
    document.querySelectorAll("[data-filter]").forEach((button) => {
      button.addEventListener("click", () => {
        state.filter = button.dataset.filter;
        render();
      });
    });

    loadData();
  });

  async function loadData() {
    state.error = "";
    state.dirty = false;
    state.offline = false;
    renderLoading();
    if (shouldLoadOfflineFirst()) {
      loadOfflineSnapshot();
      render();
      return;
    }
    try {
      const payload = await apiRequest("/api/cards");
      state.data = payload.data;
      state.sourcePath = payload.source_path || "游戏工程/data/cards.json";
      state.designerDocPath = payload.designer_doc_path || "开发文档/设计/设计师文档.md";
      state.selectedId = firstCardId();
      state.compareId = secondCardId();
      state.offline = false;
      showToast("已读取权威 JSON。");
    } catch (error) {
      if (loadOfflineSnapshot()) {
        render();
        return;
      }
      state.error = `无法读取卡牌数据：${error.message}`;
      showToast(state.error);
    }
    render();
  }

  async function saveData() {
    if (!state.data || !state.dirty || state.saving) {
      return;
    }
    state.saving = true;
    renderToolbar();
    try {
      if (state.offline) {
        const exported = await exportOfflineJson();
        if (exported) {
          state.dirty = false;
        }
        state.saving = false;
        render();
        return;
      }
      const payload = await apiRequest("/api/cards", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(state.data)
      });
      state.dirty = false;
      if (payload.updated_at) {
        state.data.updated_at = payload.updated_at;
      }
      showToast(`已保存，并同步 ${payload.designer_doc_path || state.designerDocPath}。`);
    } catch (error) {
      if (state.offline && error.name === "AbortError") {
        showToast("已取消导出。");
      } else {
        showToast(`${state.offline ? "导出" : "保存"}失败：${error.message}`);
      }
    }
    state.saving = false;
    render();
  }

  async function apiRequest(path, options) {
    const candidates = apiCandidates();
    let lastError = null;

    for (const apiBase of candidates) {
      try {
        const response = await fetch(`${apiBase}${path}`, options);
        const payload = await response.json();
        if (!response.ok || payload.ok === false) {
          throw new Error(payload.error || `HTTP ${response.status}`);
        }
        state.apiBase = apiBase;
        if (apiBase) {
          setSavedApiBase(apiBase);
        }
        return payload;
      } catch (error) {
        lastError = error;
      }
    }

    const detail = lastError ? lastError.message : "接口不可用";
    throw new Error(`${detail}。请先运行 tools\\balance_studio\\start_balance_studio.bat，或在仓库根目录执行 python tools\\balance_studio\\server.py --open。`);
  }

  function apiCandidates() {
    const params = new URLSearchParams(window.location.search);
    const configured = params.get("api");
    const saved = getSavedApiBase();
    const currentOrigin = window.location.protocol === "http:" || window.location.protocol === "https:"
      ? window.location.origin
      : "";
    const values = [state.apiBase, configured, saved, currentOrigin, ...defaultApiBases]
      .map(normalizeApiBase)
      .filter(Boolean);
    return [...new Set(values)];
  }

  function getSavedApiBase() {
    try {
      const saved = normalizeApiBase(localStorage.getItem("balanceStudioApiBase") || "");
      if (!saved) {
        localStorage.removeItem("balanceStudioApiBase");
      }
      return saved;
    } catch (error) {
      return "";
    }
  }

  function setSavedApiBase(apiBase) {
    const normalized = normalizeApiBase(apiBase);
    if (!normalized) {
      return;
    }
    try {
      localStorage.setItem("balanceStudioApiBase", normalized);
    } catch (error) {
      // 部分浏览器会限制 file:// 下的 localStorage；接口成功即可，不让缓存失败中断工具。
    }
  }

  function normalizeApiBase(value) {
    const text = String(value || "").trim();
    if (!text) {
      return "";
    }
    try {
      const url = new URL(text);
      if (url.protocol !== "http:" && url.protocol !== "https:") {
        return "";
      }
      return url.origin;
    } catch (error) {
      return "";
    }
  }

  function shouldLoadOfflineFirst() {
    const params = new URLSearchParams(window.location.search);
    return window.location.protocol === "file:" && !params.has("api") && Boolean(window.__BALANCE_STUDIO_DATA__);
  }

  function loadOfflineSnapshot() {
    const snapshot = window.__BALANCE_STUDIO_DATA__;
    if (!snapshot || !Array.isArray(snapshot.cards) || !snapshot.cards.length) {
      return false;
    }

    state.data = cloneData(snapshot);
    state.sourcePath = window.__BALANCE_STUDIO_SOURCE__ || "tools/balance_studio/cards_snapshot.js（离线快照）";
    state.designerDocPath = "离线模式不会直接同步设计师文档";
    state.selectedId = firstCardId();
    state.compareId = secondCardId();
    state.error = "";
    state.apiBase = "";
    state.offline = true;
    showToast("已加载离线快照；修改后请用“导出 JSON”。");
    return true;
  }

  async function exportOfflineJson() {
    const exportedData = cloneData(state.data);
    exportedData.updated_at = new Date().toISOString().slice(0, 10);
    const text = `${JSON.stringify(exportedData, null, 2)}\n`;

    if (window.showSaveFilePicker && window.isSecureContext) {
      const handle = await window.showSaveFilePicker({
        suggestedName: "cards.json",
        types: [
          {
            description: "Arcane Frontline card data",
            accept: { "application/json": [".json"] }
          }
        ]
      });
      const writable = await handle.createWritable();
      await writable.write(text);
      await writable.close();
    } else {
      downloadText("cards.json", text);
    }

    state.data.updated_at = exportedData.updated_at;
    showToast("已导出 cards.json；替换 游戏工程/data/cards.json 后提交。");
    return true;
  }

  function downloadText(filename, text) {
    const blob = new Blob([text], { type: "application/json;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 0);
  }

  function renderLoading() {
    dom.cardList.innerHTML = '<div class="loading-state">加载中</div>';
    dom.editorHeader.innerHTML = "";
    dom.editorForm.innerHTML = "";
    dom.metricsPanel.innerHTML = "";
    dom.comparePanel.innerHTML = "";
    dom.overviewPanel.innerHTML = "";
    dom.warningsPanel.innerHTML = "";
    renderToolbar();
  }

  function render() {
    renderToolbar();
    renderFieldDocs();

    if (!state.data) {
      renderErrorState();
      return;
    }

    ensureSelectedCard();
    renderCardList();
    renderEditor();
    renderMetrics();
    renderCompare();
    renderOverview();
    renderWarnings();
  }

  function renderToolbar() {
    if (!dom.sourceLine) {
      return;
    }
    const dirtyText = state.dirty ? "，有未保存修改" : "";
    const apiText = state.offline ? " · 离线快照模式" : state.apiBase ? ` · 接口：${state.apiBase}` : "";
    dom.sourceLine.textContent = state.sourcePath ? `源：${state.sourcePath}${apiText}${dirtyText}` : "加载数据中";
    dom.saveBtn.disabled = !state.dirty || state.saving || !state.data;
    dom.saveBtn.textContent = state.saving ? (state.offline ? "导出中" : "保存中") : (state.offline ? "导出 JSON" : "保存");
  }

  function renderErrorState() {
    dom.cardList.innerHTML = state.error ? `<div class="empty-state">${escapeHtml(state.error)}</div>` : "";
    dom.editorHeader.innerHTML = "";
    dom.editorForm.innerHTML = `
      <div class="empty-state error-guide">
        <strong>未找到本地服务，也没有可用离线快照</strong>
        <span>直接双击 index.html 时，页面会读取同目录的 cards_snapshot.js；如果这个提示出现，说明离线快照缺失或加载失败。</span>
        <code>tools\\balance_studio\\start_balance_studio.bat</code>
        <span>或在仓库根目录执行：</span>
        <code>python tools\\balance_studio\\server.py --open</code>
      </div>
    `;
    dom.metricsPanel.innerHTML = "";
    dom.comparePanel.innerHTML = "";
    dom.overviewPanel.innerHTML = "";
    dom.warningsPanel.innerHTML = "";
  }

  function renderCardList() {
    const cards = filteredCards();
    updateSegments();

    if (!cards.length) {
      dom.cardList.innerHTML = '<div class="empty-state">没有匹配的卡牌</div>';
      return;
    }

    dom.cardList.innerHTML = cards.map((card) => {
      const metrics = cardMetrics(card);
      const meta = card.kind === "unit"
        ? `DPS ${formatNumber(metrics.cardDps)} · 生命 ${formatNumber(metrics.totalHp)}`
        : `伤害/费 ${formatNumber(metrics.damagePerMana)} · 面积 ${formatNumber(metrics.coverageArea)}`;
      return `
        <button class="card-row ${card.id === state.selectedId ? "is-active" : ""}" type="button" data-card-id="${escapeAttr(card.id)}">
          <span class="card-token" style="background:${safeColor(card.color)}">${escapeHtml(card.short_name || "?")}</span>
          <span class="card-title">
            <strong>${escapeHtml(card.name)}</strong>
            <span>${escapeHtml(card.role)} · ${escapeHtml(meta)}</span>
          </span>
          <span class="card-cost">${formatNumber(card.cost)}费</span>
        </button>
      `;
    }).join("");

    dom.cardList.querySelectorAll("[data-card-id]").forEach((row) => {
      row.addEventListener("click", () => {
        state.selectedId = row.dataset.cardId;
        if (state.compareId === state.selectedId) {
          state.compareId = secondCardId();
        }
        render();
      });
    });
  }

  function renderEditor() {
    const card = selectedCard();
    if (!card) {
      dom.editorHeader.innerHTML = "";
      dom.editorForm.innerHTML = '<div class="empty-state">请选择一张卡牌</div>';
      return;
    }

    const pillClass = state.error ? "is-error" : state.offline ? "is-offline" : state.dirty ? "is-dirty" : "";
    const statusText = state.error ? "校验错误" : state.dirty ? (state.offline ? "待导出" : "未保存") : state.offline ? "离线快照" : "已同步";
    dom.editorHeader.innerHTML = `
      <div class="section-title">
        <h2>${escapeHtml(card.name)}</h2>
        <p>${escapeHtml(card.id)} · ${escapeHtml(card.role)} · ${card.kind === "unit" ? "生物" : "法术"}</p>
      </div>
      <span class="status-pill ${pillClass}">${statusText}</span>
    `;

    const sections = [];
    fieldGroups.forEach((group) => {
      if (group.kind && group.kind !== card.kind) {
        return;
      }
      sections.push(renderFieldSection(card, group.title, group.fields));
    });
    sections.push(renderOverridesSection(card));
    dom.editorForm.innerHTML = sections.join("");
    bindEditorInputs(card);
  }

  function renderFieldSection(card, title, fields) {
    const controls = fields.map((field) => renderField(card, field)).join("");
    const gridClass = fields.some((field) => field.wide) ? "field-grid" : "field-grid";
    return `
      <section class="form-section">
        <h3>${escapeHtml(title)}</h3>
        <div class="${gridClass}">
          ${controls}
        </div>
      </section>
    `;
  }

  function renderOverridesSection(card) {
    const overrides = card.evolution && card.evolution.overrides ? card.evolution.overrides : {};
    const controls = overrideFields.map((field) => {
      const value = overrides[field.key];
      return renderRawField({
        path: `evolution.overrides.${field.key}`,
        label: field.label,
        type: field.type,
        step: field.step,
        options: field.options,
        optional: true,
        value: value === undefined ? "" : value
      });
    }).join("");
    return `
      <section class="form-section">
        <h3>进化覆盖值</h3>
        <div class="field-grid">
          ${controls}
        </div>
      </section>
    `;
  }

  function renderField(card, field) {
    return renderRawField({ ...field, value: getByPath(card, field.path) });
  }

  function renderRawField(field) {
    const value = field.value;
    const wide = field.wide ? " style=\"grid-column: 1 / -1\"" : "";
    const note = field.note ? `<small>${escapeHtml(field.note)}</small>` : "";

    if (field.type === "textarea") {
      return `
        <div class="field"${wide}>
          <label>${escapeHtml(field.label)}</label>
          <textarea data-path="${escapeAttr(field.path)}" data-type="text" ${field.readonly ? "readonly" : ""}>${escapeHtml(value || "")}</textarea>
          ${note}
        </div>
      `;
    }

    if (field.type === "select" || field.type === "select-card") {
      let options = field.type === "select-card" ? cardIdOptions(field.optional) : field.options;
      if (field.type === "select" && field.optional) {
        options = ["", ...options];
      }
      const optional = field.optional ? "true" : "false";
      return `
        <div class="field"${wide}>
          <label>${escapeHtml(field.label)}</label>
          <select data-path="${escapeAttr(field.path)}" data-type="text" data-optional="${optional}" ${field.readonly ? "disabled" : ""}>
            ${options.map((option) => `<option value="${escapeAttr(option)}" ${String(option) === String(value || "") ? "selected" : ""}>${escapeHtml(option || "未设置")}</option>`).join("")}
          </select>
          ${note}
        </div>
      `;
    }

    if (field.type === "checkbox") {
      return `
        <label class="checkbox-field"${wide}>
          <input data-path="${escapeAttr(field.path)}" data-type="checkbox" type="checkbox" ${value ? "checked" : ""}>
          <span>${escapeHtml(field.label)}</span>
        </label>
      `;
    }

    const inputType = field.type === "color" ? "color" : field.type === "number" ? "number" : "text";
    const dataType = field.type === "number" ? "number" : field.type === "tag-list" ? "tag-list" : "text";
    const optional = field.optional ? "true" : "false";
    const step = field.step ? ` step="${escapeAttr(String(field.step))}"` : "";
    const inputValue = field.type === "color" ? safeColor(value) : field.type === "tag-list" ? (Array.isArray(value) ? value.join(", ") : "") : value === undefined ? "" : value;
    return `
      <div class="field"${wide}>
        <label>${escapeHtml(field.label)}</label>
        <input data-path="${escapeAttr(field.path)}" data-type="${dataType}" data-optional="${optional}" type="${inputType}" value="${escapeAttr(inputValue)}"${step} ${field.readonly ? "readonly" : ""}>
        ${note}
      </div>
    `;
  }

  function bindEditorInputs(card) {
    dom.editorForm.querySelectorAll("[data-path]").forEach((input) => {
      input.addEventListener("input", () => {
        updateCardValue(card, input);
      });
      input.addEventListener("change", () => {
        updateCardValue(card, input);
      });
    });
  }

  function updateCardValue(card, input) {
    if (input.readOnly || input.disabled) {
      return;
    }
    const path = input.dataset.path;
    const type = input.dataset.type;
    const optional = input.dataset.optional === "true";
    let value;
    if (type === "checkbox") {
      value = input.checked;
    } else if (type === "tag-list") {
      value = [...new Set(input.value.split(/[,，]/).map((tag) => tag.trim()).filter(Boolean))];
    } else if (type === "number") {
      if (input.value.trim() === "" && optional) {
        deleteByPath(card, path);
        markDirty(path);
        return;
      }
      value = Number(input.value);
      if (Number.isNaN(value)) {
        return;
      }
    } else {
      if (input.value.trim() === "" && optional) {
        deleteByPath(card, path);
        markDirty(path);
        return;
      }
      value = input.value;
    }
    setByPath(card, path, value);
    markDirty(path);
  }

  function markDirty(path) {
    state.dirty = true;
    renderToolbar();
    renderCardList();
    renderMetrics();
    renderCompare();
    renderOverview();
    renderWarnings();
    if (path === "kind") {
      renderEditor();
    }
  }

  function renderMetrics() {
    const card = selectedCard();
    if (!card) {
      dom.metricsPanel.innerHTML = "";
      return;
    }
    const base = cardMetrics(card);
    const evolved = cardMetrics(evolvedCard(card));
    const tiles = card.kind === "unit"
      ? [
          metricTile("整卡 DPS", base.cardDps, evolved.cardDps),
          metricTile("单体 DPS", base.singleDps, evolved.singleDps),
          metricTile("总生命", base.totalHp, evolved.totalHp),
          metricTile("每费生命", base.hpPerMana, evolved.hpPerMana),
          metricTile("每费 DPS", base.dpsPerMana, evolved.dpsPerMana),
          metricTile("等费时间", base.waitSeconds, evolved.waitSeconds, "秒")
        ]
      : [
          metricTile("伤害/费", base.damagePerMana, evolved.damagePerMana),
          metricTile("基地伤害/费", base.baseDamagePerMana, evolved.baseDamagePerMana),
          metricTile("覆盖面积", base.coverageArea, evolved.coverageArea),
          metricTile("半径", base.radius, evolved.radius),
          metricTile("等费时间", base.waitSeconds, evolved.waitSeconds, "秒"),
          metricTile("模式", base.spellMode, evolved.spellMode)
        ];
    dom.metricsPanel.innerHTML = `
      <section class="metric-section">
        <h3>关键指标</h3>
        <div class="metric-grid">${tiles.join("")}</div>
      </section>
    `;
  }

  function metricTile(label, baseValue, evolvedValue, suffix) {
    const delta = numericDelta(baseValue, evolvedValue);
    const deltaClass = delta > 0 ? "up" : delta < 0 ? "down" : "";
    const deltaText = Number.isFinite(delta) && delta !== 0 ? `${delta > 0 ? "+" : ""}${formatNumber(delta)}${suffix || ""}` : "无变化";
    return `
      <div class="metric-tile">
        <div class="metric-label">${escapeHtml(label)}</div>
        <div class="metric-value">${escapeHtml(formatMetric(baseValue, suffix))}</div>
        <div class="metric-delta ${deltaClass}">进化 ${escapeHtml(deltaText)}</div>
      </div>
    `;
  }

  function renderCompare() {
    const cards = state.data.cards;
    const current = selectedCard();
    if (!current) {
      dom.comparePanel.innerHTML = "";
      return;
    }
    if (!state.compareId || state.compareId === state.selectedId) {
      state.compareId = cards.find((card) => card.id !== state.selectedId)?.id || "";
    }
    const compare = cards.find((card) => card.id === state.compareId);
    const options = cards
      .filter((card) => card.id !== state.selectedId)
      .map((card) => `<option value="${escapeAttr(card.id)}" ${card.id === state.compareId ? "selected" : ""}>${escapeHtml(card.name)}</option>`)
      .join("");
    const rows = compare ? compareRows(current, compare) : "";

    dom.comparePanel.innerHTML = `
      <section class="metric-section">
        <h3>双卡对照</h3>
        <select class="compare-select" id="compareSelect">${options}</select>
        <table class="mini-table">
          <thead><tr><th>指标</th><th>${escapeHtml(current.name)}</th><th>${escapeHtml(compare ? compare.name : "")}</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `;
    const select = document.getElementById("compareSelect");
    if (select) {
      select.addEventListener("change", () => {
        state.compareId = select.value;
        renderCompare();
      });
    }
  }

  function compareRows(left, right) {
    const leftMetrics = cardMetrics(left);
    const rightMetrics = cardMetrics(right);
    const rows = left.kind === "unit" && right.kind === "unit"
      ? [
          ["费用", left.cost, right.cost],
          ["整卡 DPS", leftMetrics.cardDps, rightMetrics.cardDps],
          ["总生命", leftMetrics.totalHp, rightMetrics.totalHp],
          ["每费 DPS", leftMetrics.dpsPerMana, rightMetrics.dpsPerMana],
          ["每费生命", leftMetrics.hpPerMana, rightMetrics.hpPerMana]
        ]
      : [
          ["费用", left.cost, right.cost],
          ["伤害/费", leftMetrics.damagePerMana, rightMetrics.damagePerMana],
          ["基地伤害/费", leftMetrics.baseDamagePerMana, rightMetrics.baseDamagePerMana],
          ["覆盖面积", leftMetrics.coverageArea, rightMetrics.coverageArea],
          ["等费时间", leftMetrics.waitSeconds, rightMetrics.waitSeconds]
        ];
    return rows.map(([label, leftValue, rightValue]) => `
      <tr>
        <td>${escapeHtml(label)}</td>
        <td>${escapeHtml(formatMetric(leftValue))}</td>
        <td>${escapeHtml(formatMetric(rightValue))}</td>
      </tr>
    `).join("");
  }

  function renderOverview() {
    const metrics = state.data.cards.map((card) => ({ card, metrics: cardMetrics(card) }));
    const maxValue = Math.max(...metrics.map((item) => overviewScore(item.card, item.metrics)), 1);
    const rows = metrics.map(({ card, metrics: itemMetrics }) => {
      const value = overviewScore(card, itemMetrics);
      return `
        <tr>
          <td>${escapeHtml(card.name)}</td>
          <td>${escapeHtml(card.kind === "unit" ? "生物" : "法术")}</td>
          <td>
            <div class="bar-cell">
              <span>${escapeHtml(formatNumber(value))}</span>
              <span class="bar-track"><span class="bar-fill" style="width:${Math.max(4, value / maxValue * 100)}%"></span></span>
            </div>
          </td>
        </tr>
      `;
    }).join("");
    dom.overviewPanel.innerHTML = `
      <section class="overview-section">
        <h3>效率矩阵</h3>
        <table class="mini-table">
          <thead><tr><th>卡牌</th><th>类型</th><th>主效率</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `;
  }

  function renderWarnings() {
    const warnings = validationWarnings();
    if (state.offline) {
      warnings.unshift({
        level: "offline",
        text: "当前为双击打开的离线快照模式：可查看、编辑和计算；导出 JSON 后需要手动替换 游戏工程/data/cards.json。"
      });
    }
    if (!warnings.length) {
      dom.warningsPanel.innerHTML = `
        <section class="warning-section">
          <h3>异常提示</h3>
          <div class="hint-text">当前没有明显结构错误或效率离群。</div>
        </section>
      `;
      return;
    }
    dom.warningsPanel.innerHTML = `
      <section class="warning-section">
        <h3>异常提示</h3>
        <div class="warning-list">
          ${warnings.map((item) => `<div class="warning-item ${item.level || ""}">${escapeHtml(item.text)}</div>`).join("")}
        </div>
      </section>
    `;
  }

  function renderFieldDocs() {
    if (!state.data || !state.data.field_definitions) {
      dom.fieldDocs.innerHTML = "";
      return;
    }
    const rules = state.data.global_rules || {};
    const ruleDocs = [
      ["地图长边", `${formatNumber(rules.map_long_edge_logic_units)} 逻辑单位`],
      ["生物半径倍率", `${formatNumber(rules.unit_radius_scale)} 倍`],
      ["费用回复", `${formatNumber(rules.mana_per_second)} 点/秒`],
      ["费用上限", `${formatNumber(rules.mana_max)} 点`],
      ["基地生命", `${formatNumber(rules.base_hp)} 点`]
    ].map(([label, value]) => `
      <article class="field-doc">
        <strong>${escapeHtml(label)}</strong>
        <p>${escapeHtml(value)}</p>
      </article>
    `).join("");

    const fieldDocs = Object.entries(state.data.field_definitions).map(([key, item]) => `
      <article class="field-doc">
        <strong>${escapeHtml(item.label || key)} · ${escapeHtml(key)}</strong>
        <p>${escapeHtml(item.unit || "无单位")} · ${escapeHtml(item.applies_to || "")}。${escapeHtml(item.notes || "")}</p>
      </article>
    `).join("");
    dom.fieldDocs.innerHTML = ruleDocs + fieldDocs;
  }

  function cardMetrics(card) {
    const rules = state.data?.global_rules || {};
    const manaPerSecond = numberOr(rules.mana_per_second, 0.5);
    const cost = Math.max(numberOr(card.cost, 0), 0);
    const waitSeconds = manaPerSecond > 0 ? cost / manaPerSecond : 0;

    if (card.kind === "unit") {
      const count = Math.max(numberOr(card.count, 0), 0);
      const damage = numberOr(card.damage, 0);
      const cooldown = numberOr(card.attack_cooldown, 0);
      const singleDps = cooldown > 0 ? damage / cooldown : 0;
      const multiTarget = Math.max(numberOr(card.multi_target_count, 1), 1);
      const cardDps = singleDps * count * multiTarget;
      const totalHp = numberOr(card.hp, 0) * count;
      const auraDps = numberOr(card.aura_interval, 0) > 0 ? numberOr(card.aura_damage, 0) / numberOr(card.aura_interval, 0) : 0;
      return {
        kind: "unit",
        cost,
        singleDps,
        cardDps,
        totalHp,
        dpsPerMana: cost > 0 ? cardDps / cost : 0,
        hpPerMana: cost > 0 ? totalHp / cost : 0,
        waitSeconds,
        auraDps,
        radius: numberOr(card.radius, 0),
        battleRadius: numberOr(card.radius, 0) * numberOr(rules.unit_radius_scale, 2)
      };
    }

    const radius = numberOr(card.radius, 0);
    return {
      kind: "spell",
      cost,
      damagePerMana: cost > 0 ? numberOr(card.damage, 0) / cost : 0,
      baseDamagePerMana: cost > 0 ? numberOr(card.base_damage, 0) / cost : 0,
      coverageArea: Math.PI * radius * radius,
      waitSeconds,
      radius,
      spellMode: card.spell_mode || "未设置"
    };
  }

  function evolvedCard(card) {
    const evolved = cloneData(card);
    if (!evolved.evolution || !evolved.evolution.overrides) {
      return evolved;
    }
    Object.entries(evolved.evolution.overrides).forEach(([key, value]) => {
      evolved[key] = value;
    });
    return evolved;
  }

  function validationWarnings() {
    if (!state.data) {
      return [];
    }
    const warnings = [];
    const ids = new Set();
    state.data.cards.forEach((card) => {
      if (ids.has(card.id)) {
        warnings.push({ level: "error", text: `id 重复：${card.id}` });
      }
      ids.add(card.id);
      if (!card.name || !card.short_name || !card.role) {
        warnings.push({ level: "error", text: `${card.id} 缺少基础文本字段。` });
      }
      if (numberOr(card.cost, -1) < 0) {
        warnings.push({ level: "error", text: `${card.name} 的费用不能为负数。` });
      }
      if (card.kind === "unit" && numberOr(card.attack_cooldown, 0) <= 0) {
        warnings.push({ level: "error", text: `${card.name} 的攻击间隔必须大于 0。` });
      }
    });

    const unitMetrics = state.data.cards.filter((card) => card.kind === "unit").map((card) => ({ card, metrics: cardMetrics(card) }));
    const avgDpsMana = average(unitMetrics.map((item) => item.metrics.dpsPerMana));
    const avgHpMana = average(unitMetrics.map((item) => item.metrics.hpPerMana));
    unitMetrics.forEach(({ card, metrics }) => {
      if (avgDpsMana > 0 && metrics.dpsPerMana > avgDpsMana * 1.45) {
        warnings.push({ text: `${card.name} 每费 DPS 明显高于生物均值。` });
      }
      if (avgHpMana > 0 && metrics.hpPerMana > avgHpMana * 1.45) {
        warnings.push({ text: `${card.name} 每费生命明显高于生物均值。` });
      }
      if (metrics.waitSeconds > 10) {
        warnings.push({ text: `${card.name} 从 0 费等待超过 10 秒。` });
      }
    });

    const spellMetrics = state.data.cards.filter((card) => card.kind === "spell").map((card) => ({ card, metrics: cardMetrics(card) }));
    const avgSpellDamage = average(spellMetrics.map((item) => item.metrics.damagePerMana));
    spellMetrics.forEach(({ card, metrics }) => {
      if (avgSpellDamage > 0 && metrics.damagePerMana > avgSpellDamage * 1.35) {
        warnings.push({ text: `${card.name} 对单位伤害/费高于法术均值。` });
      }
    });
    return warnings;
  }

  function overviewScore(card, metrics) {
    if (card.kind === "unit") {
      return metrics.dpsPerMana + metrics.hpPerMana / 12;
    }
    return metrics.damagePerMana + metrics.baseDamagePerMana + metrics.coverageArea / 50;
  }

  function filteredCards() {
    if (!state.data) {
      return [];
    }
    const query = state.search.toLowerCase();
    return state.data.cards.filter((card) => {
      const matchesType = state.filter === "all" || card.kind === state.filter;
      const haystack = `${card.id} ${card.name} ${card.role} ${card.trial_note}`.toLowerCase();
      return matchesType && (!query || haystack.includes(query));
    });
  }

  function selectedCard() {
    return state.data?.cards.find((card) => card.id === state.selectedId);
  }

  function ensureSelectedCard() {
    if (!state.data?.cards.length) {
      state.selectedId = "";
      return;
    }
    if (!selectedCard()) {
      state.selectedId = state.data.cards[0].id;
    }
  }

  function firstCardId() {
    return state.data?.cards[0]?.id || "";
  }

  function secondCardId() {
    return state.data?.cards.find((card) => card.id !== state.selectedId)?.id || "";
  }

  function updateSegments() {
    document.querySelectorAll("[data-filter]").forEach((button) => {
      button.classList.toggle("is-active", button.dataset.filter === state.filter);
    });
  }

  function cardIdOptions(includeEmpty) {
    const values = state.data?.cards.map((card) => card.id) || [];
    return includeEmpty ? ["", ...values] : values;
  }

  function getByPath(source, path) {
    return path.split(".").reduce((value, part) => {
      if (value === undefined || value === null) {
        return undefined;
      }
      return value[part];
    }, source);
  }

  function setByPath(source, path, value) {
    const parts = path.split(".");
    let cursor = source;
    parts.slice(0, -1).forEach((part) => {
      if (!cursor[part] || typeof cursor[part] !== "object") {
        cursor[part] = {};
      }
      cursor = cursor[part];
    });
    cursor[parts[parts.length - 1]] = value;
  }

  function deleteByPath(source, path) {
    const parts = path.split(".");
    let cursor = source;
    parts.slice(0, -1).forEach((part) => {
      if (!cursor[part] || typeof cursor[part] !== "object") {
        cursor[part] = {};
      }
      cursor = cursor[part];
    });
    delete cursor[parts[parts.length - 1]];
  }

  function average(values) {
    const finite = values.filter((value) => Number.isFinite(value));
    if (!finite.length) {
      return 0;
    }
    return finite.reduce((sum, value) => sum + value, 0) / finite.length;
  }

  function numericDelta(left, right) {
    if (typeof left === "number" && typeof right === "number") {
      return right - left;
    }
    return 0;
  }

  function numberOr(value, fallback) {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }

  function formatMetric(value, suffix) {
    if (typeof value === "string") {
      return value;
    }
    return `${formatNumber(value)}${suffix || ""}`;
  }

  function formatNumber(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return String(value ?? "");
    }
    if (Math.abs(number - Math.round(number)) < 0.005) {
      return String(Math.round(number));
    }
    return number.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
  }

  function safeColor(value) {
    return /^#[0-9a-f]{6}$/i.test(String(value)) ? value : "#8ac4f5";
  }

  function cloneData(value) {
    if (typeof structuredClone === "function") {
      return structuredClone(value);
    }
    return JSON.parse(JSON.stringify(value));
  }

  function showToast(message) {
    dom.toast.textContent = message;
    dom.toast.classList.add("is-visible");
    window.clearTimeout(showToast.timer);
    showToast.timer = window.setTimeout(() => {
      dom.toast.classList.remove("is-visible");
    }, 2800);
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function escapeAttr(value) {
    return escapeHtml(value);
  }
})();
