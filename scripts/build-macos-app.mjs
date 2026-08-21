// Builds dist/Net Conditioner.app — the menu-bar wrapper around the netcond
// engine. macOS-only build (uses swiftc, sips, iconutil, codesign, ditto).
import { execFileSync } from 'node:child_process'
import {
  chmodSync, cpSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync,
} from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { prepareSparkle } from './sparkle.mjs'
import { UPDATE } from './update-config.mjs'

const APP_NAME = 'Net Conditioner'
const EXECUTABLE = 'NetConditioner'

if (process.platform !== 'darwin') {
  console.error('the .app can only be built on macOS')
  process.exit(1)
}

const projectRoot = fileURLToPath(new URL('..', import.meta.url))
const { version } = (
  await import(`file://${projectRoot}package.json`, { with: { type: 'json' } })
).default

const arch = process.arch === 'arm64' ? 'arm64' : 'x64'
const dist = join(projectRoot, 'dist')
const appRoot = join(dist, `${APP_NAME}.app`)
const contents = join(appRoot, 'Contents')
const resources = join(contents, 'Resources')
const frameworks = join(contents, 'Frameworks')
const cacheDir = join(projectRoot, '.data', 'build-cache')

const run = (cmd, args) => execFileSync(cmd, args, { stdio: 'pipe' })
const step = (label) => console.log(`• ${label}`)

step('creating bundle skeleton')
rmSync(appRoot, { recursive: true, force: true })
mkdirSync(join(contents, 'MacOS'), { recursive: true })
mkdirSync(resources, { recursive: true })
mkdirSync(frameworks, { recursive: true })
mkdirSync(cacheDir, { recursive: true })

const sparkle = await prepareSparkle(cacheDir, step)
step('embedding Sparkle.framework')
run('ditto', [sparkle.framework, join(frameworks, 'Sparkle.framework')])

step('writing Info.plist')
writeFileSync(
  join(contents, 'Info.plist'),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${UPDATE.bundleId}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>${UPDATE.feedUrl}</string>
  <key>SUPublicEDKey</key><string>${UPDATE.publicEdKey}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>${UPDATE.scheduledCheckInterval}</integer>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
</dict>
</plist>
`,
)

step('compiling the app (swiftc)')
const sources = readdirSync(join(projectRoot, 'app'))
  .filter((name) => name.endsWith('.swift'))
  .sort()
  .map((name) => join(projectRoot, 'app', name))
run('swiftc', [
  '-O',
  '-parse-as-library',
  '-target', `${arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macos13.0`,
  '-F', sparkle.root,
  '-framework', 'Sparkle',
  '-Xlinker', '-rpath',
  '-Xlinker', '@executable_path/../Frameworks',
  '-o', join(contents, 'MacOS', EXECUTABLE),
  ...sources,
])

step('bundling the netcond engine')
cpSync(join(projectRoot, 'netcond'), join(resources, 'netcond'))
chmodSync(join(resources, 'netcond'), 0o755)

step('rendering icon')
const iconPng = join(cacheDir, 'icon-1024.png')
run('swift', [join(projectRoot, 'scripts', 'render-icon.swift'), iconPng])
const iconset = join(cacheDir, 'AppIcon.iconset')
rmSync(iconset, { recursive: true, force: true })
mkdirSync(iconset)
for (const [size, name] of [
  [16, 'icon_16x16.png'], [32, 'icon_16x16@2x.png'], [32, 'icon_32x32.png'],
  [64, 'icon_32x32@2x.png'], [128, 'icon_128x128.png'], [256, 'icon_128x128@2x.png'],
  [256, 'icon_256x256.png'], [512, 'icon_256x256@2x.png'], [512, 'icon_512x512.png'],
  [1024, 'icon_512x512@2x.png'],
]) {
  run('sips', ['-z', String(size), String(size), iconPng, '--out', join(iconset, name)])
}
run('iconutil', ['-c', 'icns', iconset, '-o', join(resources, 'AppIcon.icns')])

step('ad-hoc code signing')
// Sparkle ships with valid nested signatures. Preserve them and sign only our
// outer bundle; --deep signing here would rewrite Sparkle's own helpers.
run('codesign', ['--verify', '--deep', '--strict', join(frameworks, 'Sparkle.framework')])
run('codesign', ['--force', '--sign', '-', appRoot])
run('codesign', ['--verify', '--deep', '--strict', appRoot])

step('zipping')
const zipPath = join(dist, `Net-Conditioner-${version}-macOS-${arch}.zip`)
rmSync(zipPath, { force: true })
run('ditto', ['-c', '-k', '--keepParent', appRoot, zipPath])

const sizeMb = (bytes) => `${(bytes / 1024 / 1024).toFixed(1)} MB`
console.log(`\nbuilt: ${appRoot}`)
console.log(`zip:   ${zipPath} (${sizeMb(statSync(zipPath).size)})`)
console.log('\nnote: ad-hoc signed. Recipients of the zip must right-click → Open on first launch')
console.log(`(or: xattr -dr com.apple.quarantine "/Applications/${APP_NAME}.app")`)
