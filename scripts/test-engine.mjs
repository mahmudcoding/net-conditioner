// Engine checks that never touch pf, dnctl, sudo, or the network: bash syntax,
// dry-run command plans, and input validation.
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const projectRoot = fileURLToPath(new URL('..', import.meta.url))
const engine = join(projectRoot, 'netcond')
const home = mkdtempSync(join(tmpdir(), 'netcond-test-'))
process.on('exit', () => rmSync(home, { recursive: true, force: true }))

let failures = 0
const check = (label, ok, detail = '') => {
  if (ok) {
    console.log(`  ok  ${label}`)
  } else {
    failures += 1
    console.error(`FAIL  ${label}${detail ? `\n      ${detail}` : ''}`)
  }
}

const run = (...args) => {
  const result = spawnSync('bash', [engine, ...args], {
    encoding: 'utf8',
    env: { ...process.env, HOME: home },
    timeout: 30_000,
  })
  return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '' }
}

console.log('bash syntax')
execFileSync('bash', ['-n', engine])
check('bash -n netcond', true)

console.log('dry-run: preset 2mbit')
{
  const r = run('preset', '2mbit', '--dry-run')
  check('exits 0', r.status === 0, r.stderr)
  const out = r.stdout
  check('download pipe', out.includes('pipe 9101 config bw 2000000bit/s delay 0 plr 0.00000 queue'))
  check('upload pipe', out.includes('pipe 9102 config bw 2000000bit/s delay 0 plr 0.00000 queue'))
  check('anchor hooks appended to pf.conf payload',
    out.includes('dummynet-anchor "netcond"') && out.includes('anchor "netcond"'))
  check('inbound rule excludes loopback',
    out.includes('dummynet in quick on ! lo0 from any to any pipe 9101'))
  check('outbound rule excludes loopback',
    out.includes('dummynet out quick on ! lo0 from any to any pipe 9102'))
  check('pf enable reference', out.includes('-E'))
  check('announces dry run', out.includes('dry run — nothing was changed'))
  check('no state written', !existsSync(join(home, '.netcond')))
}

console.log('dry-run: loss-only shaping')
{
  const r = run('set', '--loss', '8', '--dry-run')
  check('exits 0', r.status === 0, r.stderr)
  check('both pipes uncapped with 8% loss',
    r.stdout.includes('pipe 9101 config bw 0bit/s delay 0 plr 0.08000') &&
    r.stdout.includes('pipe 9102 config bw 0bit/s delay 0 plr 0.08000'))
  check('no queue sizing when uncapped',
    !r.stdout.split('\n').some((line) => line.includes('dnctl') && line.includes('queue')))
}

console.log('dry-run: directional loss')
{
  const r = run('set', '--loss-up', '8', '--dry-run')
  check('upload direction only',
    r.stdout.includes('pipe 9102 config bw 0bit/s delay 0 plr 0.08000') &&
    r.stdout.includes('pipe 9101 config bw 0bit/s delay 0 plr 0.00000'))
}

console.log('dry-run: scoped custom shape')
{
  const r = run('set', '--down', '1mbit', '--rtt', '300', '--host', '1.1.1.1', '--dry-run')
  check('exits 0', r.status === 0, r.stderr)
  check('scope table', r.stdout.includes('table <netcond_targets> persist { 1.1.1.1 }'))
  check('scoped inbound rule',
    r.stdout.includes('dummynet in quick on ! lo0 from <netcond_targets> to any pipe 9101'))
  check('scoped outbound rule',
    r.stdout.includes('dummynet out quick on ! lo0 from any to <netcond_targets> pipe 9102'))
  check('rtt split across directions',
    r.stdout.includes('pipe 9101 config bw 1000000bit/s delay 150') &&
    r.stdout.includes('pipe 9102 config bw 0bit/s delay 150'))
  check('queue sized only for the capped pipe', (() => {
    const dn = r.stdout.split('\n').filter((line) => line.includes('config bw'))
    return dn.length === 2 &&
      dn.find((l) => l.includes('9101')).includes('queue') &&
      !dn.find((l) => l.includes('9102')).includes('queue')
  })())
}

console.log('dry-run: fractional rate')
{
  const r = run('set', '--down', '2.5mbit', '--dry-run')
  check('2.5mbit parses to 2500000bit/s', r.stdout.includes('bw 2500000bit/s'))
}

console.log('dry-run: preset 250kbit')
{
  const r = run('preset', '250kbit', '--dry-run')
  check('caps both directions at 250 kbit', (() => {
    const dn = r.stdout.split('\n').filter((line) => line.includes('config bw'))
    return dn.length === 2 && dn.every((line) => line.includes('bw 250000bit/s'))
  })())
}

console.log('dry-run: off')
{
  const r = run('off', '--dry-run')
  check('exits 0', r.status === 0, r.stderr)
  check('flushes only our anchor', r.stdout.includes('-a netcond -F all'))
  check('restores stock ruleset', r.stdout.includes('-f /etc/pf.conf'))
  check('deletes only our pipes',
    r.stdout.includes('pipe delete 9101') && r.stdout.includes('pipe delete 9102'))
  check('never flushes all dummynet pipes',
    !r.stdout.split('\n').some((line) => line.includes('dnctl') && / flush/.test(line)))
  check('notes the missing token', r.stdout.includes('no pf reference token'))
}

console.log('validation')
{
  check('set with no flags fails', (() => {
    const r = run('set', '--dry-run')
    return r.status !== 0 && r.stderr.includes('nothing to shape')
  })())
  check('non-rate preset fails', (() => {
    const r = run('preset', 'nope', '--dry-run')
    return r.status !== 0 && r.stderr.includes('invalid rate')
  })())
  check('preset without a speed fails', (() => {
    const r = run('preset')
    return r.status !== 0 && r.stderr.includes('requires a speed')
  })())
  check('bad rate unit fails', (() => {
    const r = run('set', '--down', '1MB', '--dry-run')
    return r.status !== 0 && r.stderr.includes('invalid rate')
  })())
  check('loss above 100 fails', (() => {
    const r = run('set', '--loss', '150', '--dry-run')
    return r.status !== 0 && r.stderr.includes('out of range')
  })())
  check('unknown option fails', (() => {
    const r = run('set', '--loss', '5', '--bogus', '--dry-run')
    return r.status !== 0 && r.stderr.includes('unknown option')
  })())
  check('missing value fails', (() => {
    const r = run('set', '--down', '--dry-run')
    return r.status !== 0 && r.stderr.includes('requires a value')
  })())
  check('tiny probe count fails', (() => {
    const r = run('verify', '--probes', '2')
    return r.status !== 0 && r.stderr.includes('at least 5')
  })())
  check('unknown command fails', (() => {
    const r = run('conditionify')
    return r.status !== 0 && r.stderr.includes('unknown command')
  })())
}

console.log('status without state')
{
  const r = run('status', '--porcelain')
  check('porcelain reports off', r.status === 0 && r.stdout.trim() === 'ACTIVE=0')
}

console.log('usage')
{
  const r = run('--help')
  check('help lists every command', r.status === 0 &&
    ['preset', 'set', 'status', 'off', 'verify'].every((c) => r.stdout.includes(`netcond ${c}`)))
  const bare = run()
  check('no arguments prints usage and fails', bare.status !== 0 && bare.stderr.includes('Usage:'))
}

if (failures > 0) {
  console.error(`\n${failures} check(s) failed`)
  process.exit(1)
}
console.log('\nall engine checks passed')
