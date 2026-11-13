export const SERVICE_TYPE = '_neartransfer._tcp';
export const MAX_FILES = 128;
export const CONTROL_LIMIT = 128 * 1024;
export const CHUNK_SIZE = 128 * 1024;
export const IO_TIMEOUT = 15000;
export const WAIT_TIME = 90000;
export const ACCEPTED_IDLE = 10 * 60 * 1000;

export interface Codec {
  encode(text: string): Uint8Array;
  decode(bytes: Uint8Array): string;
}

export interface Peer {
  id: string;
  name: string;
  address: string;
  port: number;
  platform: string;
}

export interface FileSpec {
  id: string;
  name: string;
  size: number;
}

export interface Offer {
  requestId: string;
  senderId: string;
  senderPort: number;
  files: FileSpec[];
}

export interface Proof {
  requestId: string;
  receiverId: string;
}

export interface Verification {
  verified: boolean;
}

export enum SessionState {
  Waiting = 'waiting',
  Accepted = 'accepted',
  Declined = 'declined',
  Canceled = 'canceled',
  Expired = 'expired',
  Completed = 'completed',
  Partial = 'partial',
  Failed = 'failed'
}

export enum FileState {
  Pending = 'pending',
  Uploading = 'uploading',
  Committed = 'committed',
  Failed = 'failed'
}

export interface Receipt {
  id: string;
  state: FileState;
  bytes: number;
  error?: string;
  name?: string;
}

export interface Snapshot {
  id: string;
  state: SessionState;
  files: Receipt[];
  token?: string;
}

export interface SavedFile {
  name: string;
  path: string;
}

export interface Reader {
  read(max: number): Promise<Uint8Array>;
  close(): Promise<void>;
}

export interface Source {
  spec: FileSpec;
  open(): Promise<Reader>;
}

export interface Target {
  write(bytes: Uint8Array): Promise<void>;
  commit(): Promise<SavedFile>;
  rollback(): Promise<void>;
}

export interface Storage {
  create(spec: FileSpec): Promise<Target>;
}

export interface Digest {
  update(bytes: Uint8Array): void;
  finish(): string;
}

export interface Crypto {
  randomId(): string;
  sha256(): Digest;
}

export class TransferError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status: number = 400) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

export class Item {
  state: FileState = FileState.Pending;
  bytes = 0;
  error?: string;
  savedName?: string;
  saved?: SavedFile;
  readonly spec: FileSpec;

  constructor(spec: FileSpec) {
    this.spec = spec;
  }

  receipt(): Receipt {
    const result: Receipt = { id: this.spec.id, state: this.state, bytes: this.bytes };
    if (this.error !== undefined) result.error = this.error;
    if (this.savedName !== undefined) result.name = this.savedName;
    return result;
  }
}

export function active(state: SessionState): boolean {
  return state === SessionState.Waiting || state === SessionState.Accepted;
}

export function validState(state: SessionState): boolean {
  return active(state) || state === SessionState.Declined || state === SessionState.Canceled ||
    state === SessionState.Expired || state === SessionState.Completed || state === SessionState.Partial ||
    state === SessionState.Failed;
}

export function resultState(files: Item[]): SessionState {
  const saved = files.filter(file => file.state === FileState.Committed).length;
  if (saved === files.length) return SessionState.Completed;
  return saved === 0 ? SessionState.Failed : SessionState.Partial;
}

export function isId(value: string | undefined): boolean {
  return typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
}

export function isDigest(value: string | undefined): boolean {
  return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
}

export function isPort(value: number | undefined): boolean {
  return typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 65535;
}

export function isSize(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

export function validateManifest(files: FileSpec[], codec: Codec): void {
  if (!Array.isArray(files) || files.length === 0 || files.length > MAX_FILES) {
    throw new TransferError('invalid_manifest');
  }
  const ids = new Set<string>();
  let total = 0;
  for (const file of files) {
    if (!file || !isId(file.id) || ids.has(file.id) || typeof file.name !== 'string' ||
      !file.name.trim() || codec.encode(file.name).length > 1024 || !isSize(file.size)) {
      throw new TransferError('invalid_manifest');
    }
    total += file.size;
    if (!Number.isSafeInteger(total)) throw new TransferError('invalid_manifest');
    ids.add(file.id);
  }
}

export function validReceipt(receipt: Receipt, spec: FileSpec): boolean {
  return !!receipt && receipt.id === spec.id &&
    (receipt.state === FileState.Pending || receipt.state === FileState.Uploading ||
      receipt.state === FileState.Committed || receipt.state === FileState.Failed) &&
    isSize(receipt.bytes) && receipt.bytes <= spec.size &&
    (receipt.error === undefined || typeof receipt.error === 'string') &&
    (receipt.state !== FileState.Committed ||
      (receipt.bytes === spec.size && typeof receipt.name === 'string' && receipt.name.length > 0));
}

function ipv4Number(address: string): number {
  if (!/^([0-9]{1,3}\.){3}[0-9]{1,3}$/.test(address)) return -1;
  let value = 0;
  for (const part of address.split('.')) {
    const octet = Number(part);
    if (octet > 255 || String(octet) !== part) return -1;
    value = value * 256 + octet;
  }
  return value;
}

export function onSubnet(address: string, local: string, prefix: number): boolean {
  const peer = ipv4Number(address);
  const host = ipv4Number(local);
  const first = peer >>> 24;
  if (peer < 0 || host < 0 || first === 0 || first === 127 || first >= 224 ||
    !Number.isInteger(prefix) || prefix < 1 || prefix > 32) return false;
  const shift = 32 - prefix;
  return (peer >>> shift) === (host >>> shift);
}

export function checkPin(expected: string, actual: string): void {
  if (!isDigest(expected) || actual !== expected) throw new TransferError('certificate_changed', 403);
}

export function safeName(input: string, codec: Codec): string {
  let name = input.replace(/[<>:"/\\|?*\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, '_')
    .trim().replace(/[. ]+$/, '');
  if (!name) name = '文件';
  if (/^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]) *(\.|$)/i.test(name)) name = '_' + name;
  const dot = name.lastIndexOf('.');
  const extension = dot > 0 && codec.encode(name.slice(dot)).length <= 30 ? name.slice(dot) : '';
  const stem = name.slice(0, name.length - extension.length);
  let result = '';
  let length = codec.encode(extension).length;
  for (const character of stem) {
    length += codec.encode(character).length;
    if (length > 220) break;
    result += character;
  }
  return result + extension;
}

export function numberedName(name: string, number: number): string {
  if (number === 0) return name;
  const dot = name.lastIndexOf('.');
  const suffix = ' (' + number + ')';
  return dot > 0 ? name.slice(0, dot) + suffix + name.slice(dot) : name + suffix;
}

export class Cancellation {
  private listeners = new Set<() => void>();
  private reason = '';

  get canceled(): boolean {
    return this.reason !== '';
  }

  get code(): string {
    return this.reason;
  }

  cancel(reason: string = 'canceled'): void {
    if (this.canceled) return;
    this.reason = reason;
    for (const listener of this.listeners) listener();
    this.listeners.clear();
  }

  check(): void {
    if (this.canceled) throw new TransferError(this.reason, 409);
  }

  watch(listener: () => void): () => void {
    if (this.canceled) listener();
    else this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }
}

export async function withTimeout<T>(operation: Promise<T>, ms: number = IO_TIMEOUT): Promise<T> {
  let timer = -1;
  try {
    const timeout = new Promise<T>((_, reject) => {
      timer = setTimeout(() => reject(new TransferError('timeout', 408)), Math.max(0, ms));
    });
    return await Promise.race([operation, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

export async function consume(
  source: Source, stop: Cancellation, write: (bytes: Uint8Array) => Promise<void>
): Promise<void> {
  stop.check();
  const reader = await source.open();
  try {
    let count = 0;
    for (;;) {
      stop.check();
      const bytes = await reader.read(CHUNK_SIZE);
      stop.check();
      if (bytes.length === 0) break;
      count += bytes.length;
      if (count > source.spec.size) throw new TransferError('source_changed');
      await write(bytes);
    }
    if (count !== source.spec.size) throw new TransferError('source_changed');
  } finally {
    await reader.close().catch(() => {});
  }
}
