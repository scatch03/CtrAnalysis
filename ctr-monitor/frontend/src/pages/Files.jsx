import { useState } from "react";
import { useApp } from "../App";
import { api, bundleUrl, fileUrl } from "../api";
import { useAsync } from "../hooks";
import { bytes } from "../format";
import { DataTable, Empty, Panel, RecordsTable } from "../components/ui";
import { useResult } from "./common";

export default function Files() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const [table, setTable] = useState(null);
  const t = useAsync(() => (table && ctx.run ? api.table(ctx.run.id, table) : null), [ctx.run?.id, table]);
  if (block) return block;
  const run = ctx.run;
  const figs = res.figures || [];
  const files = (res.files || []).filter((f) => f.kind !== "preview");
  return (
    <>
      <Panel title="Publication figures" sub="rendered by the script itself (PDF) · PNG previews"
             tools={<a className="btn sm primary" href={bundleUrl(run.id)}>Download all (.zip)</a>}>
        {figs.length === 0 ? <Empty title="No figures" /> : (
          <div className="gallery">
            {figs.map((f) => (
              <div key={f.name} className="panel fig">
                <div className="img">{f.png ? <img src={fileUrl(run.id, f.png)} alt={f.name} loading="lazy" /> : <span className="muted">no preview</span>}</div>
                <div className="cap"><b className="mono" style={{ fontSize: 11.5 }}>{f.name}</b>{f.caption && <div className="muted" style={{ marginTop: 3 }}>↳ {f.caption}</div>}</div>
                <div className="acts">
                  <a className="btn sm" href={fileUrl(run.id, f.file)} target="_blank" rel="noreferrer">Open PDF</a>
                  <a className="btn sm" href={fileUrl(run.id, f.file, true)}>Download</a>
                  {f.png && <a className="btn sm ghost" href={fileUrl(run.id, f.png, true)}>PNG</a>}
                </div>
              </div>
            ))}
          </div>
        )}
      </Panel>
      <div className="grid g-side" style={{ gridTemplateColumns: "minmax(0,380px) minmax(0,1fr)" }}>
        <Panel title="Output files" sub={`${files.length}`} flush>
          <DataTable rows={files.map((f) => ({ ...f, __key: f.name }))} onRowClick={(f) => f.kind === "table" && setTable(f.name)}
            rowClass={(f) => (f.name === table ? "expanded" : "")}
            columns={[
              { key: "name", label: "File", render: (f) => <span className="mono" style={{ fontSize: 11.5 }}>{f.name}</span> },
              { key: "kind", label: "Kind", render: (f) => <span className="tag">{f.kind}</span> },
              { key: "size", label: "Size", num: true, fmt: bytes },
              { key: "dl", label: "", sort: false, render: (f) => <a href={fileUrl(run.id, f.name, true)} onClick={(e) => e.stopPropagation()}>↓</a> },
            ]} />
        </Panel>
        <Panel title={table || "Table viewer"} sub={table ? "click another CSV to switch" : "click a CSV on the left"} flush>
          {!table ? <Empty title="No table selected" /> : t.error ? <div className="alert err" style={{ margin: 14 }}>{t.error.message}</div>
            : !t.data ? <Empty title="Loading…" /> : <RecordsTable columns={t.data.columns} rows={t.data.rows} maxHeight={560} />}
        </Panel>
      </div>
    </>
  );
}
