"use strict";

const $ = (sel) => document.querySelector(sel);
const form = $("#box-form");
const statusEl = $("#status");
const exportBtn = $("#export");
let requestSeq = 0;
let debounceTimer = null;

// ---- Navigation -------------------------------------------------------
function showView(button) {
  document.querySelectorAll(".sidebar button").forEach((b) => b.classList.toggle("active", b === button));
  document.querySelectorAll(".view").forEach((v) => v.classList.add("hidden"));
  const view = button.dataset.view;
  if (view === "planned") {
    $("#planned-title").textContent = button.dataset.name;
    $("#planned-phase").textContent = button.dataset.phase;
  }
  $(`#view-${view}`).classList.remove("hidden");
  if (view === "box") scheduleCalculate(0);
}
document.querySelectorAll(".sidebar button").forEach((b) => b.addEventListener("click", () => showView(b)));
document.querySelectorAll("[data-goto]").forEach((b) =>
  b.addEventListener("click", () => showView(document.querySelector(`.sidebar button[data-view="${b.dataset.goto}"]`)))
);

// ---- Formular ---------------------------------------------------------
function formData() {
  const data = {};
  for (const el of form.elements) {
    if (!el.name) continue;
    data[el.name] = el.type === "number" ? el.value.trim() : el.value;
  }
  return data;
}

function fmt(n) {
  return Number(n).toLocaleString("de-DE", { maximumFractionDigits: 3 });
}

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className = `status ${kind || ""}`;
}

function showErrors(errors) {
  const list = $("#errors");
  list.innerHTML = "";
  form.querySelectorAll(".invalid").forEach((el) => el.classList.remove("invalid"));
  for (const err of errors) {
    const li = document.createElement("li");
    li.textContent = err.message;
    list.appendChild(li);
    if (err.field && form.elements[err.field]) form.elements[err.field].classList.add("invalid");
  }
}

function renderResult(r) {
  $("#inner").textContent =
    `Länge ${fmt(r.inner.length)} mm × Breite ${fmt(r.inner.width)} mm × Höhe ${fmt(r.inner.height)} mm`;
  const tbody = $("#parts");
  tbody.innerHTML = "";
  for (const p of r.panels) {
    const tr = document.createElement("tr");
    for (const text of [p.name, `${fmt(p.width)} × ${fmt(p.height)}`, `${fmt(p.cut_width)} × ${fmt(p.cut_height)}`]) {
      const td = document.createElement("td");
      td.textContent = text;
      tr.appendChild(td);
    }
    tbody.appendChild(tr);
  }
  const warn = $("#warnings");
  warn.innerHTML = "";
  for (const w of r.warnings) {
    const li = document.createElement("li");
    li.textContent = w;
    warn.appendChild(li);
  }
  $("#layout-method").textContent = `Anordnung: ${r.layout.method}.`;
  // Vom eigenen lokalen Server erzeugtes SVG (Texte sind dort XML-escaped).
  $("#preview").innerHTML = r.preview_svg.replace(/^<\?xml[^>]*\?>\s*/, "");
  $("#summary").classList.remove("hidden");
}

async function calculate() {
  const seq = ++requestSeq;
  exportBtn.disabled = true;
  setStatus("Berechne …", "busy");
  let res, body;
  try {
    res = await fetch("/api/box/calculate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(formData()),
    });
    body = await res.json();
  } catch (e) {
    if (seq !== requestSeq) return;
    setStatus("Keine Verbindung zum lokalen Programm. Läuft das Startfenster noch?", "error");
    return;
  }
  if (seq !== requestSeq) return; // veraltete Antwort
  if (!body.ok) {
    showErrors(body.errors || []);
    $("#summary").classList.add("hidden");
    setStatus("Konstruktion nicht möglich – bitte Eingaben prüfen. Es wird keine Datei erzeugt.", "error");
    return;
  }
  showErrors([]);
  renderResult(body.result);
  setStatus("Konstruktion rechnerisch geprüft: Teile passen lückenlos und ohne Überschneidung zusammen.", "ok");
  exportBtn.disabled = false;
}

let lastScheduled = null;

function scheduleCalculate(delay = 300) {
  // Ein "change" beim Verlassen eines Feldes (z. B. Klick auf "SVG herunterladen")
  // darf den Export nicht sperren, wenn sich die Eingaben nicht geändert haben.
  const snapshot = JSON.stringify(formData());
  if (snapshot === lastScheduled && delay !== 0) return;
  lastScheduled = snapshot;
  clearTimeout(debounceTimer);
  exportBtn.disabled = true;
  debounceTimer = setTimeout(calculate, delay);
}

form.addEventListener("input", () => scheduleCalculate());
form.addEventListener("change", () => scheduleCalculate());
form.addEventListener("submit", (e) => e.preventDefault());

// ---- Export -----------------------------------------------------------
exportBtn.addEventListener("click", async () => {
  exportBtn.disabled = true;
  try {
    const res = await fetch("/api/box/export", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(formData()),
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({ errors: [{ message: "Export fehlgeschlagen." }] }));
      showErrors(body.errors || []);
      setStatus("Export abgelehnt – die Konstruktion ist fehlerhaft.", "error");
      return;
    }
    const disposition = res.headers.get("Content-Disposition") || "";
    const match = disposition.match(/filename\*=UTF-8''([^;]+)/);
    const filename = match ? decodeURIComponent(match[1]) : "kiste.svg";
    const url = URL.createObjectURL(await res.blob());
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setStatus(`SVG gespeichert als „${filename}“ (Download-Ordner des Browsers).`, "ok");
  } catch (e) {
    setStatus("Keine Verbindung zum lokalen Programm. Läuft das Startfenster noch?", "error");
  } finally {
    exportBtn.disabled = false;
  }
});

// ---- Start ------------------------------------------------------------
fetch("/api/info")
  .then((r) => r.json())
  .then((info) => { $("#version").textContent = `Version ${info.version} · Phase 1`; })
  .catch(() => {});
