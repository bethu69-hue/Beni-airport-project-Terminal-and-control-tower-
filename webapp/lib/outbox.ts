// Offline outbox: writes made without a connection are stored on the device (IndexedDB) and replayed in order.
// Design rules for a contract system:
//  * Each queued item has a client_id (uuid). The server function must treat a repeated client_id as a no-op, so a retry never creates a duplicate.
//  * The server stamps the real time. The device time is stored only as "captured_at" and shown as unverified.
//  * Notices and sign-offs are NOT queued offline. They need the live server to record the true time, so the screen says "connect to issue".
//  * Items that fail validation stay in the outbox with the server's message; nothing is silently dropped.
// UNTESTED: written without a build environment.
import { openDB } from 'idb';

export type OutboxItem = {
  client_id: string; rpc: string; args: Record<string, unknown>;
  captured_at: string; status: 'pending' | 'sent' | 'rejected'; error?: string;
};
export const NEVER_OFFLINE = ['sign_record', 'issue_report', 'create_deadline_for_notice', 'change_deadline', 'satisfy_deadline'];

const db = () => openDB('beni-outbox', 1, { upgrade(d) { d.createObjectStore('items', { keyPath: 'client_id' }); } });

export async function enqueue(rpc: string, args: Record<string, unknown>) {
  if (NEVER_OFFLINE.includes(rpc)) throw new Error('This action needs a connection so the server can record the true time.');
  const item: OutboxItem = { client_id: crypto.randomUUID(), rpc, args, captured_at: new Date().toISOString(), status: 'pending' };
  await (await db()).put('items', item);
  const reg = await navigator.serviceWorker?.ready;
  // @ts-expect-error Background Sync is not in every TypeScript lib
  if (reg?.sync) await reg.sync.register('beni-outbox');
  return item;
}

export async function flush(supabase: { rpc: (n: string, a: object) => Promise<{ error: { message: string } | null }> }) {
  const d = await db();
  const items = (await d.getAll('items')) as OutboxItem[];
  for (const it of items.filter((i) => i.status === 'pending')) {
    const { error } = await supabase.rpc(it.rpc, { ...it.args, p_client_id: it.client_id });
    await d.put('items', error ? { ...it, status: 'rejected', error: error.message } : { ...it, status: 'sent' });
  }
}
export async function list() { return (await (await db()).getAll('items')) as OutboxItem[]; }
