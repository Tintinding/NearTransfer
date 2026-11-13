import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { certificateBody, hex, signedCertificate } from '../core/Certificate';
import { Codec, Crypto, Digest, TransferError } from '../core/Protocol';

class Utf8 implements Codec {
  private encoder = new util.TextEncoder();
  private decoder = util.TextDecoder.create('utf-8', { fatal: true });

  encode(text: string): Uint8Array {
    return this.encoder.encodeInto(text);
  }

  decode(bytes: Uint8Array): string {
    try {
      return this.decoder.decodeToString(bytes);
    } catch (_) {
      throw new TransferError('invalid_json');
    }
  }
}

export const utf8: Codec = new Utf8();
const base64 = new util.Base64Helper();

class Sha256 implements Digest {
  private hash = cryptoFramework.createMd('SHA256');

  update(bytes: Uint8Array): void {
    if (bytes.length > 0) this.hash.updateSync({ data: bytes });
  }

  finish(): string {
    return hex(this.hash.digestSync().data);
  }
}

class SecureRandom implements Crypto {
  private random = cryptoFramework.createRandom();

  randomId(): string {
    return hex(this.bytes());
  }

  bytes(): Uint8Array {
    return this.random.generateRandomSync(16).data;
  }

  sha256(): Digest {
    return new Sha256();
  }
}

const crypto = new SecureRandom();
export const deviceCrypto: Crypto = crypto;

export function fingerprint(der: Uint8Array): string {
  const hash = deviceCrypto.sha256();
  hash.update(der);
  return hash.finish();
}

function pem(label: string, bytes: Uint8Array): string {
  const text = base64.encodeToStringSync(bytes);
  const lines = text.match(/.{1,64}/g);
  return '-----BEGIN ' + label + '-----\n' + (lines ?? []).join('\n') + '\n-----END ' + label + '-----\n';
}

export function certificateDer(text: string): Uint8Array {
  const match = /^-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----\s*$/.exec(text);
  if (!match) throw new TransferError('tls_failed');
  return base64.decodeSync(match[1].replace(/\s/g, ''));
}

interface IdentityData {
  cert: string;
  key: string;
}

export class Identity {
  readonly cert: string;
  readonly key: string;
  readonly id: string;

  constructor(data: IdentityData) {
    this.cert = data.cert;
    this.key = data.key;
    this.id = fingerprint(certificateDer(data.cert));
  }

  static async load(directory: string): Promise<Identity> {
    const path = directory + '/neartransfer-identity.json';
    if (await fs.access(path)) {
      const data = JSON.parse(await fs.readText(path)) as IdentityData;
      if (!data || typeof data.cert !== 'string' || typeof data.key !== 'string') {
        throw new TransferError('identity_failed');
      }
      return new Identity(data);
    }
    const data = await Identity.generate();
    const staging = path + '.tmp';
    const file = await fs.open(staging, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const bytes = utf8.encode(JSON.stringify(data));
      if (await fs.write(file.fd, bytes.buffer) !== bytes.length) throw new TransferError('identity_failed');
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
    await fs.rename(staging, path);
    return new Identity(data);
  }

  private static async generate(): Promise<IdentityData> {
    const keyPair = await cryptoFramework.createAsyKeyGenerator('ECC256').generateKeyPair();
    try {
      const day = 24 * 60 * 60 * 1000;
      const now = Date.now();
      const publicKey = keyPair.pubKey.getEncodedDer('X509|UNCOMPRESSED').data;
      const body = certificateBody(publicKey, crypto.bytes(), new Date(now - day), new Date(now + 3650 * day));
      const signer = cryptoFramework.createSign('ECC256|SHA256');
      await signer.init(keyPair.priKey);
      const signature = await signer.sign({ data: body });
      return {
        cert: pem('CERTIFICATE', signedCertificate(body, signature.data)),
        key: pem('PRIVATE KEY', keyPair.priKey.getEncodedDer('PKCS8').data)
      };
    } finally {
      keyPair.priKey.clearMem();
    }
  }
}
