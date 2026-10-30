import { useEffect, useState } from "react";
import type { Address } from "viem";
import { fetchArt } from "./chain";

// Renders a token's onchain artwork from its tokenURI image. undefined = loading.
export function Art({ collection, tokenId, isPack, alt }: { collection: Address; tokenId: bigint; isPack?: boolean; alt: string }) {
  const [src, setSrc] = useState<string | null | undefined>(undefined);
  useEffect(() => {
    let on = true;
    setSrc(undefined);
    fetchArt(collection, tokenId, isPack).then((s) => on && setSrc(s));
    return () => {
      on = false;
    };
  }, [collection, tokenId, isPack]);

  if (src === undefined) return <div className="art-frame"><div className="art--loading" /></div>;
  if (!src) return <div className="art-frame"><div className="art--empty" role="img" aria-label={alt}>no art</div></div>;
  return <div className="art-frame"><img className="art" src={src} alt={alt} loading="lazy" /></div>;
}
