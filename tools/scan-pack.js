#!/usr/bin/env node
/* Finds the one bad vehicle in an add-on vehicle pack.
 *
 * A single broken model is enough to leave FiveM sitting at 100% on the loading
 * screen, and the client console (F8) is not always available. Every check here
 * is a fault that is known to do exactly that:
 *
 *   missing-file        a model declared in vehicles.meta with no .yft in the pack
 *   missing-handling    a handlingId that is not defined in any handling.meta
 *   duplicate-model     the same model name (or .yft) in two resources
 *   empty-file          a 0-byte .yft/.ytd
 *   huge-texture        an oversized .ytd (stalls the client while streaming)
 *   bad-name            a model name that is not lowercase [a-z0-9_]
 *   orphan-model        a .yft with no modelName (usually a leftover)
 *   malformed-meta      <Item> tags that do not balance, or a truncated file
 *
 * Usage:
 *   node tools/scan-pack.js <path-to-resource>          # pack + its neighbours
 *   node tools/scan-pack.js <path-to-resource> --no-siblings
 *   node tools/scan-pack.js <resources-dir> --duplicates-only
 *   node tools/scan-pack.js <path> --json
 */
const fs = require('fs');
const path = require('path');

const META = /\.(meta|xml)$/i;
const MODEL = /\.(yft|ydr)$/i;
const TEXTURE = /\.ytd$/i;

const HUGE_TEXTURE_BYTES = 16 * 1024 * 1024;
const HUGE_FILE_BYTES = 32 * 1024 * 1024;
const GOOD_NAME = /^[a-z0-9_]+$/;

function walk(dir, base = dir, out = []) {
  let entries;

  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    return out;
  }

  for (const entry of entries) {
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      if (entry.name === '.git' || entry.name === 'node_modules') continue;
      walk(full, base, out);
    } else if (entry.isFile()) {
      let stat;

      try {
        stat = fs.statSync(full);
      } catch (err) {
        continue;
      }

      out.push({
        full,
        rel: path.relative(base, full).split(path.sep).join('/'),
        size: stat.size,
        base: entry.name.toLowerCase(),
      });
    }
  }

  return out;
}

function readText(file) {
  const buffer = fs.readFileSync(file);

  if (buffer.includes(0)) return null; // not text: a binary .meta is corrupt

  return buffer.toString('utf8').replace(/^\uFEFF/, '');
}

/** Collect <modelName>/<handlingId>/<handlingName> with a tolerant regex scan. */
function parseMeta(text) {
  const models = [];
  const handlingIds = [];
  const handlingNames = [];

  const collect = (re, target) => {
    let match;

    while ((match = re.exec(text)) !== null) {
      const value = match[1].trim();

      if (value) target.push(value);
    }
  };

  collect(/<modelName>\s*([^<]+?)\s*<\/modelName>/gi, models);
  collect(/<handlingId>\s*([^<]+?)\s*<\/handlingId>/gi, handlingIds);
  collect(/<handlingName>\s*([^<]+?)\s*<\/handlingName>/gi, handlingNames);

  return { models, handlingIds, handlingNames };
}

function tagBalance(text) {
  const opens = (text.match(/<Item\b/gi) || []).length;
  const closes = (text.match(/<\/Item>/gi) || []).length;

  return { opens, closes };
}

function scanPack(dir, options = {}) {
  const files = walk(dir);
  const findings = [];
  const add = (level, code, message) => findings.push({ level, code, message });

  const models = []; // { name, file }
  const handlingIds = []; // { name, file }
  const handlingNames = new Set();
  const modelFiles = new Map(); // lowercased basename -> file
  let totalBytes = 0;

  for (const file of files) {
    totalBytes += file.size;

    if (MODEL.test(file.rel)) {
      const stem = file.base.replace(MODEL, '');
      modelFiles.set(stem, file);

      if (file.size === 0) {
        add('error', 'empty-file', `${file.rel} is 0 bytes`);
      } else if (file.size > HUGE_FILE_BYTES) {
        add('warn', 'huge-texture', `${file.rel} is ${mb(file.size)} - very large for one asset`);
      }

      continue;
    }

    if (TEXTURE.test(file.rel)) {
      if (file.size === 0) {
        add('error', 'empty-file', `${file.rel} is 0 bytes`);
      } else if (file.size > HUGE_TEXTURE_BYTES) {
        add('warn', 'huge-texture', `${file.rel} is ${mb(file.size)} - clients stream this every spawn`);
      }

      continue;
    }

    if (!META.test(file.rel)) continue;

    const text = readText(file.full);

    if (text === null) {
      add('error', 'malformed-meta', `${file.rel} is not text (binary or corrupt)`);
      continue;
    }

    if (!text.trim()) {
      add('error', 'malformed-meta', `${file.rel} is empty`);
      continue;
    }

    const balance = tagBalance(text);

    if (balance.opens !== balance.closes) {
      add('error', 'malformed-meta',
        `${file.rel} has ${balance.opens} <Item> but ${balance.closes} </Item> - truncated or badly edited`);
    }

    const parsed = parseMeta(text);

    parsed.models.forEach((name) => models.push({ name, file: file.rel }));
    parsed.handlingIds.forEach((name) => handlingIds.push({ name, file: file.rel }));
    parsed.handlingNames.forEach((name) => handlingNames.add(name.toLowerCase()));
  }

  // --- per-model checks -----------------------------------------------------
  const seen = new Map();

  for (const model of models) {
    const key = model.name.toLowerCase();

    if (seen.has(key)) {
      add('error', 'duplicate-model',
        `model "${model.name}" is declared twice in this pack (${seen.get(key)} and ${model.file})`);
    } else {
      seen.set(key, model.file);
    }

    if (!GOOD_NAME.test(model.name)) {
      add('warn', 'bad-name',
        `model "${model.name}" in ${model.file} is not lowercase a-z/0-9/_ - FiveM will not load it reliably`);
    }

    const hasModel = modelFiles.has(key) || modelFiles.has(`${key}_hi`);

    if (!hasModel) {
      add('error', 'missing-file',
        `model "${model.name}" (${model.file}) has no ${model.name}.yft in this pack`);
    }
  }

  for (const id of handlingIds) {
    if (!handlingNames.has(id.name.toLowerCase())) {
      add('error', 'missing-handling',
        `handlingId "${id.name}" (${id.file}) is not defined by any <handlingName> in this pack - `
        + 'the client freezes while loading that vehicle');
    }
  }

  if (handlingNames.size === 0 && handlingIds.length > 0) {
    add('error', 'missing-handling',
      'vehicles declare handling ids but the pack has no handling.meta at all');
  }

  for (const [stem, file] of modelFiles) {
    const base = stem.replace(/_hi$/, '');

    if (!seen.has(base) && !options.quietOrphans) {
      add('warn', 'orphan-model', `${file.rel} is streamed but no <modelName> declares "${base}"`);
    }
  }

  return {
    dir,
    name: path.basename(dir),
    files: files.length,
    bytes: totalBytes,
    models: models.map((model) => model.name),
    findings,
  };
}

function mb(bytes) {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function looksLikeResource(dir) {
  try {
    return fs.existsSync(path.join(dir, 'fxmanifest.lua'))
      || fs.existsSync(path.join(dir, '__resource.lua'));
  } catch (err) {
    return false;
  }
}

/** Resources directly inside `dir` (a resources folder, or a [category] one). */
function childResources(dir) {
  let entries;

  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    return [];
  }

  const found = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    const full = path.join(dir, entry.name);

    if (looksLikeResource(full)) {
      found.push(full);
    } else if (entry.name.startsWith('[')) {
      // resources/[category]/pack
      found.push(...childResources(full));
    }
  }

  return found;
}

/** Resources in the same folder as `dir` (the usual `resources/[packs]/...`). */
function siblingResources(dir) {
  const parent = path.dirname(path.resolve(dir));
  let entries;

  try {
    entries = fs.readdirSync(parent, { withFileTypes: true });
  } catch (err) {
    return [];
  }

  const found = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    const full = path.join(parent, entry.name);
    if (full === path.resolve(dir)) continue;

    try {
      if (!fs.existsSync(path.join(full, 'fxmanifest.lua'))
        && !fs.existsSync(path.join(full, '__resource.lua'))) continue;
    } catch (err) {
      continue;
    }

    found.push(full);
  }

  return found;
}

/**
 * The same model (or the same .yft) in two resources is the classic cause of a
 * client that never finishes loading: it streams one of them and waits for the
 * other.
 */
function findDuplicates(packs) {
  const byModel = new Map();
  const byFile = new Map();
  const findings = [];

  for (const pack of packs) {
    for (const file of walk(pack.dir)) {
      if (MODEL.test(file.rel)) {
        const stem = file.base.replace(MODEL, '');
        const list = byFile.get(stem) || [];
        list.push(pack.name);
        byFile.set(stem, list);
      }
    }

    for (const name of pack.models) {
      const key = name.toLowerCase();
      const list = byModel.get(key) || [];
      list.push(pack.name);
      byModel.set(key, list);
    }
  }

  for (const [name, owners] of byModel) {
    const unique = [...new Set(owners)];

    if (unique.length > 1) {
      findings.push({
        level: 'error',
        code: 'duplicate-model',
        message: `model "${name}" is declared in ${unique.join(' and ')} - remove one of them`,
      });
    }
  }

  for (const [name, owners] of byFile) {
    const unique = [...new Set(owners)];

    if (unique.length > 1 && !byModel.has(name.replace(/_hi$/, ''))) {
      findings.push({
        level: 'error',
        code: 'duplicate-model',
        message: `${name}.yft is streamed by ${unique.join(' and ')} - the client picks one and waits for the other`,
      });
    }
  }

  return findings;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function main(argv) {
  const args = argv.slice(2);
  const target = args.find((arg) => !arg.startsWith('--'));
  const json = args.includes('--json');
  const duplicatesOnly = args.includes('--duplicates-only');
  const siblings = !args.includes('--no-siblings');

  if (!target) {
    console.log('Usage: node tools/scan-pack.js <path-to-resource-or-resources-dir> [--json]');
    console.log('       [--no-siblings] [--duplicates-only]');
    return 2;
  }

  const resolved = path.resolve(target);

  if (!fs.existsSync(resolved)) {
    console.error(`No such folder: ${resolved}`);
    return 2;
  }

  // A resources folder (it contains resources, not a fxmanifest) scans every
  // resource inside it; a single resource scans itself plus its siblings.
  const isResource = looksLikeResource(resolved);

  let packDirs;

  if (isResource) {
    packDirs = [resolved];

    if (siblings) {
      packDirs.push(...siblingResources(resolved).filter((dir) => dir !== resolved));
    }
  } else {
    packDirs = childResources(resolved);
  }
  const packs = packDirs.map((dir) => scanPack(dir, { quietOrphans: duplicatesOnly }));

  const findings = [];

  packs.forEach((pack) => {
    if (duplicatesOnly) return;
    pack.findings.forEach((finding) => findings.push({ ...finding, pack: pack.name }));
  });

  if (packs.length > 1) {
    findDuplicates(packs).forEach((finding) => findings.push(finding));
  }

  const errors = findings.filter((finding) => finding.level === 'error');
  const warnings = findings.filter((finding) => finding.level === 'warn');

  if (json) {
    console.log(JSON.stringify({
      packs: packs.map((pack) => ({
        name: pack.name,
        files: pack.files,
        bytes: pack.bytes,
        models: pack.models.length,
        findings: pack.findings,
      })),
      findings,
      errors: errors.length,
      warnings: warnings.length,
    }, null, 2));

    return errors.length ? 1 : 0;
  }

  for (const pack of packs) {
    if (duplicatesOnly) continue;

    console.log(`\n${pack.name}  (${mb(pack.bytes)}, ${pack.files} files, ${pack.models.length} models, ${path.relative(process.cwd(), pack.dir) || '.'})`);

    if (pack.findings.length === 0) {
      console.log('  ok - no problems found');
      continue;
    }

    for (const finding of pack.findings) {
      console.log(`  ${finding.level === 'error' ? 'ERROR' : 'WARN '}  ${finding.message}`);
    }
  }

  const crossPack = findings.filter((finding) => !finding.pack);

  if (crossPack.length) {
    console.log('\nAcross resources');

    for (const finding of crossPack) {
      console.log(`  ${finding.level === 'error' ? 'ERROR' : 'WARN '}  ${finding.message}`);
    }
  }

  console.log(`\n${errors.length} problem(s), ${warnings.length} warning(s).`);

  if (errors.length) {
    console.log('Fix the ERROR lines first: one bad model is enough to leave a client at 100%.');
  }

  return errors.length ? 1 : 0;
}

if (require.main === module) {
  process.exitCode = main(process.argv);
}

module.exports = {
  scanPack, findDuplicates, parseMeta, walk, siblingResources, childResources,
};
