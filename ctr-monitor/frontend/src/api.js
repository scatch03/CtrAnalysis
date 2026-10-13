async function req(path, opts = {}) {
  const r = await fetch(path, opts);
  if (!r.ok) {
    let msg = `${r.status} ${r.statusText}`;
    try { const j = await r.json(); if (j.error) msg = j.error; } catch { /* not json */ }
    throw new Error(msg);
  }
  if (r.status === 204) return null;
  const ct = r.headers.get("content-type") || "";
  return ct.includes("application/json") ? r.json() : r.text();
}

export const api = {
  info: () => req("/api/info"),
  runs: () => req("/api/runs"),
  run: (id) => req(`/api/runs/${id}`),
  result: (id) => req(`/api/runs/${id}/result`),
  narrative: (id) => req(`/api/runs/${id}/narrative`),
  log: (id, offset) => req(`/api/runs/${id}/log${offset != null ? `?offset=${offset}` : ""}`),
  mrtg: (id, campaign) => req(`/api/runs/${id}/mrtg${campaign ? `?campaign=${encodeURIComponent(campaign)}` : ""}`),
  table: (id, name) => req(`/api/runs/${id}/tables/${encodeURIComponent(name)}`),
  text: (id, name) => req(`/api/runs/${id}/files/${encodeURIComponent(name)}`),
  cancel: (id) => req(`/api/runs/${id}/cancel`, { method: "POST" }),
  remove: (id) => req(`/api/runs/${id}`, { method: "DELETE" }),
  create: (form) => req("/api/runs", { method: "POST", body: form }),
};

export const fileUrl = (id, name, download) =>
  `/api/runs/${id}/files/${encodeURIComponent(name)}${download ? "?download=1" : ""}`;
export const bundleUrl = (id) => `/api/runs/${id}/bundle.zip`;

// XHR for upload progress (fetch has no upload progress events)
export function upload(form, onProgress) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open("POST", "/api/runs");
    x.upload.onprogress = (e) => e.lengthComputable && onProgress?.(e.loaded / e.total);
    x.onload = () => {
      let body = null;
      try { body = JSON.parse(x.responseText); } catch { /* ignore */ }
      if (x.status >= 200 && x.status < 300) resolve(body);
      else reject(new Error(body?.error || `${x.status} ${x.statusText}`));
    };
    x.onerror = () => reject(new Error("network error"));
    x.send(form);
  });
}
