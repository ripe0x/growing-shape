import { useCallback, useEffect, useRef, useState } from "react";
import { createWalletClient, custom, http } from "viem";
import type { Address, WalletClient, EIP1193Provider } from "viem";
import { chain } from "./chain";
import { CHAIN_ID, RPC_URL } from "./config";

export type Connector = { uuid: string; name: string; icon?: string; provider: EIP1193Provider };

type Eip6963Detail = { info: { uuid: string; name: string; icon: string; rdns: string }; provider: EIP1193Provider };

export type Wallet = {
  account?: Address;
  chainId?: number;
  walletClient?: WalletClient;
  connectors: Connector[];
  connectInjected: (c: Connector) => Promise<void>;
  connectLocal: (addr: Address) => void;
  disconnect: () => void;
  wrongChain: boolean;
  error?: string;
};

export function useWallet(): Wallet {
  const [connectors, setConnectors] = useState<Connector[]>([]);
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [walletClient, setWalletClient] = useState<WalletClient>();
  const [error, setError] = useState<string>();
  const providerRef = useRef<EIP1193Provider | undefined>(undefined);

  // EIP-6963 discovery of injected wallets.
  useEffect(() => {
    const onAnnounce = (e: Event) => {
      const detail = (e as CustomEvent<Eip6963Detail>).detail;
      setConnectors((prev) =>
        prev.some((c) => c.uuid === detail.info.uuid)
          ? prev
          : [...prev, { uuid: detail.info.uuid, name: detail.info.name, icon: detail.info.icon, provider: detail.provider }],
      );
    };
    window.addEventListener("eip6963:announceProvider", onAnnounce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    return () => window.removeEventListener("eip6963:announceProvider", onAnnounce);
  }, []);

  const connectInjected = useCallback(async (c: Connector) => {
    setError(undefined);
    try {
      const accounts = (await c.provider.request({ method: "eth_requestAccounts" })) as Address[];
      const cid = Number((await c.provider.request({ method: "eth_chainId" })) as string);
      providerRef.current = c.provider;
      setAccount(accounts[0]);
      setChainId(cid);
      setWalletClient(createWalletClient({ account: accounts[0], chain, transport: custom(c.provider) }));

      const onAccounts = (accs: unknown) => {
        const list = accs as Address[];
        if (!list.length) return disconnect();
        setAccount(list[0]);
        setWalletClient(createWalletClient({ account: list[0], chain, transport: custom(c.provider) }));
      };
      const onChain = (id: unknown) => setChainId(Number(id as string));
      c.provider.on?.("accountsChanged", onAccounts);
      c.provider.on?.("chainChanged", onChain);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to connect wallet.");
    }
  }, []);

  // Dev-only: send through anvil's unlocked accounts (chainId 31337 gates this in the UI).
  const connectLocal = useCallback((addr: Address) => {
    setError(undefined);
    setAccount(addr);
    setChainId(CHAIN_ID);
    setWalletClient(createWalletClient({ account: addr, chain, transport: http(RPC_URL) }));
  }, []);

  const disconnect = useCallback(() => {
    providerRef.current = undefined;
    setAccount(undefined);
    setChainId(undefined);
    setWalletClient(undefined);
  }, []);

  return {
    account, chainId, walletClient, connectors,
    connectInjected, connectLocal, disconnect,
    wrongChain: account !== undefined && chainId !== undefined && chainId !== CHAIN_ID,
    error,
  };
}
