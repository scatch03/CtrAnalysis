import { useEffect, useId, useRef, useState } from "react";
import { upload } from "../api";
import { bytes } from "../format";

const ACCEPT = ".csv,.txt,.gz,.bz2,.xz,.zip";
const SPEC = {
  mapping: { title: "Mapping file", cols: 2, columns: "banner_id, campaign_id", example: "10234,517" },
  events: { title: "Events file", cols: 5, columns: "date, hour, banner_id, impressions, clicks", example: "2026-02-27,0,10234,1840,37" },
};
const isCompressed = (name) => /\.(gz|bz2|xz|zip)$/i.test(name);

/** Peek at the first lines of an uncompressed CSV — catches swapped files and header rows before upload. */
async function sniff(file) {
  if (isCompressed(file.name)) return { compressed: true };
  const text = await file.slice(0, 16384).text();
  const lines = text.split(/\r?\n/).filter((l) => l.trim()).slice(0, 3);
  const cols = lines.length ? lines[0].split(",").length : 0;
  return { compressed: false, lines, cols };
}

function problems(role, info) {
  if (!info || info.compressed) return [];
  const out = [];
  const want = SPEC[role].cols;
  if (!info.lines.length) out.push("file looks empty");
  else if (info.cols !== want) {
    const other = role === "mapping" ? "events" : "mapping";
    out.push(`expected ${want} columns, found ${info.cols}${info.cols === SPEC[other].cols ? ` — this looks like the ${other} file` : ""}`);
  } else if (role === "events" && !/^\d{4}-\d{2}-\d{2}$/.test(info.lines[0].split(",")[0].trim())) {
    out.push("first row doesn't start with a YYYY-MM-DD date — the script expects no header row");
  }
  return out;
}

function FileField({ role, file, info, onFile, onClear }) {
  const id = useId();
  const input = useRef(null);
  const [over, setOver] = useState(false);
  const spec = SPEC[role];
  const warn = problems(role, info);
  return (
    <div className={`drop${over ? " over" : ""}${file ? (warn.length ? " bad" : " has") : ""}`}
         onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)}
         onDrop={(e) => { e.preventDefault(); setOver(false); if (e.dataTransfer.files[0]) onFile(e.dataTransfer.files[0]); }}>
      <label htmlFor={id} className="drop-title">{spec.title} <span className="req">required</span></label>
      <div className="drop-cols mono">{spec.columns}</div>
      <input id={id} ref={input} type="file" accept={ACCEPT} className="sr-only"
             onChange={(e) => { if (e.target.files[0]) onFile(e.target.files[0]); e.target.value = ""; }} />
      {file ? (
        <div className="drop-file">
          <span className="fn">{file.name}</span>
          <span className="muted">{bytes(file.size)}{info?.compressed ? " · compressed" : info?.cols ? ` · ${info.cols} columns` : ""}</span>
          <span className="drop-acts">
            <button type="button" className="btn sm" onClick={() => input.current?.click()}>Change…</button>
            <button type="button" className="btn sm ghost" onClick={onClear} aria-label={`Remove ${spec.title}`}>✕</button>
          </span>
        </div>
      ) : (
        <div className="drop-pick">
          <button type="button" className="btn" onClick={() => input.current?.click()}>Choose file…</button>
          <span className="muted">or drop it here</span>
        </div>
      )}
      {info?.lines?.length > 0 && (
        <pre className="drop-preview">{info.lines.join("\n")}</pre>
      )}
      {warn.map((w) => <div key={w} className="drop-warn">⚠ {w}</div>)}
      {!file && <div className="drop-hint">CSV without header, e.g. <span className="mono">{spec.example}</span> · .gz/.bz2/.xz/.zip ok</div>}
    </div>
  );
}

/**
 * Upload the two input files (or reuse a previous run's inputs) and queue an analysis run.
 * `compact` drops the explanatory text for use at the top of a results page.
 */
export default function UploadForm({ info, fromRun, clearFrom, onCreated, compact = false, autoFocus = false }) {
  const [files, setFiles] = useState({ mapping: null, events: null });
  const [sniffs, setSniffs] = useState({ mapping: null, events: null });
  const [label, setLabel] = useState("");
  const [minImpr, setMinImpr] = useState("");
  const [dpi, setDpi] = useState("300");
  const [busy, setBusy] = useState(null);
  const [err, setErr] = useState(null);
  const firstBtn = useRef(null);
  const def = info?.script?.default_min_impr ?? 10;
  const s = info?.script;

  useEffect(() => {
    if (fromRun) { setMinImpr(String(fromRun.params?.min_impr ?? def)); setDpi(String(fromRun.params?.dpi ?? 300)); setLabel(""); }
  }, [fromRun]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (autoFocus) firstBtn.current?.querySelector("button")?.focus(); }, [autoFocus]);

  async function setFile(role, file) {
    setErr(null);
    setFiles((f) => ({ ...f, [role]: file }));
    setSniffs((x) => ({ ...x, [role]: null }));
    if (file) {
      const info2 = await sniff(file).catch(() => null);
      setSniffs((x) => ({ ...x, [role]: info2 }));
    }
  }
  const swap = () => { setFiles((f) => ({ mapping: f.events, events: f.mapping })); setSniffs((x) => ({ mapping: x.events, events: x.mapping })); };
  const swapped = sniffs.mapping?.cols === SPEC.events.cols && sniffs.events?.cols === SPEC.mapping.cols;
  const blocking = !fromRun && (problems("mapping", sniffs.mapping).length > 0 || problems("events", sniffs.events).length > 0);
  const ready = fromRun || (files.mapping && files.events);

  async function submit(e) {
    e.preventDefault();
    if (!ready) { setErr("Choose both files first."); return; }
    setErr(null);
    const f = new FormData();
    if (fromRun) f.append("from_run", fromRun.id);
    else { f.append("mapping", files.mapping); f.append("events", files.events); }
    f.append("label", label);
    f.append("min_impr", minImpr || String(def));
    f.append("dpi", dpi || "300");
    setBusy(0);
    try {
      const r = await upload(f, (p) => setBusy(p));
      setFiles({ mapping: null, events: null }); setSniffs({ mapping: null, events: null }); setLabel("");
      clearFrom?.();
      onCreated?.(r);
    } catch (e2) { setErr(e2.message); } finally { setBusy(null); }
  }

  return (
    <form onSubmit={submit} className="upload-form" noValidate>
      {s && !s.present && <div className="alert err">Analysis script not found at <span className="mono">{s.path}</span>.</div>}
      {s?.present && !s.structured && (
        <div className="alert info">This script lacks {s.missing_api.join(", ")} — runs use its own <span className="mono">main()</span> (summary &amp; files only).</div>
      )}

      {fromRun ? (
        <div className="alert info" style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
          Re-using the input files of <b>{fromRun.label}</b>
          <span className="muted">({fromRun.inputs?.events?.name}, {fromRun.inputs?.mapping?.name})</span>
          <button type="button" className="btn sm" onClick={clearFrom} style={{ marginLeft: "auto" }}>Upload new files instead</button>
        </div>
      ) : (
        <>
          <div className="grid g2" ref={firstBtn}>
            <FileField role="mapping" file={files.mapping} info={sniffs.mapping} onFile={(f) => setFile("mapping", f)} onClear={() => setFile("mapping", null)} />
            <FileField role="events" file={files.events} info={sniffs.events} onFile={(f) => setFile("events", f)} onClear={() => setFile("events", null)} />
          </div>
          {swapped && (
            <div className="alert info" style={{ display: "flex", gap: 10, alignItems: "center" }}>
              The two files look swapped.<button type="button" className="btn sm" onClick={swap}>Swap them</button>
            </div>
          )}
        </>
      )}

      <div className="form-row">
        <div className="field"><label htmlFor="up-label">Label <span className="muted">(optional)</span></label>
          <input id="up-label" type="text" placeholder={fromRun ? fromRun.label : files.events?.name || "e.g. network 2615, March"}
                 value={label} onChange={(e) => setLabel(e.target.value)} maxLength={80} /></div>
        <div className="field"><label htmlFor="up-min">Min impressions per hour</label>
          <input id="up-min" type="number" min={1} placeholder={String(def)} value={minImpr} onChange={(e) => setMinImpr(e.target.value)} /></div>
        <div className="field"><label htmlFor="up-dpi">Figure DPI</label>
          <input id="up-dpi" type="number" min={50} max={1200} value={dpi} onChange={(e) => setDpi(e.target.value)} /></div>
        <div className="field" style={{ display: "flex", alignItems: "flex-end" }}>
          <button className="btn primary lg" type="submit" disabled={busy !== null || (s && !s.present)}
                  title={blocking ? "check the file warnings above" : undefined}>
            {busy !== null ? <><span className="spin" /> {busy < 1 ? `Uploading ${Math.round(busy * 100)}%` : "Queuing…"}</> : "Upload & run analysis"}
          </button>
        </div>
      </div>
      {busy !== null && busy < 1 && <div className="progress"><div style={{ width: `${Math.round(busy * 100)}%` }} /></div>}
      {err && <div className="alert err">{err}</div>}
      {blocking && !err && <div className="drop-warn">⚠ Check the file warnings above — the run will likely fail or produce nonsense with these files.</div>}
      {!compact && (
        <div className="muted" style={{ fontSize: 11.5 }}>
          Same inputs as <span className="mono">ctr_analysis.py --mapping … --events …</span>. Files are kept with the run on this
          server so it can be re-run with other parameters. Max upload {info?.config?.max_upload_mb ?? "…"} MB.
        </div>
      )}
    </form>
  );
}
