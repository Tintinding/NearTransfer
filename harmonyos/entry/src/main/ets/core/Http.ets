import { concat } from './Certificate';
import {
  Cancellation, CHUNK_SIZE, consume, CONTROL_LIMIT, IO_TIMEOUT, isSize, TransferError, withTimeout
} from './Protocol';
import type { Codec, Peer, Source } from './Protocol';

const HEAD_LIMIT = 16 * 1024;
// The socket API delivers events. Bound the queue even when storage stalls.
const FILE_BUFFER_LIMIT = 8 * 1024 * 1024;

export class ByteQueue {
  private chunks: Uint8Array[] = [];
  private offset = 0;
  private available = 0;
  private bufferLimit = 512 * 1024;
  private eof = false;
  private error?: TransferError;
  private wake?: () => void;

  get buffered(): number {
    return this.available;
  }

  allowFile(): void {
    this.bufferLimit = FILE_BUFFER_LIMIT;
  }

  push(bytes: Uint8Array): boolean {
    if (this.eof || this.error) return false;
    if (this.available + bytes.length > this.bufferLimit) {
      this.abort(new TransferError('interrupted'));
      return false;
    }
    if (bytes.length > 0) {
      this.chunks.push(bytes);
      this.available += bytes.length;
      this.wake?.();
    }
    return true;
  }

  end(): void {
    this.eof = true;
    this.wake?.();
  }

  abort(error: TransferError): void {
    this.error = error;
    this.chunks = [];
    this.available = 0;
    this.wake?.();
  }

  private async wait(minimum: number, deadline: number): Promise<void> {
    while (this.available < minimum && !this.eof && !this.error) {
      if (Date.now() >= deadline) throw new TransferError('timeout', 408);
      try {
        await withTimeout(new Promise<void>(resolve => { this.wake = resolve; }), deadline - Date.now());
      } finally {
        this.wake = undefined;
      }
    }
    if (this.error) throw this.error;
  }

  private discard(length: number): void {
    this.available -= length;
    this.offset += length;
    if (this.offset === this.chunks[0].length) {
      this.chunks.shift();
      this.offset = 0;
    }
  }

  private take(length: number): Uint8Array {
    if (length === 0) return new Uint8Array(0);
    const first = this.chunks[0];
    if (first.length - this.offset >= length) {
      const data = first.subarray(this.offset, this.offset + length);
      this.discard(length);
      return data;
    }
    const result = new Uint8Array(length);
    let copied = 0;
    while (copied < length) {
      const chunk = this.chunks[0];
      const count = Math.min(chunk.length - this.offset, length - copied);
      result.set(chunk.subarray(this.offset, this.offset + count), copied);
      this.discard(count);
      copied += count;
    }
    return result;
  }

  async exact(length: number, deadline: number): Promise<Uint8Array> {
    await this.wait(length, deadline);
    if (this.available < length) throw new TransferError('interrupted', 408);
    return this.take(length);
  }

  async some(limit: number, deadline: number): Promise<Uint8Array> {
    await this.wait(1, deadline);
    return this.take(Math.min(limit, this.available));
  }

  async line(limit: number, deadline: number): Promise<string> {
    let line = '';
    while (line.length < limit) {
      if (this.available === 0 || this.error) await this.wait(1, deadline);
      if (this.available === 0) throw new TransferError('interrupted', 408);
      const byte = this.chunks[0][this.offset];
      this.discard(1);
      if (byte === 10) {
        if (!line.endsWith('\r')) throw new TransferError('invalid_http');
        return line.slice(0, -1);
      }
      if (byte > 126 || (byte < 32 && byte !== 9 && byte !== 13)) {
        throw new TransferError('invalid_http');
      }
      line += String.fromCharCode(byte);
    }
    throw new TransferError('control_too_large', 413);
  }
}

export interface Channel {
  input: ByteQueue;
  send(bytes: Uint8Array): Promise<void>;
  close(): void;
}

export interface Request {
  method: string;
  path: string;
  headers: Map<string, string>;
  input: ByteQueue;
}

interface Head {
  line: string;
  headers: Map<string, string>;
}

async function readHead(input: ByteQueue): Promise<Head> {
  const deadline = Date.now() + IO_TIMEOUT;
  const line = await input.line(HEAD_LIMIT, deadline);
  let remaining = HEAD_LIMIT - line.length - 2;
  const headers = new Map<string, string>();
  while (remaining > 0) {
    const field = await input.line(remaining, deadline);
    remaining -= field.length + 2;
    if (field === '') return { line: line, headers: headers };
    const match = /^([!#$%&'*+.^_\x60|~0-9A-Za-z-]+):([\t -~]*)$/.exec(field);
    if (!match) throw new TransferError('invalid_http');
    const name = match[1].toLowerCase();
    if (headers.has(name)) {
      if (name === 'content-length' || name === 'transfer-encoding' ||
        name === 'authorization' || name === 'x-content-sha256') {
        throw new TransferError('invalid_http');
      }
      headers.set(name, headers.get(name) + ', ' + match[2].trim());
    } else {
      headers.set(name, match[2].trim());
    }
  }
  throw new TransferError('control_too_large', 413);
}

export async function readRequest(input: ByteQueue): Promise<Request> {
  const head = await readHead(input);
  const match = /^(GET|POST|PUT) (\/[a-z0-9/-]+) HTTP\/1\.[01]$/.exec(head.line);
  if (!match) throw new TransferError('not_found', 404);
  if (head.headers.has('transfer-encoding') || head.headers.has('content-encoding')) {
    throw new TransferError('invalid_file_headers');
  }
  return { method: match[1], path: match[2], headers: head.headers, input: input };
}

export function contentLength(headers: Map<string, string>): number | undefined {
  const raw = headers.get('content-length');
  if (raw === undefined) return undefined;
  const size = Number(raw);
  if (!/^[0-9]+$/.test(raw) || !isSize(size)) throw new TransferError('invalid_http');
  return size;
}

export async function controlBody(request: Request, codec: Codec): Promise<string> {
  const size = contentLength(request.headers) ?? 0;
  if (size > CONTROL_LIMIT) throw new TransferError('control_too_large', 413);
  return codec.decode(await request.input.exact(size, Date.now() + IO_TIMEOUT));
}

async function responseBody(channel: Channel, codec: Codec): Promise<string> {
  const head = await readHead(channel.input);
  const match = /^HTTP\/1\.[01] ([2-5][0-9]{2})( .*)?$/.exec(head.line);
  if (!match || head.headers.has('content-encoding')) throw new TransferError('invalid_status');
  const status = Number(match[1]);
  const length = contentLength(head.headers);
  const encoding = head.headers.get('transfer-encoding');
  const deadline = Date.now() + IO_TIMEOUT;
  let data: Uint8Array;
  if (encoding !== undefined) {
    if (encoding.toLowerCase() !== 'chunked' || length !== undefined) throw new TransferError('invalid_http');
    data = await chunkedBody(channel.input, deadline);
  } else if (length !== undefined) {
    if (length > CONTROL_LIMIT) throw new TransferError('control_too_large', 413);
    data = await channel.input.exact(length, deadline);
  } else {
    const chunks: Uint8Array[] = [];
    let count = 0;
    for (;;) {
      const bytes = await channel.input.some(CHUNK_SIZE, deadline);
      if (!bytes.length) break;
      count += bytes.length;
      if (count > CONTROL_LIMIT) throw new TransferError('control_too_large', 413);
      chunks.push(bytes);
    }
    data = concat(chunks);
  }
  const text = codec.decode(data);
  if (status >= 300) {
    let code = 'peer_error';
    if (status < 400) throw new TransferError(code, status);
    try {
      const body = JSON.parse(text) as ErrorBody;
      if (body && typeof body.error === 'string' && /^[a-z_]{1,50}$/.test(body.error)) code = body.error;
    } catch (_) {}
    throw new TransferError(code, status);
  }
  return text;
}

interface ErrorBody {
  error: string;
}

async function chunkedBody(input: ByteQueue, deadline: number): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const line = await input.line(256, deadline);
    const hex = line.split(';')[0];
    if (!/^[a-fA-F0-9]{1,8}$/.test(hex)) throw new TransferError('invalid_http');
    const length = Number.parseInt(hex, 16);
    if (length === 0) break;
    total += length;
    if (total > CONTROL_LIMIT) throw new TransferError('control_too_large', 413);
    chunks.push(await input.exact(length, deadline));
    if (await input.line(4, deadline) !== '') throw new TransferError('invalid_http');
  }
  let left = HEAD_LIMIT;
  for (;;) {
    const trailer = await input.line(left, deadline);
    if (trailer === '') break;
    left -= trailer.length + 2;
  }
  return concat(chunks);
}

export async function sendResponse(channel: Channel, status: number, body: string, codec: Codec): Promise<void> {
  const bytes = codec.encode(body);
  const head = 'HTTP/1.1 ' + status + (status === 200 ? ' OK' : ' Error') +
    '\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ' + bytes.length +
    '\r\nConnection: close\r\n\r\n';
  await withTimeout(channel.send(concat([codec.encode(head), bytes])));
}

export type Dial = (peer: Peer, stop: Cancellation) => Promise<Channel>;

export interface Upload {
  path: string;
  token: string;
  source: Source;
  digest: string;
  started: () => void;
  progress: (bytes: number) => void;
}

export class HttpClient {
  private codec: Codec;
  private dial: Dial;

  constructor(codec: Codec, dial: Dial) {
    this.codec = codec;
    this.dial = dial;
  }

  async control(peer: Peer, method: string, path: string, body: string = '',
    stop: Cancellation = new Cancellation()): Promise<string> {
    const bytes = this.codec.encode(body);
    if (bytes.length > CONTROL_LIMIT) throw new TransferError('control_too_large', 413);
    const channel = await this.dial(peer, stop);
    const unwatch = stop.watch(() => channel.close());
    try {
      stop.check();
      await this.sendHead(channel, peer, method, path, bytes.length,
        body ? 'Content-Type: application/json; charset=utf-8\r\n' : '');
      if (bytes.length) await withTimeout(channel.send(bytes));
      return await responseBody(channel, this.codec);
    } finally {
      unwatch();
      channel.close();
    }
  }

  async upload(peer: Peer, transfer: Upload, stop: Cancellation): Promise<string> {
    const channel = await this.dial(peer, stop);
    const unwatch = stop.watch(() => channel.close());
    try {
      stop.check();
      transfer.started();
      let count = 0;
      try {
        await this.sendHead(channel, peer, 'PUT', transfer.path, transfer.source.spec.size,
          'Content-Type: application/octet-stream\r\nAuthorization: Bearer ' + transfer.token +
          '\r\nX-Content-SHA256: ' + transfer.digest + '\r\n');
        await consume(transfer.source, stop, async (bytes: Uint8Array) => {
          await withTimeout(channel.send(bytes));
          count += bytes.length;
          transfer.progress(count);
        });
      } catch (error) {
        stop.check();
        // A disk error or duplicate receipt can arrive while the PUT is still sending.
        if (channel.input.buffered === 0) {
          throw error instanceof Error ? error : new TransferError('interrupted');
        }
      }
      return await responseBody(channel, this.codec);
    } finally {
      unwatch();
      channel.close();
    }
  }

  private async sendHead(channel: Channel, peer: Peer, method: string, path: string,
    length: number, headers: string): Promise<void> {
    await withTimeout(channel.send(this.codec.encode(method + ' ' + path + ' HTTP/1.1\r\nHost: ' +
      peer.address + ':' + peer.port + '\r\nContent-Length: ' + length +
      '\r\nConnection: close\r\n' + headers + '\r\n')));
  }
}
