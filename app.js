const OFFICIAL_PRICES = {
  'gpt-5.6-sol':   { input: 5.00, cached: 0.50, output: 30.00, longContext: true },
  'gpt-5.6':       { input: 5.00, cached: 0.50, output: 30.00, longContext: true },
  'gpt-5.6-terra': { input: 2.00, cached: 0.20, output: 12.00, longContext: true },
  'gpt-5.6-luna':  { input: 0.20, cached: 0.02, output: 1.20, longContext: true },
  'gpt-5.5':       { input: 5.00, cached: 0.50, output: 30.00, longContext: true },
  'gpt-5.4':       { input: 2.50, cached: 0.25, output: 15.00, longContext: true },
  'gpt-5.4-mini':  { input: 0.75, cached: 0.075, output: 4.50, longContext: true },
  'gpt-5.4-nano':  { input: 0.20, cached: 0.02, output: 1.25, longContext: true },
  'gpt-5.3-codex': { input: 1.75, cached: 0.175, output: 14.00, longContext: false },
  'gpt-5.2-codex': { input: 1.75, cached: 0.175, output: 14.00, longContext: false }
};

const DEFAULT_SETTINGS = {
  exchangeRate: 7.20,
  currencyConversion: true,
  exchangeRateDate: '',
  exchangeRateFetchedAt: '',
  exchangeRateSource: '',
  refreshIntervalSeconds: 15,
  themeAccent: '#B8FF34',
  themeBackground: '#090B0D',
  themePanel: '#131619',
  themeText: '#F3F6F4',
  themeMuted: '#8A9290',
  themeSecondary: '#9D84EF',
  numberUnitStyle: 'international',
  longContext: true,
  prices: {}
};
const THEME_KEYS = ['themeAccent', 'themeBackground', 'themePanel', 'themeText', 'themeMuted', 'themeSecondary'];
const IS_WIDGET = new URLSearchParams(location.search).get('widget') === '1';
document.documentElement.classList.toggle('widget-mode', IS_WIDGET);
if (IS_WIDGET) document.title = 'Codex Token Widget';
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const asArray = (value) => value == null ? [] : Array.isArray(value) ? value : [value];
const modelRows = (value) => asArray(value).flat(Infinity).filter(item => item && typeof item.model === 'string');

let rawData = null;
let periodDays = 0;
let settings = loadSettings();
applyTheme();
let chartPoints = [];
let filteredSessions = [];
let usageFetchInFlight = false;
let lastUsageFetchAt = 0;
let metricAnimationReady = false;
let autoRefreshTimer = null;
let refreshCountdownTimer = null;
let nextRefreshAt = 0;
let lastRefreshFailed = false;
let metricAnimationSequence = 0;
let activeThemeTarget = 'themeAccent';
let themeBeforeDialog = null;
const metricSnapshots = new Map();
const FLIP_METRIC_IDS = [
  'accountLifetime', 'accountLocal', 'accountUnattributed', 'accountCoverage', 'accountPeak', 'accountProjectedCost',
  'totalTokens', 'costUsd', 'costCny', 'savedUsd', 'limitUsed', 'uncachedTokens', 'cachedTokens',
  'outputTokens', 'reasoningTokens', 'cacheCenter', 'widgetTotal', 'widgetCostUsd', 'widgetCostCny',
  'widgetCache', 'widgetSources', 'widgetLimit', 'exactLiveLifetime'
];

function animateChangedMetrics() {
  for (const id of FLIP_METRIC_IDS) {
    const element = document.getElementById(id);
    if (!element) continue;
    const current = element.textContent.trim();
    const previous = metricSnapshots.get(id);
    if (metricAnimationReady && previous != null && previous !== current && current !== '—'
        && /\d/.test(previous) && /\d/.test(current)) {
      renderRollingMetric(element, previous, current);
    }
    metricSnapshots.set(id, current);
  }
  metricAnimationReady = true;
}

function renderRollingMetric(element, previous, current) {
  const animationKey = String(++metricAnimationSequence);
  element.dataset.metricAnimation = animationKey;
  const oldDigits = [...previous].filter(char => /\d/.test(char));
  const currentChars = [...current];
  const currentDigitCount = currentChars.filter(char => /\d/.test(char)).length;
  const oldNumeric = parseMetricNumber(previous);
  const newNumeric = parseMetricNumber(current);
  const rollsUp = !Number.isFinite(oldNumeric) || !Number.isFinite(newNumeric) || newNumeric >= oldNumeric;
  let digitIndex = 0;

  const fragment = document.createDocumentFragment();
  for (const char of currentChars) {
    if (!/\d/.test(char)) {
      const mark = document.createElement('span');
      mark.className = 'odometer-mark';
      mark.textContent = char;
      mark.setAttribute('aria-hidden', 'true');
      fragment.appendChild(mark);
      continue;
    }

    const digitsFromRight = currentDigitCount - digitIndex - 1;
    const oldIndex = oldDigits.length - digitsFromRight - 1;
    const oldDigit = oldIndex >= 0 ? oldDigits[oldIndex] : null;
    digitIndex++;
    if (oldDigit == null || oldDigit === char) {
      const stable = document.createElement('span');
      stable.className = 'odometer-static';
      stable.textContent = char;
      stable.setAttribute('aria-hidden', 'true');
      fragment.appendChild(stable);
      continue;
    }

    const viewport = document.createElement('span');
    viewport.className = `odometer-digit ${rollsUp ? 'roll-up' : 'roll-down'}`;
    viewport.style.setProperty('--roll-delay', `${Math.min(150, digitsFromRight * 22)}ms`);
    viewport.setAttribute('aria-hidden', 'true');
    const track = document.createElement('span');
    track.className = 'odometer-track';
    const first = document.createElement('span');
    const second = document.createElement('span');
    first.textContent = rollsUp ? oldDigit : char;
    second.textContent = rollsUp ? char : oldDigit;
    track.append(first, second);
    viewport.appendChild(track);
    fragment.appendChild(viewport);
  }
  element.replaceChildren(fragment);
  element.setAttribute('aria-label', current);
  setTimeout(() => {
    if (element.dataset.metricAnimation !== animationKey) return;
    finalizeRollingMetric(element);
  }, 760);
}

function finalizeRollingMetric(element) {
  const finalValue = element.getAttribute('aria-label');
  if (finalValue != null) element.textContent = finalValue;
  element.removeAttribute('data-metric-animation');
}

function finalizeAllRollingMetrics() {
  $$('[data-metric-animation]').forEach(finalizeRollingMetric);
}

function parseMetricNumber(value) {
  const number = Number(String(value).replace(/[^\d.-]/g, ''));
  if (!Number.isFinite(number)) return NaN;
  const suffix = String(value).match(/([KMGTEP万亿])/i)?.[1]?.toUpperCase();
  return number * ({ K: 1e3, M: 1e6, G: 1e9, T: 1e12, P: 1e15, E: 1e18, 万: 1e4, 亿: 1e8 }[suffix] || 1);
}

function loadSettings() {
  try {
    const saved = JSON.parse(localStorage.getItem('codex-meter-settings') || '{}');
    return {
      exchangeRate: Number(saved.exchangeRate) || DEFAULT_SETTINGS.exchangeRate,
      currencyConversion: saved.currencyConversion !== false,
      exchangeRateDate: typeof saved.exchangeRateDate === 'string' ? saved.exchangeRateDate : '',
      exchangeRateFetchedAt: typeof saved.exchangeRateFetchedAt === 'string' ? saved.exchangeRateFetchedAt : '',
      exchangeRateSource: typeof saved.exchangeRateSource === 'string' ? saved.exchangeRateSource : '',
      refreshIntervalSeconds: normalizeRefreshInterval(saved.refreshIntervalSeconds),
      themeAccent: normalizeHex(saved.themeAccent, DEFAULT_SETTINGS.themeAccent),
      themeBackground: normalizeHex(saved.themeBackground, DEFAULT_SETTINGS.themeBackground),
      themePanel: normalizeHex(saved.themePanel, DEFAULT_SETTINGS.themePanel),
      themeText: normalizeHex(saved.themeText, DEFAULT_SETTINGS.themeText),
      themeMuted: normalizeHex(saved.themeMuted, DEFAULT_SETTINGS.themeMuted),
      themeSecondary: normalizeHex(saved.themeSecondary, DEFAULT_SETTINGS.themeSecondary),
      numberUnitStyle: saved.numberUnitStyle === 'chinese' ? 'chinese' : 'international',
      longContext: saved.longContext !== false,
      prices: saved.prices && typeof saved.prices === 'object' ? saved.prices : {}
    };
  } catch {
    return structuredClone(DEFAULT_SETTINGS);
  }
}

function normalizeRefreshInterval(value) {
  const seconds = Number(value);
  return Math.min(3600, Math.max(0.5, Number.isFinite(seconds) && seconds > 0 ? seconds : 15));
}

function normalizeHex(value, fallback) {
  const text = String(value || '').trim();
  return /^#[0-9a-f]{6}$/i.test(text) ? text.toUpperCase() : fallback;
}

function hexToRgb(hex) {
  const value = normalizeHex(hex, '#000000').slice(1);
  return { r: parseInt(value.slice(0, 2), 16), g: parseInt(value.slice(2, 4), 16), b: parseInt(value.slice(4, 6), 16) };
}

function rgbToHex(r, g, b) {
  return `#${[r, g, b].map(value => Math.round(Math.max(0, Math.min(255, value))).toString(16).padStart(2, '0')).join('')}`.toUpperCase();
}

function hexToHsl(hex) {
  let { r, g, b } = hexToRgb(hex);
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h = 0, s = 0;
  const l = (max + min) / 2;
  const delta = max - min;
  if (delta) {
    s = delta / (1 - Math.abs(2 * l - 1));
    if (max === r) h = 60 * (((g - b) / delta) % 6);
    else if (max === g) h = 60 * ((b - r) / delta + 2);
    else h = 60 * ((r - g) / delta + 4);
  }
  return { h: Math.round((h + 360) % 360), s: Math.round(s * 100), l: Math.round(l * 100) };
}

function hslToHex(h, s, l) {
  h = ((Number(h) % 360) + 360) % 360;
  s = Math.max(0, Math.min(100, Number(s))) / 100;
  l = Math.max(0, Math.min(100, Number(l))) / 100;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs((h / 60) % 2 - 1));
  const m = l - c / 2;
  let rgb = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
    : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return rgbToHex(...rgb.map(value => (value + m) * 255));
}

function mixHex(base, overlay, amount) {
  const a = hexToRgb(base), b = hexToRgb(overlay);
  return rgbToHex(a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount);
}

function relativeLuminance(hex) {
  const channels = Object.values(hexToRgb(hex)).map(value => {
    const channel = value / 255;
    return channel <= .04045 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4;
  });
  return .2126 * channels[0] + .7152 * channels[1] + .0722 * channels[2];
}

function contrastRatio(first, second) {
  const a = relativeLuminance(first), b = relativeLuminance(second);
  return (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
}

function readableColor(background, preferred, minimum = 4.5) {
  if (contrastRatio(background, preferred) >= minimum) return preferred;
  return contrastRatio(background, '#F6F8F7') >= contrastRatio(background, '#111315') ? '#F6F8F7' : '#111315';
}

function applyTheme() {
  if (!settings) return;
  for (const key of THEME_KEYS) settings[key] = normalizeHex(settings[key], DEFAULT_SETTINGS[key]);
  const accent = hexToRgb(settings.themeAccent);
  const text = hexToRgb(settings.themeText);
  const onBackground = readableColor(settings.themeBackground, settings.themeText);
  const onBackgroundMuted = contrastRatio(settings.themeBackground, settings.themeMuted) >= 3
    ? settings.themeMuted
    : mixHex(onBackground, settings.themeBackground, .22);
  const root = document.documentElement.style;
  root.setProperty('--accent', settings.themeAccent);
  root.setProperty('--accent-soft', `rgba(${accent.r},${accent.g},${accent.b},.12)`);
  root.setProperty('--accent-glow', `rgba(${accent.r},${accent.g},${accent.b},.4)`);
  root.setProperty('--accent-border', `rgba(${accent.r},${accent.g},${accent.b},.28)`);
  const accentLuminance = (0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b) / 255;
  root.setProperty('--accent-contrast', accentLuminance > .52 ? '#111111' : '#F6F8F7');
  root.setProperty('--bg', settings.themeBackground);
  root.setProperty('--on-bg', onBackground);
  root.setProperty('--on-bg-muted', onBackgroundMuted);
  root.setProperty('--panel', settings.themePanel);
  root.setProperty('--panel-strong', mixHex(settings.themePanel, '#FFFFFF', .045));
  root.setProperty('--surface-deep', mixHex(settings.themePanel, '#000000', .12));
  root.setProperty('--surface', settings.themePanel);
  root.setProperty('--surface-raised', mixHex(settings.themePanel, '#FFFFFF', .065));
  root.setProperty('--text', settings.themeText);
  root.setProperty('--muted', settings.themeMuted);
  root.setProperty('--secondary', settings.themeSecondary);
  root.setProperty('--purple', settings.themeSecondary);
  root.setProperty('--line', `rgba(${text.r},${text.g},${text.b},.085)`);
  root.setProperty('--line-strong', `rgba(${text.r},${text.g},${text.b},.15)`);
}

function saveSettings() {
  localStorage.setItem('codex-meter-settings', JSON.stringify(settings));
}

function emptyUsage() {
  return {
    inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
    outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0,
    longInputTokens: 0, longCachedInputTokens: 0, longCacheWriteInputTokens: 0,
    longOutputTokens: 0, requests: 0, longRequests: 0
  };
}

function addUsage(target, source) {
  for (const key of Object.keys(target)) target[key] += Number(source?.[key] || 0);
  return target;
}

function officialPriceFor(model) {
  if (typeof model !== 'string') return { input: 0, cached: 0, output: 0, longContext: false };
  if (OFFICIAL_PRICES[model]) return OFFICIAL_PRICES[model];
  const key = Object.keys(OFFICIAL_PRICES)
    .sort((a, b) => b.length - a.length)
    .find(name => model.startsWith(`${name}-`));
  return key ? OFFICIAL_PRICES[key] : { input: 0, cached: 0, output: 0, longContext: false };
}

function priceFor(model) {
  return { ...officialPriceFor(model), ...(settings.prices[model] || {}) };
}

function costForUsage(usage, model, noCache = false) {
  const p = priceFor(model);
  const million = 1_000_000;
  let longInput = Number(usage.longInputTokens || 0);
  let longCached = Number(usage.longCachedInputTokens || 0);
  let longWrite = Number(usage.longCacheWriteInputTokens || 0);
  let longOutput = Number(usage.longOutputTokens || 0);
  const applyLong = settings.longContext && p.longContext;
  if (!applyLong) longInput = longCached = longWrite = longOutput = 0;

  const input = Number(usage.inputTokens || 0);
  const cached = Number(usage.cachedInputTokens || 0);
  const cacheWrite = Number(usage.cacheWriteInputTokens || 0);
  const output = Number(usage.outputTokens || 0);
  const standard = Math.max(0, input - cached - cacheWrite);
  const longStandard = Math.max(0, longInput - longCached - longWrite);
  const normalStandard = Math.max(0, standard - longStandard);
  const normalCached = Math.max(0, cached - longCached);
  const normalWrite = Math.max(0, cacheWrite - longWrite);
  const normalOutput = Math.max(0, output - longOutput);

  if (noCache) {
    return ((normalStandard + normalCached + normalWrite) * p.input + normalOutput * p.output
      + longInput * p.input * 2 + longOutput * p.output * 1.5) / million;
  }
  return (normalStandard * p.input + normalCached * p.cached + normalWrite * p.input * 1.25 + normalOutput * p.output
    + longStandard * p.input * 2 + longCached * p.cached * 2 + longWrite * p.input * 1.25 * 2 + longOutput * p.output * 1.5) / million;
}

function sessionCost(session, noCache = false) {
  return modelRows(session.models).reduce((sum, item) => sum + costForUsage(item, item.model, noCache), 0);
}

function selectedSessions() {
  return asArray(rawData.sessions).filter(session => periodRowsForSession(session).length > 0);
}

function localDateKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function periodRowsForSession(session) {
  if (!periodDays) return [session];
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - periodDays + 1);
  const startKey = localDateKey(start);
  const endKey = localDateKey(new Date());
  const daily = asArray(session.dailyUsage);
  if (daily.length) return daily.filter(row => row?.date >= startKey && row.date <= endKey);
  return session.startedAt && new Date(session.startedAt) >= start ? [session] : [];
}

function aggregate(sessions) {
  const usage = emptyUsage();
  const models = new Map();
  for (const session of sessions) {
    addUsage(usage, session.usage);
    for (const item of modelRows(session.models)) {
      if (!models.has(item.model)) models.set(item.model, emptyUsage());
      addUsage(models.get(item.model), item);
    }
  }
  return { usage, models };
}

function aggregateSelected(sessions) {
  if (!periodDays) return aggregate(sessions);
  const usage = emptyUsage();
  const models = new Map();
  for (const session of sessions) {
    for (const row of periodRowsForSession(session)) {
      addUsage(usage, row.usage);
      for (const item of modelRows(row.models)) {
        if (!models.has(item.model)) models.set(item.model, emptyUsage());
        addUsage(models.get(item.model), item);
      }
    }
  }
  return { usage, models };
}

function formatCompact(value, digits = 1) {
  const number = Number(value || 0);
  const absolute = Math.abs(number);
  if (absolute <= 9999) return Math.round(number).toLocaleString('zh-CN');
  const units = settings.numberUnitStyle === 'chinese'
    ? [[1e24, '亿亿亿'], [1e20, '万亿亿'], [1e16, '亿亿'], [1e12, '万亿'], [1e8, '亿'], [1e4, '万']]
    : [[1e18, 'E'], [1e15, 'P'], [1e12, 'T'], [1e9, 'G'], [1e6, 'M'], [1e3, 'K']];
  const [scale, suffix] = units.find(([threshold]) => absolute >= threshold) || units.at(-1);
  return `${(number / scale).toLocaleString('zh-CN', { maximumFractionDigits: digits })}${suffix}`;
}

function formatFull(value) {
  return Number(value || 0).toLocaleString('zh-CN');
}

function formatUsd(value) {
  const digits = value >= 100 ? 2 : value >= 1 ? 3 : 4;
  return `$${Number(value || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: digits })}`;
}

function formatDate(value, includeYear = false) {
  if (!value) return '—';
  return new Intl.DateTimeFormat('zh-CN', {
    ...(includeYear ? { year: 'numeric' } : {}), month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit'
  }).format(new Date(value));
}

function dateOnly(value) {
  if (!value) return '—';
  return new Intl.DateTimeFormat('zh-CN', { month: 'short', day: 'numeric' }).format(new Date(value));
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[char]);
}

async function fetchUsage() {
  if (usageFetchInFlight) return;
  clearTimeout(autoRefreshTimer);
  clearInterval(refreshCountdownTimer);
  autoRefreshTimer = null;
  refreshCountdownTimer = null;
  nextRefreshAt = 0;
  usageFetchInFlight = true;
  const button = $('#refreshButton');
  button.classList.add('loading');
  $('#scanStatus').textContent = '正在读取日志';
  try {
    const response = await fetch('/api/usage', { cache: 'no-store' });
    if (!response.ok) throw new Error((await response.json()).error || `HTTP ${response.status}`);
    rawData = await response.json();
    if (rawData.settings?.refreshIntervalSeconds != null) {
      settings.refreshIntervalSeconds = normalizeRefreshInterval(rawData.settings.refreshIntervalSeconds);
      settings.themeAccent = normalizeHex(rawData.settings.themeAccent, settings.themeAccent);
      settings.themeBackground = normalizeHex(rawData.settings.themeBackground, settings.themeBackground);
      settings.themePanel = normalizeHex(rawData.settings.themePanel, settings.themePanel);
      settings.themeText = normalizeHex(rawData.settings.themeText, settings.themeText);
      settings.themeMuted = normalizeHex(rawData.settings.themeMuted, settings.themeMuted);
      settings.themeSecondary = normalizeHex(rawData.settings.themeSecondary, settings.themeSecondary);
      settings.numberUnitStyle = rawData.settings.numberUnitStyle === 'chinese' ? 'chinese' : 'international';
      applyTheme();
      saveSettings();
    }
    lastUsageFetchAt = Date.now();
    lastRefreshFailed = false;
    render();
    animateChangedMetrics();
  } catch (error) {
    lastRefreshFailed = true;
    $('#scanStatus').textContent = '读取失败';
    showToast(`读取失败：${error.message}`, true);
  } finally {
    button.classList.remove('loading');
    usageFetchInFlight = false;
    scheduleNextRefresh();
  }
}

function scheduleNextRefresh() {
  clearTimeout(autoRefreshTimer);
  clearInterval(refreshCountdownTimer);
  const delay = normalizeRefreshInterval(settings.refreshIntervalSeconds) * 1000;
  nextRefreshAt = Date.now() + delay;
  autoRefreshTimer = setTimeout(fetchUsage, delay);
  updateRefreshCountdown();
  refreshCountdownTimer = setInterval(updateRefreshCountdown, delay < 10_000 ? 100 : 1000);
}

function updateRefreshCountdown() {
  if (usageFetchInFlight || !nextRefreshAt) return;
  const remaining = Math.max(0, (nextRefreshAt - Date.now()) / 1000);
  const countdown = remaining < 10 ? remaining.toFixed(1) : String(Math.ceil(remaining));
  if (lastRefreshFailed) {
    $('#scanStatus').textContent = `读取失败 · ${countdown} 秒后重试`;
    return;
  }
  const syncedAt = rawData?.generatedAt ? new Date(rawData.generatedAt) : new Date();
  const time = syncedAt.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  $('#scanStatus').textContent = `已同步 ${time} · ${countdown} 秒后刷新`;
}

function render() {
  if (!rawData) return;
  filteredSessions = selectedSessions();
  const { usage, models } = aggregateSelected(filteredSessions);
  const totalCost = [...models].reduce((sum, [model, item]) => sum + costForUsage(item, model), 0);
  const noCacheCost = [...models].reduce((sum, [model, item]) => sum + costForUsage(item, model, true), 0);
  const saved = Math.max(0, noCacheCost - totalCost);
  const cacheRate = usage.inputTokens ? usage.cachedInputTokens / usage.inputTokens * 100 : 0;
  const periodDates = filteredSessions.flatMap(session => {
    const rows = periodRowsForSession(session);
    return rows.map(row => row.date || session.localDate).filter(Boolean);
  }).sort();

  renderAccountLedger();

  $('#totalTokens').textContent = formatCompact(usage.totalTokens, 2);
  $('#requestCount').textContent = `${formatFull(usage.requests)} REQUESTS`;
  $('#sessionCount').textContent = `${filteredSessions.length} 个任务`;
  $('#dateRange').textContent = periodDates.length
    ? `${dateOnly(new Date(`${periodDates[0]}T00:00:00`))} — ${dateOnly(new Date(`${periodDates.at(-1)}T00:00:00`))}`
    : '暂无数据';
  $('#costUsd').textContent = formatUsd(totalCost);
  $('#costCny').textContent = settings.currencyConversion
    ? `约 ¥${(totalCost * settings.exchangeRate).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
    : '人民币换算已关闭';
  $('#costCny').classList.toggle('conversion-off', !settings.currencyConversion);
  $('#savedUsd').textContent = formatUsd(saved);
  $('#cacheRate').textContent = `${cacheRate.toFixed(1)}% 命中率`;

  const uncached = Math.max(0, usage.inputTokens - usage.cachedInputTokens - usage.cacheWriteInputTokens);
  $('#uncachedTokens').textContent = formatCompact(uncached, 2);
  $('#cachedTokens').textContent = formatCompact(usage.cachedInputTokens, 2);
  $('#outputTokens').textContent = formatCompact(usage.outputTokens, 2);
  $('#reasoningTokens').textContent = formatCompact(usage.reasoningOutputTokens, 2);
  $('#cacheCenter').textContent = `${Math.round(cacheRate)}%`;
  $('#tokenDonut').style.setProperty('--cached-angle', `${Math.min(99.5, Math.max(0, cacheRate)) * 3.5}deg`);

  renderRateLimit();
  renderModels(models, usage.totalTokens);
  renderSessions();
  renderTrend(filteredSessions);
  renderWidget(filteredSessions, usage, totalCost, cacheRate);
  renderSourceSummary();
  if (!$('#settingsDialog').open) populatePriceRows();
}

function renderAccountLedger() {
  const account = rawData.account;
  const coverage = rawData.coverage || {};
  const available = account?.available && account?.summary;
  const liveLifetime = Number(account?.liveLifetimeTokens ?? account?.summary?.lifetimeTokens ?? 0);
  $('#accountLifetime').textContent = available ? formatCompact(liveLifetime, 2) : '不可用';
  $('#accountLocal').textContent = formatCompact(coverage.locallyAttributableTokens, 2);
  $('#accountUnattributed').textContent = available ? formatCompact(coverage.unattributedTokens, 2) : '—';
  $('#accountCoverage').textContent = coverage.percent == null ? '—' : `${Number(coverage.percent).toFixed(1)}%`;
  $('#accountPeak').textContent = available ? formatCompact(account.summary.peakDailyTokens, 2) : '—';
  const comparableSessions = asArray(rawData.sessions).filter(item => item.source !== 'manual');
  const comparableModels = aggregate(comparableSessions).models;
  const comparableCost = [...comparableModels].reduce((sum, [model, item]) => sum + costForUsage(item, model), 0);
  const projectedCost = available && Number(coverage.locallyAttributableTokens) > 0
    ? comparableCost * liveLifetime / Number(coverage.locallyAttributableTokens)
    : null;
  $('#accountProjectedCost').textContent = projectedCost == null ? '—' : formatUsd(projectedCost);
  const bucketMap = new Map();
  for (const day of asArray(rawData.history?.days)) {
    if (day?.date && Number(day.accountTokens || 0) > 0) bucketMap.set(day.date, { startDate: day.date, tokens: Number(day.accountTokens) });
  }
  for (const item of asArray(account?.dailyUsageBuckets).filter(item => item?.startDate)) {
    const existing = bucketMap.get(item.startDate);
    bucketMap.set(item.startDate, { startDate: item.startDate, tokens: Math.max(Number(existing?.tokens || 0), Number(item.tokens || 0)) });
  }
  const buckets = [...bucketMap.values()].sort((a, b) => a.startDate.localeCompare(b.startDate));
  $('#accountDays').textContent = buckets.length ? `${buckets.length} 个有用量日期` : '账户每日桶不可用';
  $('#accountSync').textContent = available
    ? `账户已同步 · ${new Date(account.fetchedAt).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`
    : `仅本机 · ${account?.error || '账户接口不可用'}`;
  $('#accountSync').classList.toggle('error', !available);

  $('#exactLiveLifetime').textContent = formatFull(liveLifetime);

  const recent = buckets.slice(-14);
  const max = Math.max(1, ...recent.map(item => Number(item.tokens || 0)));
  $('#accountDailyBars').innerHTML = recent.map(item => {
    const height = Math.max(4, Number(item.tokens || 0) / max * 100);
    const exact = `${item.startDate} · ${formatFull(item.tokens)} Token`;
    return `<div title="${escapeHtml(exact)}" aria-label="${escapeHtml(exact)}"><b>${formatCompact(item.tokens, 2)}</b><i style="height:${height}%"></i><span>${escapeHtml(item.startDate.slice(5))}</span></div>`;
  }).join('');
}

function renderWidget(sessions, usage, totalCost, cacheRate) {
  $('#widgetTotal').textContent = formatCompact(usage.totalTokens, 2);
  $('#widgetRequests').textContent = `${formatFull(usage.requests)} 次调用`;
  $('#widgetSessions').textContent = `${sessions.length} 个任务`;
  $('#widgetCostUsd').textContent = formatUsd(totalCost);
  $('#widgetCostCny').textContent = `¥${(totalCost * settings.exchangeRate).toLocaleString('zh-CN', { maximumFractionDigits: 2 })}`;
  $('#widgetCostCny').parentElement.hidden = !settings.currencyConversion;
  $('#widgetCache').textContent = `${cacheRate.toFixed(1)}%`;
  $('#widgetSources').textContent = `${new Set(sessions.map(item => item.source || 'local')).size} 类`;
  $('#widgetLimit').textContent = rawData.rateLimit?.usedPercent == null ? '—' : `${Number(rawData.rateLimit.usedPercent).toFixed(0)}%`;
  $('#widgetUpdated').textContent = `已同步 ${new Date(rawData.generatedAt).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;
  renderWidgetChart(sessions);
}

function renderSourceSummary() {
  if (!rawData) return;
  const groups = new Map();
  for (const session of asArray(rawData.sessions)) {
    const key = session.source || 'local';
    const current = groups.get(key) || { label: session.sourceLabel || key, sessions: 0, tokens: 0 };
    current.sessions += 1;
    current.tokens += Number(session.usage?.totalTokens || 0);
    groups.set(key, current);
  }
  $('#sourceSummary').innerHTML = [...groups.values()].map(item => `<div><span>${escapeHtml(item.label)}</span><b>${formatCompact(item.tokens, 2)}</b><small>${item.sessions} 个任务</small></div>`).join('') || '<div><span>暂无来源</span></div>';
}

function renderRateLimit() {
  const limit = rawData.rateLimit;
  if (!limit || limit.usedPercent == null) {
    $('#limitUsed').textContent = '—';
    $('#limitBar').style.width = '0%';
    $('#limitReset').textContent = '暂无额度数据';
    return;
  }
  const used = Number(limit.usedPercent);
  $('#limitUsed').textContent = `${used.toFixed(0)}%`;
  $('#limitBar').style.width = `${Math.min(100, used)}%`;
  $('#limitWindow').textContent = limit.windowMinutes ? `${Math.round(limit.windowMinutes / 1440)} 天窗口` : 'Codex 额度';
  if (limit.resetsAt) {
    $('#limitReset').textContent = `重置 ${formatDate(Number(limit.resetsAt) * 1000, true)}`;
  } else {
    $('#limitReset').textContent = '重置时间未知';
  }
}

function renderModels(models, totalTokens) {
  const sorted = [...models.entries()].sort((a, b) => b[1].totalTokens - a[1].totalTokens);
  $('#modelCount').textContent = `${sorted.length} 个模型`;
  $('#modelRows').innerHTML = sorted.length ? sorted.map(([model, usage]) => {
    const share = totalTokens ? usage.totalTokens / totalTokens * 100 : 0;
    const cost = costForUsage(usage, model);
    return `<div class="model-row">
      <div class="model-name"><b>${escapeHtml(model)}</b><span>${formatFull(usage.requests)} 次调用 · ${formatFull(usage.longRequests)} 次长上下文</span></div>
      <div class="model-bar"><i style="width:${Math.max(1, share)}%"></i></div>
      <div class="model-stat"><span>TOKEN</span><b>${formatCompact(usage.totalTokens, 2)}</b></div>
      <div class="model-stat"><span>API 估算</span><b>${formatUsd(cost)}</b></div>
    </div>`;
  }).join('') : '<div class="empty-state">当前周期没有 Token 记录</div>';
}

function renderSessions() {
  const query = $('#sessionSearch').value.trim().toLowerCase();
  const visible = filteredSessions.filter(session => !query || `${session.title} ${session.project} ${session.cwd}`.toLowerCase().includes(query));
  $('#sessionRows').innerHTML = visible.map(session => {
    const view = periodDays ? aggregate(periodRowsForSession(session)) : { usage: session.usage, models: new Map(modelRows(session.models).map(item => [item.model, item])) };
    const models = [...view.models.keys()];
    const viewCost = [...view.models].reduce((sum, [model, item]) => sum + costForUsage(item, model), 0);
    return `<tr>
      <td class="task-cell"><b title="${escapeHtml(session.title)}">${escapeHtml(session.title)}</b><span>${escapeHtml(session.project || '未知项目')} · ${escapeHtml(session.sourceLabel || 'This computer')}</span></td>
      <td><span class="model-chip">${escapeHtml(models.join(' + ') || '—')}</span></td>
      <td>${formatDate(session.startedAt, true)}</td>
      <td class="num">${formatCompact(view.usage.totalTokens, 2)}</td>
      <td class="num cost-cell">${formatUsd(viewCost)}</td>
    </tr>`;
  }).join('');
  $('#emptyState').hidden = visible.length > 0;
}

function buildDailyData(sessions) {
  const map = new Map();
  for (const day of asArray(rawData?.history?.days)) {
    if (!day?.date || !day?.localUsage) continue;
    const cached = emptyUsage();
    addUsage(cached, day.localUsage);
    map.set(day.date, cached);
  }
  const currentMap = new Map();
  for (const session of sessions) {
    const daily = asArray(session.dailyUsage);
    const rows = daily.length ? daily : session.localDate ? [{ date: session.localDate, usage: session.usage }] : [];
    for (const row of rows) {
      if (!row?.date) continue;
      if (!currentMap.has(row.date)) currentMap.set(row.date, emptyUsage());
      addUsage(currentMap.get(row.date), row.usage);
    }
  }
  for (const [date, usage] of currentMap) map.set(date, usage);
  if (!map.size) return [];

  let first;
  let last = new Date();
  last.setHours(0, 0, 0, 0);
  if (periodDays) {
    first = new Date(last);
    first.setDate(first.getDate() - periodDays + 1);
  } else {
    first = new Date(`${[...map.keys()].sort()[0]}T00:00:00`);
    const max = new Date(`${[...map.keys()].sort().at(-1)}T00:00:00`);
    if (max > last) last = max;
  }
  const rows = [];
  for (const cursor = new Date(first); cursor <= last; cursor.setDate(cursor.getDate() + 1)) {
    const key = `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, '0')}-${String(cursor.getDate()).padStart(2, '0')}`;
    rows.push({ date: key, usage: map.get(key) || emptyUsage() });
  }
  return rows;
}

function renderTrend(sessions) {
  chartPoints = buildDailyData(sessions);
  const canvas = $('#trendChart');
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(rect.width * ratio));
  canvas.height = Math.max(1, Math.round(rect.height * ratio));
  const ctx = canvas.getContext('2d');
  ctx.scale(ratio, ratio);
  const width = rect.width, height = rect.height;
  ctx.clearRect(0, 0, width, height);
  const pad = { left: 52, right: 10, top: 12, bottom: 30 };
  const innerW = width - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;
  const maxValue = Math.max(1, ...chartPoints.map(row => row.usage.inputTokens));
  const accentRgb = hexToRgb(settings.themeAccent);

  ctx.font = '9px "Microsoft YaHei UI", "Noto Sans CJK SC", sans-serif';
  ctx.textAlign = 'right';
  ctx.textBaseline = 'middle';
  for (let i = 0; i <= 4; i++) {
    const y = pad.top + innerH * i / 4;
    const value = maxValue * (1 - i / 4);
    ctx.strokeStyle = 'rgba(255,255,255,.055)';
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
    ctx.fillStyle = '#5f6765';
    ctx.fillText(formatCompact(value, 0), pad.left - 9, y);
  }
  if (!chartPoints.length) {
    ctx.fillStyle = '#69716f'; ctx.textAlign = 'center'; ctx.fillText('暂无趋势数据', width / 2, height / 2); return;
  }

  const xAt = i => pad.left + (chartPoints.length === 1 ? innerW / 2 : i * innerW / (chartPoints.length - 1));
  const yAt = value => pad.top + innerH - (value / maxValue * innerH);
  const drawLine = (key, color, fill) => {
    ctx.beginPath();
    chartPoints.forEach((row, i) => {
      const x = xAt(i), y = yAt(row.usage[key]);
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    if (fill) {
      const lastX = xAt(chartPoints.length - 1), firstX = xAt(0);
      ctx.lineTo(lastX, pad.top + innerH); ctx.lineTo(firstX, pad.top + innerH); ctx.closePath();
      const gradient = ctx.createLinearGradient(0, pad.top, 0, pad.top + innerH);
      gradient.addColorStop(0, `rgba(${accentRgb.r},${accentRgb.g},${accentRgb.b},.17)`); gradient.addColorStop(1, `rgba(${accentRgb.r},${accentRgb.g},${accentRgb.b},0)`);
      ctx.fillStyle = gradient; ctx.fill();
      ctx.beginPath();
      chartPoints.forEach((row, i) => i ? ctx.lineTo(xAt(i), yAt(row.usage[key])) : ctx.moveTo(xAt(i), yAt(row.usage[key])));
    }
    ctx.strokeStyle = color; ctx.lineWidth = fill ? 2 : 1.5; ctx.lineJoin = 'round'; ctx.lineCap = 'round'; ctx.stroke();
  };
  drawLine('inputTokens', settings.themeAccent, true);
  drawLine('outputTokens', settings.themeSecondary, false);

  const labelEvery = Math.max(1, Math.ceil(chartPoints.length / 7));
  ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillStyle = '#5f6765';
  chartPoints.forEach((row, i) => {
    if (i % labelEvery === 0 || i === chartPoints.length - 1) {
      const date = new Date(`${row.date}T00:00:00`);
      ctx.fillText(`${date.getMonth() + 1}/${date.getDate()}`, xAt(i), height - 17);
    }
  });
  canvas._chart = { pad, innerW, xAt };
}

function renderWidgetChart(sessions) {
  const canvas = $('#widgetChart');
  if (!canvas) return;
  const points = buildDailyData(sessions);
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(rect.width * ratio));
  canvas.height = Math.max(1, Math.round(rect.height * ratio));
  const ctx = canvas.getContext('2d');
  ctx.scale(ratio, ratio);
  const width = rect.width, height = rect.height;
  ctx.clearRect(0, 0, width, height);
  if (!points.length || !width || !height) return;
  const max = Math.max(1, ...points.map(row => row.usage.totalTokens));
  const accentRgb = hexToRgb(settings.themeAccent);
  const xAt = index => points.length === 1 ? width / 2 : index * width / (points.length - 1);
  const yAt = value => 8 + (height - 18) * (1 - value / max);
  const gradient = ctx.createLinearGradient(0, 0, 0, height);
  gradient.addColorStop(0, `rgba(${accentRgb.r},${accentRgb.g},${accentRgb.b},.24)`);
  gradient.addColorStop(1, `rgba(${accentRgb.r},${accentRgb.g},${accentRgb.b},0)`);
  ctx.beginPath();
  points.forEach((row, index) => index ? ctx.lineTo(xAt(index), yAt(row.usage.totalTokens)) : ctx.moveTo(xAt(index), yAt(row.usage.totalTokens)));
  ctx.lineTo(xAt(points.length - 1), height); ctx.lineTo(xAt(0), height); ctx.closePath(); ctx.fillStyle = gradient; ctx.fill();
  ctx.beginPath();
  points.forEach((row, index) => index ? ctx.lineTo(xAt(index), yAt(row.usage.totalTokens)) : ctx.moveTo(xAt(index), yAt(row.usage.totalTokens)));
  ctx.strokeStyle = settings.themeAccent; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.stroke();
}

function populatePriceRows() {
  if (!rawData) return;
  $('#exchangeRate').value = settings.exchangeRate;
  $('#currencyConversionToggle').checked = settings.currencyConversion;
  $('#refreshInterval').value = settings.refreshIntervalSeconds;
  $('#numberUnitStyle').value = settings.numberUnitStyle;
  $('#longContextToggle').checked = settings.longContext;
  populateThemeEditor();
  setExchangeRateMetadata(settings.exchangeRateSource, settings.exchangeRateDate, settings.exchangeRateFetchedAt);
  syncCurrencyControls();
  const models = modelRows(rawData.models).map(item => item.model);
  $('#priceRows').innerHTML = models.map(model => {
    const price = priceFor(model);
    const known = Object.values(price).some(Number);
    return `<div class="price-row" data-model="${escapeHtml(model)}">
      <label><b>${escapeHtml(model)}</b><span>${known ? 'USD / 1M Token' : '未找到官方单价，请手动填写'}</span></label>
      <input data-key="input" type="number" min="0" step="0.001" value="${price.input}">
      <input data-key="cached" type="number" min="0" step="0.001" value="${price.cached}">
      <input data-key="output" type="number" min="0" step="0.001" value="${price.output}">
    </div>`;
  }).join('');
}

function populateThemeEditor(target = activeThemeTarget) {
  const targets = {
    themeAccent: ['强调色', 'accent'], themeBackground: ['背景色', 'background'],
    themePanel: ['卡片色', 'panel'], themeText: ['主文字', 'text'],
    themeMuted: ['次级文字', 'muted'], themeSecondary: ['辅助色', 'secondary']
  };
  activeThemeTarget = targets[target] ? target : 'themeAccent';
  for (const [key, [, id]] of Object.entries(targets)) {
    settings[key] = normalizeHex(settings[key], DEFAULT_SETTINGS[key]);
    $(`#${id}Swatch`).style.background = settings[key];
    $(`#${id}Hex`).textContent = settings[key];
  }
  $$('.theme-target').forEach(button => button.classList.toggle('active', button.dataset.themeTarget === activeThemeTarget));
  const color = settings[activeThemeTarget];
  const hsl = hexToHsl(color);
  $('#hlsHue').value = hsl.h;
  $('#hlsLightness').value = hsl.l;
  $('#hlsSaturation').value = hsl.s;
  $('#hlsTargetLabel').textContent = targets[activeThemeTarget][0];
  updateHlsVisuals(color, hsl);
}

function updateHlsVisuals(color, hsl) {
  $('#hlsPreview').style.background = color;
  $('#hlsHexValue').textContent = color;
  $('#hlsHueValue').textContent = `${hsl.h}°`;
  $('#hlsLightnessValue').textContent = `${hsl.l}%`;
  $('#hlsSaturationValue').textContent = `${hsl.s}%`;
  $('#hlsHue').style.setProperty('--thumb-color', `hsl(${hsl.h} 100% 50%)`);
  $('#hlsLightness').style.setProperty('--thumb-color', color);
  $('#hlsLightness').style.setProperty('--slider-gradient', `linear-gradient(90deg,hsl(${hsl.h} ${hsl.s}% 0%),hsl(${hsl.h} ${hsl.s}% 50%),hsl(${hsl.h} ${hsl.s}% 100%))`);
  $('#hlsSaturation').style.setProperty('--thumb-color', color);
  $('#hlsSaturation').style.setProperty('--slider-gradient', `linear-gradient(90deg,hsl(${hsl.h} 0% ${hsl.l}%),hsl(${hsl.h} 100% ${hsl.l}%))`);
}

function updateThemeFromHls() {
  const h = Number($('#hlsHue').value);
  const l = Number($('#hlsLightness').value);
  const s = Number($('#hlsSaturation').value);
  const color = hslToHex(h, s, l);
  settings[activeThemeTarget] = color;
  applyTheme();
  populateThemeEditor(activeThemeTarget);
  if (rawData) {
    renderTrend(filteredSessions);
    renderWidgetChart(filteredSessions);
  }
}

async function applySettingsFromDialog() {
  settings.exchangeRate = Math.max(0, Number($('#exchangeRate').value) || DEFAULT_SETTINGS.exchangeRate);
  settings.currencyConversion = $('#currencyConversionToggle').checked;
  settings.exchangeRateSource = $('#exchangeRate').dataset.source || '';
  settings.exchangeRateDate = $('#exchangeRate').dataset.rateDate || '';
  settings.exchangeRateFetchedAt = $('#exchangeRate').dataset.fetchedAt || '';
  settings.refreshIntervalSeconds = normalizeRefreshInterval($('#refreshInterval').value);
  settings.numberUnitStyle = $('#numberUnitStyle').value === 'chinese' ? 'chinese' : 'international';
  for (const key of THEME_KEYS) settings[key] = normalizeHex(settings[key], DEFAULT_SETTINGS[key]);
  settings.longContext = $('#longContextToggle').checked;
  const prices = {};
  $$('#priceRows .price-row').forEach(row => {
    const model = row.dataset.model;
    prices[model] = {};
    row.querySelectorAll('input').forEach(input => prices[model][input.dataset.key] = Math.max(0, Number(input.value) || 0));
  });
  settings.prices = prices;
  themeBeforeDialog = null;
  saveSettings();
  applyTheme();
  render();
  scheduleNextRefresh();
  try {
    const seconds = encodeURIComponent(settings.refreshIntervalSeconds);
    const themeQuery = new URLSearchParams({
      accent: settings.themeAccent, background: settings.themeBackground, panel: settings.themePanel,
      text: settings.themeText, muted: settings.themeMuted, secondary: settings.themeSecondary
    });
    const [refreshResponse, themeResponse, unitResponse] = await Promise.all([
      fetch(`/api/settings/refresh?seconds=${seconds}`, { cache: 'no-store' }),
      fetch(`/api/settings/theme?${themeQuery}`, { cache: 'no-store' }),
      fetch(`/api/settings/units?style=${encodeURIComponent(settings.numberUnitStyle)}`, { cache: 'no-store' })
    ]);
    if (!refreshResponse.ok) throw new Error((await refreshResponse.json()).error || `HTTP ${refreshResponse.status}`);
    if (!themeResponse.ok) throw new Error((await themeResponse.json()).error || `HTTP ${themeResponse.status}`);
    if (!unitResponse.ok) throw new Error((await unitResponse.json()).error || `HTTP ${unitResponse.status}`);
    const shared = await themeResponse.json();
    settings.refreshIntervalSeconds = normalizeRefreshInterval((await refreshResponse.json()).refreshIntervalSeconds);
    settings.numberUnitStyle = (await unitResponse.json()).numberUnitStyle === 'chinese' ? 'chinese' : 'international';
    for (const key of THEME_KEYS) settings[key] = normalizeHex(shared[key], settings[key]);
    applyTheme();
    saveSettings();
    scheduleNextRefresh();
    showToast(`设置已保存 · 每 ${settings.refreshIntervalSeconds} 秒刷新`);
  } catch (error) {
    showToast(`设置已保存，但共享刷新间隔失败：${error.message}`, true);
  }
}

function setExchangeRateMetadata(source = '', rateDate = '', fetchedAt = '') {
  const input = $('#exchangeRate');
  input.dataset.source = source;
  input.dataset.rateDate = rateDate;
  input.dataset.fetchedAt = fetchedAt;
  const meta = $('#exchangeRateMeta');
  if (source && rateDate) {
    const fetched = fetchedAt ? new Date(fetchedAt).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }) : '';
    meta.textContent = `${source} · ${rateDate}${fetched ? ` · 获取于 ${fetched}` : ''}`;
  } else {
    meta.textContent = '当前为手动汇率';
  }
}

function syncCurrencyControls() {
  const enabled = $('#currencyConversionToggle').checked;
  $('#exchangeRateField').classList.toggle('disabled', !enabled);
  $('#exchangeRate').disabled = !enabled;
  $('#fetchExchangeRate').disabled = !enabled;
}

async function fetchOnlineExchangeRate() {
  const button = $('#fetchExchangeRate');
  button.disabled = true;
  button.classList.add('loading');
  button.textContent = '获取中…';
  try {
    const response = await fetch('/api/exchange-rate', { cache: 'no-store' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    const rate = Number(data.rate);
    if (!Number.isFinite(rate) || rate <= 0) throw new Error('返回的汇率无效');
    $('#exchangeRate').value = rate.toFixed(4);
    setExchangeRateMetadata(data.source || 'Frankfurter', data.date || '', data.fetchedAt || '');
    showToast(`已获取 USD/CNY ${rate.toFixed(4)}`);
  } catch (error) {
    showToast(`汇率获取失败：${error.message}`, true);
  } finally {
    button.classList.remove('loading');
    button.textContent = '在线获取';
    syncCurrencyControls();
  }
}

function showToast(message, isError = false) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.style.background = isError ? '#ff6e73' : '';
  toast.classList.add('show');
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove('show'), 2600);
}

$('#refreshButton').addEventListener('click', fetchUsage);
$('#importButton').addEventListener('click', () => { renderSourceSummary(); $('#importDialog').showModal(); });
$('#exportButton').addEventListener('click', async () => {
  const button = $('#exportButton');
  button.classList.add('loading');
  try {
    const response = await fetch('/api/export', { cache: 'no-store' });
    if (!response.ok) throw new Error((await response.json()).error || `HTTP ${response.status}`);
    const bundle = await response.json();
    if (bundle.kind !== 'codex-token-meter-export') throw new Error('导出格式无效');
    const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = bundle.suggestedFileName || `codex-meter-${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    showToast(`已导出 ${Number(bundle.sessionCount || 0).toLocaleString('zh-CN')} 个会话`);
  } catch (error) {
    showToast(`导出失败：${error.message}`, true);
  } finally {
    button.classList.remove('loading');
  }
});
$('#historyExportButton').addEventListener('click', async () => {
  const button = $('#historyExportButton');
  button.classList.add('loading');
  try {
    const response = await fetch('/api/export/history', { cache: 'no-store' });
    if (!response.ok) throw new Error((await response.json()).error || `HTTP ${response.status}`);
    const bundle = await response.json();
    if (bundle.kind !== 'codex-token-meter-history-summary') throw new Error('历史汇总格式无效');
    const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = bundle.suggestedFileName || `codex-meter-history-${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    showToast(`已导出 ${Number(bundle.range?.dayCount || 0).toLocaleString('zh-CN')} 天匿名汇总`);
  } catch (error) {
    showToast(`历史导出失败：${error.message}`, true);
  } finally {
    button.classList.remove('loading');
  }
});
$('#accountExactButton').addEventListener('click', () => $('#exactUsageDialog').showModal());
$$('[data-close-exact]').forEach(button => button.addEventListener('click', () => $('#exactUsageDialog').close()));
$('#settingsButton').addEventListener('click', () => {
  themeBeforeDialog = Object.fromEntries(THEME_KEYS.map(key => [key, settings[key]]));
  populatePriceRows();
  $('#settingsDialog').showModal();
});
$('#saveSettings').addEventListener('click', applySettingsFromDialog);
$('#fetchExchangeRate').addEventListener('click', fetchOnlineExchangeRate);
$('#currencyConversionToggle').addEventListener('change', syncCurrencyControls);
$('#exchangeRate').addEventListener('input', () => setExchangeRateMetadata());
$$('.theme-target').forEach(button => button.addEventListener('click', () => populateThemeEditor(button.dataset.themeTarget)));
$$('#hlsHue, #hlsLightness, #hlsSaturation').forEach(input => input.addEventListener('input', updateThemeFromHls));
$('#resetTheme').addEventListener('click', () => {
  for (const key of THEME_KEYS) settings[key] = DEFAULT_SETTINGS[key];
  applyTheme();
  populateThemeEditor('themeAccent');
  if (rawData) { renderTrend(filteredSessions); renderWidgetChart(filteredSessions); }
  showToast('已恢复默认配色，点击保存生效');
});
$('#settingsDialog').addEventListener('close', () => {
  if (!themeBeforeDialog) return;
  for (const key of THEME_KEYS) settings[key] = themeBeforeDialog[key];
  themeBeforeDialog = null;
  applyTheme();
  if (rawData) { renderTrend(filteredSessions); renderWidgetChart(filteredSessions); }
});
$('#resetPrices').addEventListener('click', () => {
  settings = {
    ...structuredClone(DEFAULT_SETTINGS),
    exchangeRate: settings.exchangeRate,
    currencyConversion: settings.currencyConversion,
    exchangeRateDate: settings.exchangeRateDate,
    exchangeRateFetchedAt: settings.exchangeRateFetchedAt,
    exchangeRateSource: settings.exchangeRateSource,
    refreshIntervalSeconds: settings.refreshIntervalSeconds,
    numberUnitStyle: settings.numberUnitStyle,
    themeAccent: settings.themeAccent,
    themeBackground: settings.themeBackground,
    themePanel: settings.themePanel,
    themeText: settings.themeText,
    themeMuted: settings.themeMuted,
    themeSecondary: settings.themeSecondary
  };
  populatePriceRows();
  showToast('已恢复官方单价，点击保存生效');
});
$('#sessionSearch').addEventListener('input', renderSessions);
$$('[data-close-import]').forEach(button => button.addEventListener('click', () => $('#importDialog').close()));
$('#openImportsButton').addEventListener('click', async () => {
  try {
    const response = await fetch('/api/open-imports', { cache: 'no-store' });
    if (!response.ok) throw new Error('open failed');
    showToast('已打开导入文件夹');
  } catch { showToast('无法打开文件夹，请从项目目录进入 imports', true); }
});
$('#widgetExpand').addEventListener('click', () => window.open('/', '_blank'));
$$('.period-switch button').forEach(button => button.addEventListener('click', () => {
  $$('.period-switch button').forEach(item => item.classList.remove('active'));
  button.classList.add('active');
  periodDays = Number(button.dataset.days);
  render();
  animateChangedMetrics();
}));

$('#trendChart').addEventListener('mousemove', event => {
  const canvas = event.currentTarget;
  const meta = canvas._chart;
  if (!meta || !chartPoints.length) return;
  const rect = canvas.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const raw = chartPoints.length === 1 ? 0 : Math.round((x - meta.pad.left) / meta.innerW * (chartPoints.length - 1));
  const index = Math.max(0, Math.min(chartPoints.length - 1, raw));
  const point = chartPoints[index];
  const tooltip = $('#chartTooltip');
  const today = localDateKey(new Date());
  const incompleteNote = point.date === today
    ? '<small>今日 · 本地日志仍在实时写入，数据可能不完整</small>'
    : '';
  tooltip.innerHTML = `${point.date}<br><b>输入 ${formatFull(point.usage.inputTokens)}</b><br>输出 ${formatFull(point.usage.outputTokens)}${incompleteNote}`;
  tooltip.style.display = 'block';
  const tooltipHalfWidth = Math.max(90, tooltip.offsetWidth / 2 + 4);
  tooltip.style.left = `${Math.max(tooltipHalfWidth, Math.min(rect.width - tooltipHalfWidth, meta.xAt(index)))}px`;
  tooltip.style.top = `${Math.max(70, event.clientY - rect.top)}px`;
});
$('#trendChart').addEventListener('mouseleave', () => $('#chartTooltip').style.display = 'none');

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!rawData) return;
    renderTrend(filteredSessions);
    renderWidgetChart(filteredSessions);
  }, 120);
});

fetchUsage();
window.addEventListener('focus', () => { if (Date.now() - lastUsageFetchAt > 5_000) fetchUsage(); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    finalizeAllRollingMetrics();
    return;
  }
  if (Date.now() - lastUsageFetchAt > 5_000) fetchUsage();
});
window.addEventListener('pagehide', finalizeAllRollingMetrics);
