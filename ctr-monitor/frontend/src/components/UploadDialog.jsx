import { useEffect, useRef } from "react";
import UploadForm from "./UploadForm";

/** Native <dialog>: Esc, focus trapping and the backdrop come for free. */
export default function UploadDialog({ open, onClose, info, onCreated }) {
  const ref = useRef(null);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);
  return (
    <dialog ref={ref} className="modal" onClose={onClose} onCancel={onClose}
            onClick={(e) => { if (e.target === ref.current) onClose(); }} aria-labelledby="upload-title">
      {open && (
        <div className="modal-body">
          <div className="panel-h">
            <h2 id="upload-title">Upload data &amp; run analysis</h2>
            <span className="sub">{info?.script?.version}</span>
            <div className="tools"><button type="button" className="btn sm ghost" onClick={onClose} aria-label="Close">✕</button></div>
          </div>
          <div className="panel-b"><UploadForm info={info} onCreated={onCreated} autoFocus /></div>
        </div>
      )}
    </dialog>
  );
}
