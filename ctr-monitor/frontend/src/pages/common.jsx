import { useApp } from "../App";
import { go } from "../hooks";
import { Empty, Panel } from "../components/ui";
import UploadForm from "../components/UploadForm";

export function NoRun({ runs }) {
  const { info, refresh } = useApp();
  if (runs === null) return <Empty title="Loading…" />;
  const active = runs.some((r) => r.status === "queued" || r.status === "running");
  if (active) {
    return (
      <Empty title="First run in progress…">
        <p>Results appear here as soon as the run finishes.</p>
        <a className="btn primary" href="#/runs">Watch progress</a>
      </Empty>
    );
  }
  return (
    <Panel title="Upload data & run analysis" sub="no completed analysis yet — start with your two input files">
      <UploadForm info={info} onCreated={(r) => { refresh(); go(`runs/${r.id}`); }} autoFocus />
    </Panel>
  );
}
export function useResult(ctx) {
  const { run, res, resErr } = ctx;
  if (!run) return { block: <NoRun runs={ctx.runs} /> };
  if (resErr) return { block: <div className="alert err">Could not load results: {resErr.message}</div> };
  if (!res) return { block: <Empty title="Loading results…" /> };
  return { res };
}
