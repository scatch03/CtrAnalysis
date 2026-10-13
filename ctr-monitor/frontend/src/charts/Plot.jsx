import { useMemo, useRef, useState } from "react";
import { useMeasure } from "../hooks";
import { linear, logScale, ticks as mkTicks, timeTicks } from "./scale";
import { tickTime } from "../format";

/**
 * Chart frame: measures its width, builds scales, draws the recessive grid and
 * axes, then hands {sx, sy, iw, ih} to `children`. Hover is generic:
 * `hover(px, py, ctx)` returns {x, y, content, xLine?, marks?} or null.
 */
export default function Plot({
  height = 220, margin: m0, x, y, xTickFmt, yTickFmt, xTitle, yTitle, yTicks: yTicksIn, xTicks: xTicksIn,
  vgrid = false, hover, onClick, children, watermark, label, minWidth = 260,
}) {
  const [ref, width] = useMeasure();
  const [tip, setTip] = useState(null);
  const svgRef = useRef(null);
  const m = { top: 10, right: watermark ? 22 : 12, bottom: xTitle ? 40 : 26, left: yTitle ? 58 : 46, ...m0 };
  const w = Math.max(width, minWidth);
  const iw = Math.max(10, w - m.left - m.right), ih = Math.max(10, height - m.top - m.bottom);

  const ctx = useMemo(() => {
    const sx = x.type === "log" ? logScale(x.domain, [0, iw]) : linear(x.domain, [0, iw]);
    const sy = y.type === "log" ? logScale(y.domain, [ih, 0]) : linear(y.domain, [ih, 0]);
    let xt = xTicksIn, xStep = null;
    if (!xt) {
      if (x.type === "time") { const t = timeTicks(x.domain[0], x.domain[1], Math.max(2, Math.floor(iw / 90))); xt = t.ticks; xStep = t.step; }
      else xt = mkTicks(x.domain[0], x.domain[1], Math.max(2, Math.floor(iw / 80)));
    }
    const yt = yTicksIn || mkTicks(y.domain[0], y.domain[1], Math.max(3, Math.floor(ih / 36)));
    return { sx, sy, iw, ih, xt, yt, xStep };
  }, [x.type, x.domain[0], x.domain[1], y.type, y.domain[0], y.domain[1], iw, ih, xTicksIn, yTicksIn]);

  const fx = xTickFmt || (x.type === "time" ? (v) => tickTime(v, ctx.xStep) : (v) => String(v));
  const fy = yTickFmt || ((v) => String(v));

  function move(e) {
    if (!hover || !svgRef.current) return;
    const r = svgRef.current.getBoundingClientRect();
    const px = e.clientX - r.left - m.left, py = e.clientY - r.top - m.top;
    if (px < -4 || px > iw + 4 || py < -4 || py > ih + 4) { setTip(null); return; }
    setTip(hover(Math.min(Math.max(px, 0), iw), py, ctx));
  }

  let tipStyle = null;
  if (tip) {
    const left = m.left + tip.x, top = m.top + (tip.y ?? 0);
    const flip = left > w * 0.6;
    tipStyle = { top: Math.max(0, top - 10), ...(flip ? { right: w - left + 14 } : { left: left + 14 }) };
  }

  return (
    <div className="chart" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg ref={svgRef} width={w} height={height} role="img" aria-label={label}
             onPointerMove={move} onPointerLeave={() => setTip(null)}
             onClick={onClick && tip ? () => onClick(tip) : undefined}
             style={{ cursor: onClick && tip?.clickable ? "pointer" : undefined }}>
          <g transform={`translate(${m.left},${m.top})`}>
            {ctx.yt.map((t) => (
              <g key={`y${t}`}>
                <line className="gridline" x1={0} x2={iw} y1={Math.round(ctx.sy(t)) + 0.5} y2={Math.round(ctx.sy(t)) + 0.5} />
                <text x={-7} y={ctx.sy(t)} dy="0.32em" textAnchor="end">{fy(t)}</text>
              </g>
            ))}
            {ctx.xt.map((t) => (
              <g key={`x${t}`}>
                {vgrid && <line className="gridline" x1={Math.round(ctx.sx(t)) + 0.5} x2={Math.round(ctx.sx(t)) + 0.5} y1={0} y2={ih} />}
                <text x={ctx.sx(t)} y={ih + 15} textAnchor="middle">{fx(t)}</text>
              </g>
            ))}
            <line className="baseline" x1={0} x2={iw} y1={ih + 0.5} y2={ih + 0.5} />
            {yTitle && <text className="axis-title" transform={`translate(${-m.left + 12},${ih / 2}) rotate(-90)`} textAnchor="middle">{yTitle}</text>}
            {xTitle && <text className="axis-title" x={iw / 2} y={ih + 33} textAnchor="middle">{xTitle}</text>}
            {children(ctx)}
            {tip?.xLine !== undefined && <line className="xhair" x1={tip.xLine} x2={tip.xLine} y1={0} y2={ih} />}
            {tip?.marks}
            {watermark && (
              <text className="watermark" transform={`translate(${iw + 14},${ih / 2}) rotate(90)`} textAnchor="middle">{watermark}</text>
            )}
          </g>
        </svg>
      )}
      {tip && <div className="tip" style={tipStyle}>{tip.content}</div>}
    </div>
  );
}

export function TipRow({ color, kind = "line", label, value }) {
  return (
    <div className="r">
      <span>{color && <i className={`key ${kind}`} style={{ background: color }} />}{label}</span>
      <b>{value}</b>
    </div>
  );
}

export function Legend({ items }) {
  return (
    <div className="legend">
      {items.map((it) => (
        <span key={it.label} className={it.off ? "off" : undefined}>
          {it.kind === "dash" ? (
            <svg width="18" height="6" aria-hidden="true"><line x1="0" x2="18" y1="3" y2="3" stroke={it.color} strokeWidth="2" strokeDasharray={it.dash || "5 3"} /></svg>
          ) : (
            <i className={`key ${it.kind || "line"}`} style={{ background: it.color }} />
          )}
          {it.label}
        </span>
      ))}
    </div>
  );
}
