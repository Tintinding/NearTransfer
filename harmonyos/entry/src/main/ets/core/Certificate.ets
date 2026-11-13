// X.509 DER framing. Key generation, signing and hashing are provided by the platform.
export function concat(chunks: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(chunks.reduce((length, chunk) => length + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

function der(tag: number, chunks: Uint8Array[]): Uint8Array {
  const content = concat(chunks);
  const length = content.length;
  if (length < 128) return concat([new Uint8Array([tag, length]), content]);
  if (length <= 255) return concat([new Uint8Array([tag, 0x81, length]), content]);
  return concat([new Uint8Array([tag, 0x82, length >>> 8, length & 255]), content]);
}

const ECDSA_SHA256 = new Uint8Array([0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]);

function utcTime(time: Date): Uint8Array {
  // UTCTime covers 1950–2049. GeneralizedTime covers later years.
  const year = time.getUTCFullYear();
  const utc = year >= 1950 && year < 2050;
  const stamp = time.toISOString().slice(utc ? 2 : 0, 19).replace(/[-T:]/g, '') + 'Z';
  const bytes = new Uint8Array(stamp.length);
  for (let i = 0; i < stamp.length; i++) bytes[i] = stamp.charCodeAt(i);
  return der(utc ? 0x17 : 0x18, [bytes]);
}

export function certificateBody(
  spki: Uint8Array, randomSerial: Uint8Array, from: Date, until: Date
): Uint8Array {
  const serial = randomSerial.slice();
  serial[0] = (serial[0] & 0x7f) | 0x01;
  const version = new Uint8Array([0xa0, 0x03, 0x02, 0x01, 0x02]);
  const commonNameOid = new Uint8Array([0x06, 0x03, 0x55, 0x04, 0x03]);
  const commonName = new Uint8Array([78, 101, 97, 114, 32, 84, 114, 97, 110, 115, 102, 101, 114]);
  const name = der(0x30, [der(0x31, [der(0x30, [commonNameOid, der(0x0c, [commonName])])])]);
  const validity = der(0x30, [utcTime(from), utcTime(until)]);
  return der(0x30, [version, der(0x02, [serial]), ECDSA_SHA256, name, validity, name, spki]);
}

export function signedCertificate(body: Uint8Array, signature: Uint8Array): Uint8Array {
  return der(0x30, [body, ECDSA_SHA256, der(0x03, [new Uint8Array([0]), signature])]);
}

export function hex(bytes: Uint8Array): string {
  let result = '';
  for (const byte of bytes) result += byte.toString(16).padStart(2, '0');
  return result;
}
