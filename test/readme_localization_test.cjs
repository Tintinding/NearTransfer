const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const pages = [
  {
    file: 'README.md',
    unfinished: /尚无成品.*自行打包并验证/,
  },
  {
    file: 'docs/README.en.md',
    unfinished: /No finished app is available.*build and validate/,
  },
  {
    file: 'docs/README.ja.md',
    unfinished: /完成版はありません.*ビルドと検証が必要/,
  },
  {
    file: 'docs/README.fr.md',
    unfinished: /Aucune application finalisée.*compiler et les vérifier vous-même/,
  },
  {
    file: 'docs/README.es.md',
    unfinished: /Aún no hay una aplicación terminada.*compiles y valides por tu cuenta/,
  },
];
const pagePaths = pages.map(({ file }) => path.join(root, file)).sort();

test('every introduction links to all five languages', () => {
  for (const page of pages) {
    const file = path.join(root, page.file);
    const content = fs.readFileSync(file, 'utf8');
    const buttons = [...content.matchAll(
      /<a href="([^"]+)"><img src="([^"]+)" alt="([^"]+)"><\/a>/g,
    )];
    assert.equal(buttons.length, pages.length, page.file);
    assert.deepEqual(
      buttons.map((button) => path.resolve(path.dirname(file), button[1])).sort(),
      pagePaths,
      page.file,
    );
    assert.equal(new Set(buttons.map((button) => button[3])).size, pages.length);
  }
});

test('each introduction describes the same release and unfinished platforms', () => {
  for (const page of pages) {
    const content = fs.readFileSync(path.join(root, page.file), 'utf8');
    for (const platform of ['iOS / iPadOS', 'macOS', 'HarmonyOS NEXT']) {
      const row = content.split('\n').find((line) => line.startsWith(`| ${platform} |`));
      assert.ok(row, `${page.file} is missing ${platform}`);
      assert.match(row, page.unfinished, `${page.file}: ${platform}`);
    }
    for (const packageName of [
      'NearTransfer-Windows-x64.exe',
      'NearTransfer-Android.apk',
    ]) {
      assert.ok(
        content.includes(`/releases/download/v1.0.0-preview/${packageName}`),
        `${page.file} is missing the ${packageName} download`,
      );
    }
  }
});

test('relative files linked from the introductions exist', () => {
  for (const page of pages) {
    const file = path.join(root, page.file);
    const content = fs.readFileSync(file, 'utf8');
    const links = content.matchAll(/\]\(([^)]+)\)|(?:href|src)="([^"]+)"/g);
    for (const match of links) {
      const target = match[1] || match[2];
      if (/^(https?:|#)/.test(target)) continue;
      const filename = target.split('#')[0];
      assert.ok(
        fs.existsSync(path.resolve(path.dirname(file), decodeURI(filename))),
        `${page.file} links to missing file ${target}`,
      );
    }
  }
});
