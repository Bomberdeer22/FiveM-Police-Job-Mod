/* Exercises tools/scan-pack.js against small fixture packs built in a temp
   folder: one bad vehicle in a pack is enough to leave FiveM at 100%, and this
   is the tool that finds it.
   Run with: npm test */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const TOOL = path.join(__dirname, '..', 'tools', 'scan-pack.js');
const { scanPack, findDuplicates, parseMeta } = require(TOOL);

let pass = 0;
const failures = [];

function check(name, ok, detail) {
  if (ok) {
    pass += 1;
    return;
  }
  failures.push({ name, detail });
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fk-scan-'));

function write(relative, contents) {
  const full = path.join(root, relative);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, contents);
  return full;
}

/** A file of `bytes` bytes without writing them all. */
function writeSized(relative, bytes) {
  const full = path.join(root, relative);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, '');
  fs.truncateSync(full, bytes);
  return full;
}

const manifest = "fx_version 'cerulean'\ngame 'gta5'\n";

// --- military: the pack with the bad vehicles ------------------------------
write('military/fxmanifest.lua', manifest);
write('military/data/vehicles.meta', `<?xml version="1.0" encoding="UTF-8"?>
<CVehicleModelInfo__InitDataList>
  <InitDatas>
    <Item>
      <modelName>adder</modelName>
      <handlingId>ADDER</handlingId>
    </Item>
    <Item>
      <modelName>mrap</modelName>
      <handlingId>MRAP</handlingId>
    </Item>
    <Item>
      <modelName>tank2</modelName>
      <handlingId>TANK2</handlingId>
    </Item>
  </InitDatas>
</CVehicleModelInfo__InitDataList>
`);
write('military/data/handling.meta', `<?xml version="1.0" encoding="UTF-8"?>
<CHandlingDataMgr>
  <HandlingData>
    <Item type="CHandlingData">
      <handlingName>ADDER</handlingName>
    </Item>
    <Item type="CHandlingData">
      <handlingName>TANK2</handlingName>
    </Item>
  </HandlingData>
</CHandlingDataMgr>
`);
write('military/stream/adder.yft', 'not really a model');
write('military/stream/tank2.yft', 'not really a model');
write('military/stream/leftover.yft', 'not really a model'); // orphan
write('military/stream/adder.ytd', 'texture');
writeSized('military/stream/blank.ytd', 0); // empty
writeSized('military/stream/mrap.ytd', 17 * 1024 * 1024); // oversized

// --- second pack, same model name (the classic cross-pack duplicate) --------
write('otherpack/fxmanifest.lua', manifest);
write('otherpack/data/vehicles.meta', `<?xml version="1.0" encoding="UTF-8"?>
<CVehicleModelInfo__InitDataList>
  <InitDatas>
    <Item>
      <modelName>adder</modelName>
      <handlingId>ADDER</handlingId>
    </Item>
  </InitDatas>
</CVehicleModelInfo__InitDataList>
`);
write('otherpack/stream/adder.yft', 'duplicate');

// --- a clean pack ----------------------------------------------------------
write('cleanpack/fxmanifest.lua', manifest);
write('cleanpack/data/vehicles.meta', `<?xml version="1.0" encoding="UTF-8"?>
<CVehicleModelInfo__InitDataList>
  <InitDatas>
    <Item>
      <modelName>sultan</modelName>
      <handlingId>SULTAN</handlingId>
    </Item>
  </InitDatas>
</CVehicleModelInfo__InitDataList>
`);
write('cleanpack/data/handling.meta', `<CHandlingDataMgr>
  <HandlingData>
    <Item type="CHandlingData">
      <handlingName>SULTAN</handlingName>
    </Item>
  </HandlingData>
</CHandlingDataMgr>
`);
write('cleanpack/stream/sultan.yft', 'model');
write('cleanpack/stream/sultan_hi.yft', 'model');
write('cleanpack/stream/sultan.ytd', 'texture');

// --- a pack whose meta is cut in half --------------------------------------
write('brokenmeta/fxmanifest.lua', manifest);
write('brokenmeta/data/vehicles.meta', `<CVehicleModelInfo__InitDataList>
  <InitDatas>
    <Item>
      <modelName>ghost</modelName>
      <handlingId>GHOST</handlingId>
    </Item>
    <Item>
      <modelName>phantom
`);
write('brokenmeta/stream/ghost.yft', 'model');

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------

const military = scanPack(path.join(root, 'military'));
const codes = (pack) => pack.findings.map((finding) => finding.code);
const messages = (pack) => pack.findings.map((finding) => finding.message).join('\n');

check('the pack model count is right', military.models.length === 3, military.models);
check('a model with no .yft is an error',
  military.findings.some((finding) => finding.code === 'missing-file'
    && /"mrap"/.test(finding.message)), messages(military));
check('a handlingId with no handlingName is an error',
  military.findings.some((finding) => finding.code === 'missing-handling'
    && /MRAP/.test(finding.message)), messages(military));
check('a 0-byte asset is an error',
  military.findings.some((finding) => finding.code === 'empty-file'
    && /blank\.ytd/.test(finding.message)), messages(military));
check('an oversized texture is a warning',
  military.findings.some((finding) => finding.code === 'huge-texture'
    && finding.level === 'warn' && /mrap\.ytd/.test(finding.message)), messages(military));
check('a streamed model with no vehicles.meta entry is a warning',
  codes(military).includes('orphan-model'), messages(military));
check('the _hi model file is not treated as an orphan',
  !military.findings.some((finding) => /tank2_hi/.test(finding.message)));
check('the healthy vehicles in the pack are not reported',
  !military.findings.some((finding) => /"adder"|"tank2"/.test(finding.message)), messages(military));

const clean = scanPack(path.join(root, 'cleanpack'));
check('a healthy pack has no findings at all', clean.findings.length === 0, clean.findings);

const broken = scanPack(path.join(root, 'brokenmeta'));
check('an unbalanced vehicles.meta is reported',
  broken.findings.some((finding) => finding.code === 'malformed-meta'), broken.findings);

const packs = ['military', 'otherpack', 'cleanpack'].map((name) => scanPack(path.join(root, name)));
const crossFindings = findDuplicates(packs);
check('the same model in two resources is an error',
  crossFindings.some((finding) => finding.code === 'duplicate-model' && /"adder"/.test(finding.message)),
  crossFindings);
check('a model that only exists once is not reported',
  !crossFindings.some((finding) => /"sultan"/.test(finding.message)), crossFindings);

check('models are read out of vehicles.meta',
  parseMeta('<modelName>adder</modelName><handlingId>ADDER</handlingId>').models[0] === 'adder');
check('names with whitespace are trimmed',
  parseMeta('<modelName>\n  adder\n</modelName>').models[0] === 'adder');

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function run(args) {
  try {
    const stdout = execFileSync(process.execPath, [TOOL, ...args], { encoding: 'utf8' });
    return { code: 0, stdout };
  } catch (err) {
    return { code: err.status, stdout: String(err.stdout || '') };
  }
}

const jsonRun = run([path.join(root, 'military'), '--json']);
const parsed = JSON.parse(jsonRun.stdout);
check('--json prints machine-readable output', parsed && Array.isArray(parsed.findings), jsonRun.stdout.slice(0, 200));
check('a pack with errors exits non-zero', jsonRun.code === 1, jsonRun.code);
check('the JSON counts the errors', parsed.errors > 0, parsed.errors);

const cleanRun = run([path.join(root, 'cleanpack'), '--no-siblings']);
check('a clean pack exits zero', cleanRun.code === 0, cleanRun.code);
check('and says so in plain text', /no problems found/.test(cleanRun.stdout), cleanRun.stdout);

const humanRun = run([path.join(root, 'military')]);
check('the human output names the bad model', /mrap/.test(humanRun.stdout), humanRun.stdout);
check('the human output explains what to fix first', /Fix the ERROR lines first/.test(humanRun.stdout));

const noTarget = run([]);
check('a missing argument prints the usage', noTarget.code === 2 && /Usage:/.test(noTarget.stdout));

const missing = run([path.join(root, 'does-not-exist')]);
check('a missing folder is an error', missing.code === 2);

const dupOnly = run([path.join(root), '--duplicates-only', '--json']);
const dupJson = JSON.parse(dupOnly.stdout);
check('--duplicates-only still finds the cross-pack duplicate',
  dupJson.findings.some((finding) => finding.code === 'duplicate-model'), dupJson.findings);

fs.rmSync(root, { recursive: true, force: true });

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

if (failures.length) {
  console.log('');
  for (const failure of failures) {
    console.log(`FAIL  ${failure.name}`);
    if (failure.detail !== undefined) console.log(`      got: ${JSON.stringify(failure.detail)}`);
  }
}

const total = pass + failures.length;
console.log(`\n${pass}/${total} pack scan checks passed`);
process.exit(failures.length ? 1 : 0);
