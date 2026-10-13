import { useState } from "react";
import { useApp } from "../App";
import { api, fileUrl } from "../api";
import { useAsync } from "../hooks";
import { Empty, Panel } from "../components/ui";
import { NoRun } from "./common";

function useCopy() {
  const [copied, setCopied] = useState(null);
  const copy = (key, text) => navigator.clipboard?.writeText(text || "").then(
    () => { setCopied(key); setTimeout(() => setCopied(null), 1500); }, () => {});
  return [copied, copy];
}

export default function Summary() {
  const { run, runs } = useApp();
  const t = useAsync(() => (run ? api.text(run.id, "results_summary.txt") : null), [run?.id]);
  const [copied, copy] = useCopy();
  if (!run) return <NoRun runs={runs} />;
  return (
    <>
      <Panel title="results_summary.txt" sub="verbatim output of write_summary()" flush
             tools={<>
               <button className="btn sm" onClick={() => copy("raw", t.data)} disabled={!t.data}>{copied === "raw" ? "Copied" : "Copy"}</button>
               <a className="btn sm" href={fileUrl(run.id, "results_summary.txt", true)}>Download</a>
             </>}>
        {t.error ? <div className="alert err" style={{ margin: 14 }}>{t.error.message}</div>
          : t.loading ? <Empty title="Loading…" /> : <pre className="summary-pre">{t.data}</pre>}
      </Panel>
    </>
  );
}
