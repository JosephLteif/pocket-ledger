"use strict";

const views = {
  restore: document.querySelector("#restore-view"),
  pair: document.querySelector("#pair-view"),
  offline: document.querySelector("#offline-view"),
  dashboard: document.querySelector("#dashboard"),
};

const state = { ledger: null, kind: "expense", entryMode: "transaction", splitSequence: 0, metricData: null, metricsRequestSequence: 0, transactionVisibleLimit: 100, scheduleCostPeriod: "monthly" };
const currencyDigitsCache = new Map();
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function showView(name) {
  for (const [viewName, element] of Object.entries(views)) element.hidden = viewName !== name;
}

function errorText(body, fallback) {
  const message = body && (body.message || body.error);
  return typeof message === "string" && message.trim() ? message.slice(0, 240) : fallback;
}

async function request(path, options = {}) {
  let response;
  try {
    response = await fetch(path, {
      ...options,
      credentials: "same-origin",
      cache: "no-store",
      headers: { Accept: "application/json", ...(options.headers || {}) },
    });
  } catch {
    const error = new Error("Can’t reach your iPhone. Check that Pocket Ledger is open and PC Access is running.");
    error.networkError = true;
    throw error;
  }

  let body = null;
  if (response.status !== 204) {
    try {
      body = await response.json();
    } catch {
      body = null;
    }
  }
  if (!response.ok) {
    const fallback = response.status === 401 || response.status === 403
      ? "Your session has expired. Enter a current pairing code from your iPhone."
      : `The request could not be completed (${response.status}). Try again.`;
    const error = new Error(errorText(body, fallback));
    error.status = response.status;
    throw error;
  }
  return body;
}

function validateLedger(data) {
  if (
    !data || typeof data.currencyCode !== "string" ||
    !Array.isArray(data.accounts) || !Array.isArray(data.categories) ||
    !data.metrics || !Array.isArray(data.metrics.monthly) ||
    !Array.isArray(data.metrics.categoryExpenses) || !Array.isArray(data.transactions) ||
    !Array.isArray(data.schedules)
  ) {
    throw new Error("Pocket Ledger returned incomplete dashboard data. Update the app and try again.");
  }
  return data;
}

async function fetchLedger() {
  return validateLedger(await request("/api/bootstrap"));
}

function digitsFor(currencyCode) {
  if (!currencyDigitsCache.has(currencyCode)) {
    try {
      const digits = new Intl.NumberFormat(undefined, { style: "currency", currency: currencyCode }).resolvedOptions().maximumFractionDigits;
      currencyDigitsCache.set(currencyCode, digits);
    } catch {
      currencyDigitsCache.set(currencyCode, 2);
    }
  }
  return currencyDigitsCache.get(currencyCode);
}

function minorToMajor(minorUnits, currencyCode) {
  const value = Number(minorUnits);
  return (Number.isFinite(value) ? value : 0) / (10 ** digitsFor(currencyCode));
}

function formatMoney(minorUnits, currencyCode) {
  const value = minorToMajor(minorUnits, currencyCode);
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency: currencyCode }).format(value);
  } catch {
    return `${currencyCode} ${new Intl.NumberFormat(undefined, { maximumFractionDigits: digitsFor(currencyCode) }).format(value)}`;
  }
}

function formatCompactMoney(minorUnits, currencyCode) {
  const value = minorToMajor(minorUnits, currencyCode);
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency", currency: currencyCode, notation: "compact", maximumFractionDigits: 1,
    }).format(value);
  } catch {
    return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
  }
}

function formatDate(value) {
  if (typeof value !== "string" || !value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value.slice(0, 10);
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(date);
}

function monthLabel(value) {
  if (typeof value !== "string") return "";
  const match = /^(\d{4})-(\d{2})$/.exec(value);
  if (!match) return value.slice(0, 8);
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, 1));
  return new Intl.DateTimeFormat(undefined, { month: "short", timeZone: "UTC" }).format(date);
}

function setText(selector, value) {
  $(selector).textContent = value;
}

function svgElement(name, attributes = {}, content = "") {
  const element = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, String(value));
  if (content) element.textContent = content;
  return element;
}

function renderCashFlow(metrics, currencyCode) {
  const chart = $("#cashflow-chart");
  const empty = $("#cashflow-empty");
  const viewport = $("#cashflow-viewport");
  chart.replaceChildren();
  const months = metrics.monthly;
  if (!months.length) {
    viewport.hidden = true;
    empty.hidden = false;
    $("#cashflow-description").textContent = "No monthly income or expense data yet.";
    return;
  }

  empty.hidden = true;
  viewport.hidden = false;
  const width = Math.max(520, 72 * months.length + 52);
  const height = 244;
  const left = 58;
  const right = 14;
  const top = 12;
  const bottom = 38;
  const plotHeight = height - top - bottom;
  const plotWidth = width - left - right;
  const values = months.flatMap((month) => [Number(month.incomeMinorUnits) || 0, Number(month.expenseMinorUnits) || 0]);
  const max = Math.max(...values, 1);
  const roundedMax = Math.ceil(max / 4);
  chart.setAttribute("viewBox", `0 0 ${width} ${height}`);
  chart.setAttribute("preserveAspectRatio", "xMinYMin meet");
  chart.setAttribute("aria-label", `Income and expenses across ${months.length} months`);

  for (let tick = 0; tick <= 4; tick += 1) {
    const value = roundedMax * tick;
    const y = top + plotHeight - (tick / 4) * plotHeight;
    chart.append(svgElement("line", { x1: left, x2: width - right, y1: y, y2: y, class: "chart-gridline" }));
    chart.append(svgElement("text", { x: left - 9, y: y + 4, "text-anchor": "end", class: "chart-axis-label" }, formatCompactMoney(value, currencyCode)));
  }

  const groupWidth = plotWidth / months.length;
  const barWidth = Math.min(22, Math.max(8, groupWidth * 0.24));
  months.forEach((month, index) => {
    const center = left + groupWidth * (index + 0.5);
    const entries = [
      { key: "incomeMinorUnits", className: "income-bar", label: "Income" },
      { key: "expenseMinorUnits", className: "expense-bar", label: "Expenses" },
    ];
    entries.forEach((entry, seriesIndex) => {
      const amount = Math.max(0, Number(month[entry.key]) || 0);
      const barHeight = (amount / (roundedMax * 4 || 1)) * plotHeight;
      const x = center + (seriesIndex === 0 ? -barWidth - 2 : 2);
      const y = top + plotHeight - barHeight;
      const bar = svgElement("rect", { x, y, width: barWidth, height: Math.max(barHeight, amount ? 2 : 0), rx: 3, class: entry.className });
      bar.append(svgElement("title", {}, `${entry.label}: ${formatMoney(amount, currencyCode)}`));
      chart.append(bar);
    });
    chart.append(svgElement("text", { x: center, y: height - 12, "text-anchor": "middle", class: "chart-axis-label" }, monthLabel(month.month)));
  });

  const totalIncome = Number(metrics.incomeMinorUnits) || 0;
  const totalExpense = Number(metrics.expenseMinorUnits) || 0;
  $("#cashflow-description").textContent = `${months.length} months shown. Income totals ${formatMoney(totalIncome, currencyCode)} and expenses total ${formatMoney(totalExpense, currencyCode)}.`;
}

function renderCategories(metrics, currencyCode) {
  const list = $("#category-list");
  const empty = $("#category-empty");
  list.replaceChildren();
  const categories = [...(metrics.categoryExpenses || [])]
    .filter((item) => Number(item.amountMinorUnits) > 0)
    .sort((a, b) => Number(b.amountMinorUnits) - Number(a.amountMinorUnits));
  if (metrics.selectedCategoryID && Number(metrics.selectedCategoryDirectMinorUnits) > 0) {
    categories.unshift({
      categoryName: "Directly in this category",
      amountMinorUnits: metrics.selectedCategoryDirectMinorUnits,
      isSelectedCategoryDirect: true,
    });
  }
  $("#category-back").hidden = !metrics.selectedCategoryID;
  if (!categories.length) {
    empty.hidden = false;
    empty.textContent = metrics.selectedCategoryID ? "No spending in this category for this period." : "No categorized expenses for this period.";
    return;
  }
  empty.hidden = true;
  const max = Math.max(...categories.map((item) => Number(item.amountMinorUnits) || 0), 1);
  categories.forEach((item) => {
    const row = document.createElement("li");
    row.className = "category-item";
    const line = document.createElement("div");
    line.className = "category-line";
    const name = document.createElement("span");
    name.className = "category-name";
    name.textContent = item.categoryName || "Uncategorized";
    const amount = document.createElement("span");
    amount.className = "category-amount";
    amount.textContent = formatMoney(item.amountMinorUnits, currencyCode);
    line.append(name, amount);
    const track = document.createElement("div");
    track.className = "category-track";
    track.setAttribute("aria-hidden", "true");
    const bar = document.createElement("span");
    bar.className = "category-fill";
    bar.style.width = `${Math.min(100, (Number(item.amountMinorUnits) / max) * 100)}%`;
    track.append(bar);
    if (item.categoryID && !item.isSelectedCategoryDirect) {
      const drilldown = document.createElement("button");
      drilldown.type = "button";
      drilldown.className = "category-drilldown";
      drilldown.dataset.categoryId = item.categoryID;
      drilldown.setAttribute("aria-label", `View ${item.categoryName} and its subcategories`);
      drilldown.append(line, track);
      row.append(drilldown);
    } else {
      row.append(line, track);
    }
    list.append(row);
  });
}

function renderAccounts(ledger) {
  const list = $("#account-list");
  list.replaceChildren();
  const accounts = ledger.accounts;
  setText("#account-count", new Intl.NumberFormat().format(accounts.length));
  setText("#accounts-total", `${accounts.length} ${accounts.length === 1 ? "account" : "accounts"}`);
  if (!accounts.length) {
    const empty = document.createElement("p");
    empty.className = "account-empty";
    empty.textContent = "No accounts yet. Add an account in Pocket Ledger on your iPhone.";
    list.append(empty);
  }
  accounts.forEach((account, index) => {
    const row = document.createElement("div");
    row.className = "account-row";
    const identity = document.createElement("div");
    identity.className = "account-identity";
    const marker = document.createElement("span");
    marker.className = `account-marker marker-${index % 4}`;
    marker.setAttribute("aria-hidden", "true");
    const name = document.createElement("strong");
    name.textContent = account.name || "Account";
    const currency = document.createElement("small");
    currency.textContent = account.currencyCode || ledger.currencyCode;
    identity.append(marker, name, currency);
    const balance = document.createElement("span");
    balance.className = "account-balance";
    balance.textContent = formatMoney(account.balanceMinorUnits, account.currencyCode || ledger.currencyCode);
    row.append(identity, balance);
    list.append(row);
  });
}

function recurringExpenseEstimate(schedules, period) {
  const multipliers = period === "yearly"
    ? { daily: 365.2425, weekly: 52.1775, monthly: 12, yearly: 1 }
    : { daily: 365.2425 / 12, weekly: 52.1775 / 12, monthly: 1, yearly: 1 / 12 };
  const totals = new Map();
  schedules.filter((schedule) => schedule.isEnabled && schedule.kind === "expense" && schedule.frequency !== "once")
    .forEach((schedule) => (Array.isArray(schedule.splits) ? schedule.splits : []).forEach((split) => {
      const currencyCode = split.currencyCode || "USD";
      const amount = Math.abs(Number(split.amountMinorUnits) || 0) * (multipliers[schedule.frequency] || 0);
      totals.set(currencyCode, (totals.get(currencyCode) || 0) + amount);
    }));
  return [...totals].map(([currencyCode, amount]) => ({
    currencyCode,
    amountMinorUnits: Math.round(amount),
  })).sort((a, b) => a.currencyCode.localeCompare(b.currencyCode));
}

function renderSchedules(ledger) {
  const list = $("#schedule-list");
  const schedules = [...ledger.schedules].sort((a, b) => String(a.nextRunDate).localeCompare(String(b.nextRunDate)));
  const enabledCount = schedules.filter((schedule) => schedule.isEnabled).length;
  const estimate = recurringExpenseEstimate(schedules, state.scheduleCostPeriod);
  const periodLabel = state.scheduleCostPeriod === "yearly" ? "year" : "month";
  setText("#recurring-expense-total", estimate.length
    ? estimate.map((item) => `${item.currencyCode} ${formatMoney(item.amountMinorUnits, item.currencyCode)}`).join(" · ")
    : "No active recurring expenses.");
  setText("#schedule-count", `${enabledCount} enabled · ${schedules.length} total`);
  list.replaceChildren();
  if (!schedules.length) {
    const empty = document.createElement("p");
    empty.className = "schedule-empty";
    empty.textContent = "No schedules yet. Add a schedule to plan a recurring income or expense.";
    list.append(empty);
    return;
  }

  const frequencyNames = { once: "Once", daily: "Daily", weekly: "Weekly", monthly: "Monthly", yearly: "Yearly" };
  schedules.forEach((schedule) => {
    const row = document.createElement("article");
    row.className = "schedule-card";
    const copy = document.createElement("div");
    copy.className = "schedule-copy";
    const titleRow = document.createElement("div");
    titleRow.className = "schedule-title-row";
    const title = document.createElement("strong");
    title.className = "schedule-title";
    title.textContent = schedule.note || (schedule.kind === "income" ? "Scheduled income" : schedule.kind === "transfer" ? "Scheduled transfer" : "Scheduled expense");
    const completed = schedule.frequency === "once" && Boolean(schedule.lastRunDate);
    const status = document.createElement("span");
    status.className = `schedule-status${schedule.isEnabled ? "" : " is-paused"}`;
    status.textContent = schedule.isEnabled ? "Enabled" : completed ? "Completed" : "Paused";
    titleRow.append(title, status);
    const meta = document.createElement("p");
    meta.className = "schedule-meta";
    meta.textContent = `${frequencyNames[schedule.frequency] || "Repeats"} · ${schedule.isEnabled ? "Next" : completed ? "Recorded" : "Next"} ${formatDate(completed ? schedule.lastRunDate : schedule.nextRunDate)}`;
    const detail = document.createElement("p");
    detail.className = "schedule-detail";
    const splits = Array.isArray(schedule.splits) ? schedule.splits : [];
    const splitDetails = splits.map((split) => [
      formatMoney(Math.abs(Number(split.amountMinorUnits) || 0), split.currencyCode || ledger.currencyCode),
      split.accountName,
      split.categoryName,
    ].filter(Boolean).join(" · ")).join(" / ") || "Account unavailable";
    const scheduleEstimate = recurringExpenseEstimate([schedule], state.scheduleCostPeriod);
    const estimateDetails = scheduleEstimate.map((item) => `${item.currencyCode} ${formatMoney(item.amountMinorUnits, item.currencyCode)} / ${periodLabel}`).join(" · ");
    detail.textContent = estimateDetails ? `${splitDetails} · ≈ ${estimateDetails}` : splitDetails;
    copy.append(titleRow, meta, detail);

    const actions = document.createElement("div");
    actions.className = "schedule-actions";
    if (!completed) {
      actions.append(scheduleActionButton(schedule, schedule.isEnabled ? "Pause" : "Resume", schedule.isEnabled ? "pause" : "resume"));
    }
    if (schedule.isEnabled) {
      actions.append(scheduleActionButton(schedule, "Skip next", "skip"));
      actions.append(scheduleActionButton(schedule, "Record now", "record", true));
    }
    actions.append(scheduleActionButton(schedule, "Delete", "delete"));
    row.append(copy, actions);
    list.append(row);
  });
}

function scheduleActionButton(schedule, label, action, primary = false) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `button ${primary ? "button-primary" : "button-secondary"} button-small${action === "delete" ? " schedule-delete" : ""}`;
  button.textContent = label;
  button.setAttribute("aria-label", `${label} ${schedule.note || "scheduled transaction"}`);
  button.addEventListener("click", async () => {
    if (action === "delete" && !window.confirm(`Delete “${schedule.note || "scheduled transaction"}”?`)) return;
    button.disabled = true;
    let actionCompleted = false;
    try {
      await request("/api/schedules/action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: schedule.id, action }),
      });
      actionCompleted = true;
      const messages = {
        record: "Scheduled transaction recorded.",
        skip: "Next scheduled entry skipped.",
        pause: "Schedule paused.",
        resume: "Schedule enabled.",
        delete: "Schedule deleted.",
      };
      populateDashboard(await fetchLedger());
      showDashboardFeedback(messages[action]);
      await refreshMetrics();
    } catch (error) {
      showDashboardFeedback(actionCompleted
        ? "The schedule action completed, but the page could not refresh. Reload before repeating it."
        : error.message || "The schedule could not be updated. Try again.", true);
      button.disabled = actionCompleted;
    }
  });
  return button;
}

function makeCell(text, className = "") {
  const cell = document.createElement("td");
  if (className) cell.className = className;
  cell.textContent = text;
  return cell;
}

function categoryMatches(categoryID, selectedCategoryID) {
  let category = state.ledger.categories.find((item) => String(item.id) === String(categoryID));
  while (category) {
    if (String(category.id) === String(selectedCategoryID)) return true;
    category = state.ledger.categories.find((item) => String(item.id) === String(category.parentID));
  }
  return false;
}

function renderTransactions() {
  const ledger = state.ledger;
  const body = $("#transaction-rows");
  const empty = $("#transaction-empty");
  body.replaceChildren();
  const query = $("#transaction-search").value.trim().toLocaleLowerCase();
  const kindFilter = $("#transaction-filter").value;
  const categoryFilter = $("#transaction-category-filter").value;
  const accountFilter = $("#transaction-account-filter").value;
  const transactions = [...ledger.transactions]
    .filter((item) => kindFilter === "all" || item.kind === kindFilter)
    .filter((item) => !categoryFilter || item.splits.some((split) => categoryMatches(split.categoryID, categoryFilter)))
    .filter((item) => !accountFilter || item.splits.some((split) => String(split.accountID) === accountFilter))
    .filter((item) => {
      if (!query) return true;
      const splits = Array.isArray(item.splits) ? item.splits : [];
      const searchable = [
        item.note,
        item.categoryName,
        item.kind,
        item.date,
        item.currencyCode,
        ...splits.flatMap((split) => [
          split.accountName,
          split.categoryName,
          formatMoney(Math.abs(Number(split.amountMinorUnits) || 0), split.currencyCode || item.currencyCode),
        ]),
      ].join(" ").toLocaleLowerCase();
      return searchable.includes(query);
    });

  setText("#transaction-count", `${Math.min(transactions.length, state.transactionVisibleLimit)} of ${transactions.length} ${transactions.length === 1 ? "transaction" : "transactions"}`);
  $("#load-more-transactions").hidden = transactions.length <= state.transactionVisibleLimit;
  if (!transactions.length) {
    empty.hidden = false;
    empty.textContent = ledger.transactions.length ? "No transactions match these filters." : "No transactions yet. Add one to start filling your ledger.";
    return;
  }
  empty.hidden = true;
  transactions.slice(0, state.transactionVisibleLimit).forEach((transaction) => {
    const row = document.createElement("tr");
    const description = document.createElement("td");
    description.className = "description-cell";
    const title = document.createElement("strong");
    title.textContent = transaction.note || (transaction.kind === "transfer" ? "Transfer" : transaction.kind === "income" ? "Income" : "Expense");
    const detail = document.createElement("small");
    const splitCount = Number(transaction.splitCount) || 0;
    const splits = Array.isArray(transaction.splits) ? transaction.splits : [];
    detail.textContent = splits.length
      ? splits.map((split) => [
          formatMoney(Math.abs(Number(split.amountMinorUnits) || 0), split.currencyCode || transaction.currencyCode),
          split.accountName,
          split.categoryName || (transaction.kind === "transfer" ? "" : "Uncategorized"),
        ].filter(Boolean).join(" · ")).join(" / ")
      : splitCount > 1 ? `${splitCount} splits` : splitCount === 1 ? "1 split" : "";
    description.append(title, detail);
    const kind = transaction.kind === "transfer" ? "transfer" : transaction.kind === "income" ? "income" : "expense";
    const kindCell = document.createElement("td");
    const badge = document.createElement("span");
    badge.className = `kind-badge ${kind}`;
    badge.textContent = kind === "transfer" ? "Transfer" : kind === "income" ? "Income" : "Expense";
    kindCell.append(badge);
    const amountSign = kind === "income" ? "+" : kind === "expense" ? "−" : "";
    const amount = document.createElement("td");
    amount.className = `amount-cell ${kind}`;
    amount.textContent = `${amountSign}${formatMoney(Math.abs(Number(transaction.amountMinorUnits) || 0), transaction.currencyCode || ledger.currencyCode)}`;
    row.append(
      makeCell(formatDate(transaction.date), "date-cell"),
      description,
      makeCell(transaction.categoryName || (kind === "transfer" ? "—" : "Uncategorized"), "category-cell"),
      kindCell,
      amount,
    );
    body.append(row);
  });
}

function populateDashboard(data) {
  state.metricsRequestSequence += 1;
  state.ledger = data;
  populateDashboardFilters(data);
  if (!state.metricData) {
    state.metricData = {
      currencyCode: data.currencyCode,
      incomeMinorUnits: data.metrics.monthIncomeMinorUnits,
      expenseMinorUnits: data.metrics.monthExpenseMinorUnits,
      selectedCategoryID: null,
      categoryExpenses: data.metrics.categoryExpenses,
      monthly: data.metrics.monthly,
    };
  }
  setText("#total-balance", formatMoney(data.metrics.totalBalanceMinorUnits, data.currencyCode));
  updateMetricDisplay(state.metricData, state.metricData.currencyCode || data.currencyCode);
  renderAccounts(data);
  renderSchedules(data);
  renderTransactions();
  refreshAccountOptions();
}

function populateDashboardFilters(data) {
  const fillSelect = (selector, placeholder, options) => {
    const select = $(selector);
    const previous = select.value;
    select.replaceChildren(new Option(placeholder, ""));
    options.forEach((item) => select.add(new Option(item.name, String(item.id))));
    if (options.some((item) => String(item.id) === previous)) select.value = previous;
  };
  fillSelect("#transaction-category-filter", "All categories", data.categories);
  fillSelect("#metrics-category", "All categories", data.categories);
  fillSelect("#transaction-account-filter", "All accounts", data.accounts);

  const currency = $("#metrics-currency");
  const previousCurrency = currency.value;
  const currencies = [...new Set([data.currencyCode, ...data.accounts.map((account) => account.currencyCode)].filter(Boolean))];
  currency.replaceChildren(...currencies.map((code) => new Option(code, code)));
  currency.value = currencies.includes(previousCurrency) ? previousCurrency : data.currencyCode;
}

function updateMetricDisplay(metrics, currencyCode) {
  setText("#month-income", formatMoney(metrics.incomeMinorUnits, currencyCode));
  setText("#month-expense", formatMoney(metrics.expenseMinorUnits, currencyCode));
  setText("#cashflow-subtitle", metricsPeriodLabel());
  setText("#category-title", metrics.selectedCategoryName || "Where it goes");
  setText("#category-subtitle", metrics.selectedCategoryName
    ? `Expenses in ${metrics.selectedCategoryName} and its subcategories`
    : `Expenses by category · ${metricsPeriodLabel()}`);
  renderCashFlow(metrics, currencyCode);
  renderCategories(metrics, currencyCode);
}

function metricsPeriodLabel() {
  const period = $("#metrics-period").value;
  if (period === "custom") return `${$("#metrics-start").value} – ${$("#metrics-end").value}`;
  if (period === "year") return $("#metrics-year").value || "This year";
  const [year, month] = $("#metrics-anchor").value.split("-").map(Number);
  if (!year || !month) return "This month";
  return new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" }).format(new Date(year, month - 1, 1));
}

function metricsDateRange() {
  const period = $("#metrics-period").value;
  let start;
  let end;
  if (period === "custom") {
    const startValue = $("#metrics-start").value;
    const endValue = $("#metrics-end").value;
    if (!startValue || !endValue) {
      $("#metrics-start").reportValidity();
      $("#metrics-end").reportValidity();
      return null;
    }
    start = new Date(`${startValue}T00:00:00`);
    const lastDay = new Date(`${endValue}T00:00:00`);
    if (lastDay < start) {
      $("#metrics-end").setCustomValidity("The end date must be on or after the start date.");
      $("#metrics-end").reportValidity();
      return null;
    }
    $("#metrics-end").setCustomValidity("");
    end = new Date(lastDay);
    end.setDate(end.getDate() + 1);
  } else {
    if (period === "year") {
      const year = Number($("#metrics-year").value);
      if (!$("#metrics-year").reportValidity() || !year) return null;
      start = new Date(year, 0, 1);
      end = new Date(year + 1, 0, 1);
    } else {
      const [year, month] = $("#metrics-anchor").value.split("-").map(Number);
      if (!year || !month) {
        $("#metrics-anchor").reportValidity();
        return null;
      }
      start = new Date(year, month - 1, 1);
      end = new Date(year, month, 1);
    }
  }
  return { startDate: start.toISOString(), endDate: end.toISOString() };
}

function updateMetricPeriodFields() {
  const period = $("#metrics-period").value;
  const isCustom = period === "custom";
  $("#metrics-anchor-field").hidden = period !== "month";
  $("#metrics-year-field").hidden = period !== "year";
  $("#metrics-range-fields").hidden = !isCustom;
  $("#metrics-anchor-label").textContent = "Month";
  $("#metrics-anchor").setAttribute("aria-label", "Metric month");
}

async function refreshMetrics() {
  if (!state.ledger) return;
  const range = metricsDateRange();
  if (!range) return;
  const requestSequence = ++state.metricsRequestSequence;
  $("#metrics-status").hidden = false;
  try {
    const metrics = await request("/api/metrics", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...range,
        currencyCode: $("#metrics-currency").value,
        categoryID: $("#metrics-category").value || null,
      }),
    });
    if (requestSequence !== state.metricsRequestSequence) return;
    state.metricData = metrics;
    updateMetricDisplay(metrics, metrics.currencyCode);
  } catch (error) {
    if (requestSequence === state.metricsRequestSequence) showDashboardFeedback(error.message || "Metrics could not be updated.", true);
  } finally {
    if (requestSequence === state.metricsRequestSequence) $("#metrics-status").hidden = true;
  }
}

async function openLedger() {
  showView("restore");
  try {
    populateDashboard(await fetchLedger());
    showView("dashboard");
    await refreshMetrics();
  } catch (error) {
    if (error.status === 401 || error.status === 403) {
      showView("pair");
      $("#pair-error").hidden = true;
      $("#pair-code").focus();
    } else {
      $("#offline-copy").textContent = error.message || "Check that Pocket Ledger is open and PC Access is running, then try again.";
      showView("offline");
    }
  }
}

$("#pair-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = $("#pair-code");
  const button = $("#pair-button");
  const feedback = $("#pair-error");
  const code = input.value.trim();
  if (!code) {
    input.focus();
    return;
  }
  feedback.hidden = true;
  button.disabled = true;
  button.textContent = "Connecting…";
  try {
    await request("/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    input.value = "";
    populateDashboard(await fetchLedger());
    showView("dashboard");
    await refreshMetrics();
  } catch (error) {
    feedback.textContent = error.status === 401 || error.status === 403
      ? "That code is incorrect or expired. Check the current code on your iPhone and try again."
      : error.message || "Couldn’t connect. Check the code and try again.";
    feedback.hidden = false;
    input.focus();
  } finally {
    button.disabled = false;
    button.textContent = "Connect";
  }
});

$("#retry-button").addEventListener("click", openLedger);

function localDateValue(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function refreshAccountOptions() {
  $$(".split-row").forEach((row) => {
    const select = $(".split-account", row);
    const previousValue = select.value;
    select.replaceChildren(new Option("Choose an account", ""));
    state.ledger.accounts.forEach((account) => select.add(new Option(account.name || "Account", String(account.id))));
    if (state.ledger.accounts.some((account) => String(account.id) === previousValue)) select.value = previousValue;
    updateAmountStep(row);
  });
  const hasAccounts = state.ledger.accounts.length > 0;
  $("#no-accounts-message").hidden = hasAccounts;
  $("#save-transaction").disabled = !hasAccounts;
}

function updateAmountStep(row) {
  const accountId = $(".split-account", row).value;
  const account = state.ledger.accounts.find((item) => String(item.id) === accountId);
  const input = $(".split-amount", row);
  if (!account) {
    input.step = "0.01";
    return;
  }
  const digits = digitsFor(account.currencyCode || state.ledger.currencyCode);
  input.step = digits ? `0.${"0".repeat(digits - 1)}1` : "1";
}

function createSplitRow() {
  state.splitSequence += 1;
  const suffix = state.splitSequence;
  const row = document.createElement("fieldset");
  row.className = "split-row";
  row.innerHTML = `
    <legend class="sr-only"></legend>
    <div class="split-row-top"><span class="split-number"></span><button class="remove-split" type="button" aria-label="Remove split">Remove</button></div>
    <div class="split-fields">
      <div class="field-group"><label for="split-${suffix}-account">Account</label><select id="split-${suffix}-account" class="split-account" required><option value="">Choose an account</option></select></div>
      <div class="field-group"><label for="split-${suffix}-amount">Amount</label><input id="split-${suffix}-amount" class="split-amount" type="number" inputmode="decimal" min="0" step="0.01" placeholder="0.00" required></div>
      <div class="field-group"><label for="split-${suffix}-category">Category</label><select id="split-${suffix}-category" class="split-category"><option value="">No category</option></select></div>
    </div>`;
  const number = `Split ${state.splitSequence}`;
  $("legend", row).textContent = number;
  $(".split-number", row).textContent = number;
  const accountSelect = $(".split-account", row);
  state.ledger.accounts.forEach((account) => accountSelect.add(new Option(account.name || "Account", String(account.id))));
  const categorySelect = $(".split-category", row);
  state.ledger.categories.forEach((category) => categorySelect.add(new Option(category.name, String(category.id))));
  $(".split-account", row).addEventListener("change", () => updateAmountStep(row));
  $(".split-amount", row).addEventListener("input", (event) => event.currentTarget.setCustomValidity(""));
  $(".remove-split", row).addEventListener("click", () => {
    row.remove();
    renumberSplits();
  });
  return row;
}

function renumberSplits() {
  const rows = $$(".split-row", $("#split-rows"));
  $("#add-split").disabled = rows.length >= 50;
  rows.forEach((row, index) => {
    const name = `Split ${index + 1}`;
    $("legend", row).textContent = name;
    $(".split-number", row).textContent = name;
    $(".remove-split", row).hidden = rows.length === 1;
  });
}

function setKind(kind) {
  state.kind = kind;
  $$("#transaction-form [data-kind]").forEach((button) => {
    const selected = button.dataset.kind === kind;
    button.classList.toggle("is-selected", selected);
    button.setAttribute("aria-pressed", String(selected));
  });
}

function setEntryMode(mode) {
  if (mode === "schedule" && state.entryMode !== "schedule" && $("#transaction-date").value === localDateValue()) {
    const firstRun = new Date();
    firstRun.setDate(firstRun.getDate() + 1);
    $("#transaction-date").value = localDateValue(firstRun);
  }
  state.entryMode = mode;
  $$("#entry-mode-switch [data-mode]").forEach((button) => {
    const selected = button.dataset.mode === mode;
    button.classList.toggle("is-selected", selected);
    button.setAttribute("aria-pressed", String(selected));
  });
  $("#schedule-fields").hidden = mode !== "schedule";
  $("#transaction-date-label").textContent = mode === "schedule" ? "First run" : "Date";
  $("#entry-title").textContent = mode === "schedule" ? "Add schedule" : "Add transaction";
  $("#entry-title").nextElementSibling.textContent = mode === "schedule"
    ? "Choose a future first run and how often it should repeat."
    : "Each split is saved to its own account and category.";
  $("#save-transaction").textContent = mode === "schedule" ? "Save schedule" : "Save transaction";
  $("#monthly-rule-field").hidden = $("#schedule-frequency").value !== "monthly";
  alignLastDayScheduleDate();
}

function alignLastDayScheduleDate() {
  const dateValue = $("#transaction-date").value;
  if (state.entryMode !== "schedule" || $("#schedule-frequency").value !== "monthly" ||
      $("#schedule-monthly-rule").value !== "lastDayOfMonth" || !dateValue) return;
  const [year, month] = dateValue.split("-").map(Number);
  $("#transaction-date").value = localDateValue(new Date(year, month, 0));
}

$(".kind-switch").addEventListener("click", (event) => {
  const button = event.target.closest("[data-kind]");
  if (button) setKind(button.dataset.kind);
});

$("#add-split").addEventListener("click", () => {
  const rows = $("#split-rows");
  if ($$(".split-row", rows).length >= 50) return;
  rows.append(createSplitRow());
  renumberSplits();
  $(".split-account", rows.lastElementChild).focus();
});

function openEntry(mode = "transaction") {
  setEntryMode(mode);
  const panel = $("#entry-panel");
  panel.hidden = false;
  panel.scrollIntoView({ behavior: "smooth", block: "start" });
  $("#transaction-date").focus({ preventScroll: true });
}

$("#open-entry").addEventListener("click", () => openEntry());
$("#add-schedule").addEventListener("click", () => openEntry("schedule"));
$("#entry-mode-switch").addEventListener("click", (event) => {
  const button = event.target.closest("[data-mode]");
  if (button) setEntryMode(button.dataset.mode);
});
$("#schedule-frequency").addEventListener("change", () => {
  $("#monthly-rule-field").hidden = $("#schedule-frequency").value !== "monthly";
  alignLastDayScheduleDate();
});
$("#schedule-monthly-rule").addEventListener("change", alignLastDayScheduleDate);
$("#transaction-date").addEventListener("change", alignLastDayScheduleDate);
$("#close-entry").addEventListener("click", () => {
  $("#entry-panel").hidden = true;
  $("#open-entry").focus();
});

function showDashboardFeedback(message, isError = false) {
  const feedback = $("#dashboard-feedback");
  feedback.textContent = message;
  feedback.classList.toggle("is-error", isError);
  feedback.hidden = !message;
}

$("#transaction-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const feedback = $("#form-feedback");
  const submit = $("#save-transaction");
  const isSchedule = state.entryMode === "schedule";
  const entryName = isSchedule ? "schedule" : "transaction";
  feedback.textContent = "";
  const date = $("#transaction-date").value;
  if (!date) {
    $("#transaction-date").reportValidity();
    return;
  }
  const splitRows = $$(".split-row", $("#split-rows"));
  const splits = [];
  for (const row of splitRows) {
    const amountInput = $(".split-amount", row);
    const amount = amountInput.value.trim();
    if (!/^\d+(?:\.\d+)?$/.test(amount) || Number(amount) <= 0) {
      amountInput.setCustomValidity("Enter a positive amount using digits and a decimal point.");
      amountInput.reportValidity();
      return;
    }
    amountInput.setCustomValidity("");
    splits.push({
      accountID: $(".split-account", row).value,
      amount,
      categoryID: $(".split-category", row).value || null,
    });
  }
  if (!form.reportValidity()) return;
  const splitCurrencies = new Set(splitRows.map((row) => {
    const accountID = $(".split-account", row).value;
    const account = state.ledger.accounts.find((item) => String(item.id) === accountID);
    return String(account.currencyCode || state.ledger.currencyCode).toUpperCase();
  }));
  if (splitCurrencies.size > 1) {
    feedback.textContent = `All splits in one ${entryName} must use accounts with the same currency. Choose matching accounts to continue.`;
    feedback.className = "form-feedback error-feedback";
    return;
  }

  submit.disabled = true;
  submit.textContent = isSchedule ? "Saving schedule…" : "Saving transaction…";
  try {
    await request(isSchedule ? "/api/schedules" : "/api/transactions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(isSchedule ? {
        nextRunDate: new Date(`${date}T00:00:00.000Z`).toISOString(),
        frequency: $("#schedule-frequency").value,
        monthlyRule: $("#schedule-monthly-rule").value,
        note: $("#transaction-note").value.trim(),
        kind: state.kind,
        splits,
      } : {
        date: new Date(`${date}T00:00:00.000Z`).toISOString(),
        note: $("#transaction-note").value.trim(),
        kind: state.kind,
        splits,
      }),
    });
    form.reset();
    setKind("expense");
    setEntryMode("transaction");
    $("#transaction-date").value = localDateValue();
    $("#split-rows").replaceChildren(createSplitRow());
    renumberSplits();
    $("#entry-panel").hidden = true;
    showDashboardFeedback(isSchedule ? "Schedule saved to your ledger." : "Transaction saved to your ledger.");
    try {
      populateDashboard(await fetchLedger());
      await refreshMetrics();
    } catch {
      showDashboardFeedback(`${isSchedule ? "Schedule" : "Transaction"} saved, but the ledger view couldn’t refresh. Check ${isSchedule ? "Schedules" : "Transactions"} before submitting it again.`, true);
    }
    $("#open-entry").focus();
  } catch (error) {
    const currencyRejection = /currency/i.test(error.message) && /(same|different|mixed|multiple|more than one|match|mismatch)/i.test(error.message);
    feedback.textContent = currencyRejection
      ? `All splits in one ${entryName} must use accounts with the same currency. Choose matching accounts to continue.`
      : error.networkError
        ? `The connection ended before Pocket Ledger confirmed the save. Check ${isSchedule ? "Schedules" : "Transactions"} before trying again to avoid a duplicate.`
        : error.message || `Couldn’t save this ${entryName}. Check the details and try again.`;
    feedback.className = "form-feedback error-feedback";
  } finally {
    submit.disabled = !state.ledger.accounts.length;
    submit.textContent = state.entryMode === "schedule" ? "Save schedule" : "Save transaction";
  }
});

const today = new Date();
$("#metrics-anchor").value = localDateValue(today).slice(0, 7);
$("#metrics-year").value = today.getFullYear();
$("#metrics-start").value = localDateValue(new Date(today.getFullYear(), today.getMonth(), 1));
$("#metrics-end").value = localDateValue(today);
$("#transaction-date").value = localDateValue(today);
updateMetricPeriodFields();
setEntryMode("transaction");

function resetTransactionResults() {
  state.transactionVisibleLimit = 100;
  renderTransactions();
}

$("#transaction-search").addEventListener("input", resetTransactionResults);
$("#transaction-filter").addEventListener("change", resetTransactionResults);
$("#transaction-category-filter").addEventListener("change", resetTransactionResults);
$("#transaction-account-filter").addEventListener("change", resetTransactionResults);
$("#load-more-transactions").addEventListener("click", () => {
  state.transactionVisibleLimit += 100;
  renderTransactions();
});
$("#schedule-cost-period").addEventListener("click", (event) => {
  const button = event.target.closest("[data-cost-period]");
  if (!button || !state.ledger) return;
  state.scheduleCostPeriod = button.dataset.costPeriod;
  $$("#schedule-cost-period [data-cost-period]").forEach((item) => {
    const selected = item === button;
    item.classList.toggle("is-selected", selected);
    item.setAttribute("aria-pressed", String(selected));
  });
  renderSchedules(state.ledger);
});
$("#metrics-period").addEventListener("change", () => {
  updateMetricPeriodFields();
  refreshMetrics();
});
$("#metrics-anchor").addEventListener("change", refreshMetrics);
$("#metrics-year").addEventListener("change", refreshMetrics);
$("#metrics-start").addEventListener("change", refreshMetrics);
$("#metrics-end").addEventListener("change", refreshMetrics);
$("#metrics-currency").addEventListener("change", refreshMetrics);
$("#metrics-category").addEventListener("change", refreshMetrics);
$("#category-back").addEventListener("click", () => {
  $("#metrics-category").value = "";
  refreshMetrics();
});
$("#category-list").addEventListener("click", (event) => {
  const button = event.target.closest("[data-category-id]");
  if (!button) return;
  $("#metrics-category").value = button.dataset.categoryId;
  refreshMetrics();
});

$(".primary-nav").addEventListener("click", (event) => {
  const link = event.target.closest(".nav-link");
  if (!link) return;
  $$(".nav-link").forEach((item) => item.classList.toggle("is-active", item === link));
});

openLedger();
