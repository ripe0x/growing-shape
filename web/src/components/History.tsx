import type { Address } from "viem";
import type { CycleEntry } from "../chain";
import { Art } from "../Art";
import { ethUnit, shortAddr } from "../format";
import { EXPLORER_TX } from "../config";

export function History({ shapes, entries, loading }: { shapes: Address; entries: CycleEntry[] | null; loading: boolean }) {
  return (
    <section className="section">
      <h2>Completed cycles</h2>
      {loading && !entries ? (
        <div className="card"><div className="center-muted"><span className="spin" /> Loading history…</div></div>
      ) : !entries || entries.length === 0 ? (
        <div className="card"><div className="center-muted">No featured Shape has been won yet. Completed cycles will appear here.</div></div>
      ) : (
        entries
          .slice()
          .reverse()
          .map((e) => (
            <div className="card" key={e.index}>
              <div className="outcome" style={{ borderBottom: 0, padding: 0 }}>
                <div className="thumb" style={{ width: 72, height: 72 }}><Art collection={shapes} tokenId={e.tokenId} alt={`Won Shape #${e.tokenId}`} /></div>
                <div className="meta">
                  <div className="what">Shape #{e.tokenId.toString()} · {ethUnit(e.backing)}</div>
                  <div className="sub">{e.compositions} compositions · {e.draws} draws</div>
                  <div className="req">won by {shortAddr(e.winner)}{" "}
                    {e.txHash && (EXPLORER_TX
                      ? <a className="link" href={`${EXPLORER_TX}${e.txHash}`} target="_blank" rel="noreferrer">tx ↗</a>
                      : <span>· tx {shortAddr(e.txHash)}</span>)}
                  </div>
                </div>
                <span className="pill">#{e.index + 1}</span>
              </div>
            </div>
          ))
      )}
    </section>
  );
}
