import esbuild from 'esbuild'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import * as ResEdit from 'resedit'
import { need } from '@yao-pkg/pkg-fetch'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')
const BUILD_DIR = path.join(ROOT, 'build')
const RELEASE_DIR = path.join(ROOT, 'release')
const BUNDLE = path.join(BUILD_DIR, 'server.cjs')
const EXE_NAME = 'Toneferry.exe'
const PKG_CONFIG = path.join(BUILD_DIR, 'pkg.config.json')

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true })
}

function rmrf(target) {
  fs.rmSync(target, { recursive: true, force: true })
}

function copyDir(src, dest) {
  ensureDir(dest)
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name)
    const to = path.join(dest, entry.name)
    if (entry.isDirectory()) copyDir(from, to)
    else fs.copyFileSync(from, to)
  }
}

function mustExist(file, hint) {
  if (!fs.existsSync(file)) {
    console.error(`[error] missing ${file}`)
    if (hint) console.error(hint)
    process.exit(1)
  }
}

function tryStopRunningExe() {
  if (process.platform !== 'win32') return
  for (const name of [EXE_NAME, 'ToneferryServer.exe', 'audio-capture.exe', 'audio-play.exe']) {
    try {
      execFileSync('taskkill', ['/F', '/IM', name], { stdio: 'ignore', windowsHide: true })
    } catch {
      /* not running */
    }
  }
}

function refreshExplorerIcons() {
  if (process.platform !== 'win32') return
  try {
    execFileSync('ie4uinit.exe', ['-show'], {
      stdio: 'ignore',
      windowsHide: true,
    })
  } catch {
    /* ignore */
  }
}

/**
 * Stamp public/icon.ico onto pkg's base Node binary BEFORE packaging.
 * Replaces every icon group (Explorer uses ID 1, which is Node's default).
 */
async function stampBaseNodeIconAsync(iconPath) {
  const fetched = await need({
    nodeRange: 'node22',
    platform: 'win',
    arch: 'x64',
  })
  const stamped = path.join(BUILD_DIR, 'node-with-icon.exe')
  const exe = ResEdit.NtExecutable.from(fs.readFileSync(fetched), {
    ignoreCert: true,
  })
  const res = ResEdit.NtExecutableResource.from(exe)
  const iconFile = ResEdit.Data.IconFile.from(fs.readFileSync(iconPath))
  const icons = iconFile.icons.map((item) => item.data)

  const groups = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries)
  if (groups.length === 0) {
    ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
      res.entries,
      1,
      1033,
      icons,
    )
  } else {
    for (const group of groups) {
      ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
        res.entries,
        group.id,
        group.lang,
        icons,
      )
    }
  }

  const viList = ResEdit.Resource.VersionInfo.fromEntries(res.entries)
  if (viList[0]) {
    viList[0].setStringValues(
      { lang: 1033, codepage: 1200 },
      {
        FileDescription: 'Toneferry',
        ProductName: 'Toneferry',
        OriginalFilename: EXE_NAME,
        InternalName: 'Toneferry',
        CompanyName: 'Toneferry',
      },
    )
    viList[0].outputToResourceEntries(res.entries)
  }

  res.outputResource(exe)
  fs.writeFileSync(stamped, Buffer.from(exe.generate()))
  console.log(
    `[icon] replaced ${groups.length || 1} icon group(s) with ${path.basename(iconPath)}`,
  )
  return stamped
}

async function main() {
  const captureExe = path.join(ROOT, 'bin', 'audio-capture.exe')
  const playerExe = path.join(ROOT, 'bin', 'audio-play.exe')
  mustExist(captureExe, 'Run: npm run build:capture')
  mustExist(playerExe, 'Run: npm run build:player  (needs Go)')
  mustExist(path.join(ROOT, 'public', 'index.html'), 'Missing public/index.html')
  const iconIco = path.join(ROOT, 'public', 'icon.ico')
  mustExist(iconIco, 'Missing public/icon.ico — generate app icon first')
  mustExist(path.join(ROOT, 'host', 'main.go'), 'Missing host/main.go')

  ensureDir(BUILD_DIR)
  ensureDir(RELEASE_DIR)

  console.log('[1/7] preparing embed assets…')
  rmrf(path.join(BUILD_DIR, 'public'))
  rmrf(path.join(BUILD_DIR, 'bin'))
  copyDir(path.join(ROOT, 'public'), path.join(BUILD_DIR, 'public'))
  ensureDir(path.join(BUILD_DIR, 'bin'))
  fs.copyFileSync(captureExe, path.join(BUILD_DIR, 'bin', 'audio-capture.exe'))
  fs.copyFileSync(playerExe, path.join(BUILD_DIR, 'bin', 'audio-play.exe'))

  console.log('[2/7] bundling server…')
  await esbuild.build({
    entryPoints: [path.join(ROOT, 'server', 'index.js')],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node18',
    outfile: BUNDLE,
  })

  fs.writeFileSync(
    PKG_CONFIG,
    JSON.stringify(
      {
        pkg: {
          assets: ['public/**/*', 'bin/**/*'],
          targets: ['node22-win-x64'],
        },
      },
      null,
      2,
    ),
  )

  console.log('[3/7] applying Windows exe icon to pkg base binary…')
  const stampedNode = await stampBaseNodeIconAsync(iconIco)

  console.log('[4/7] packaging server exe (public + bin embedded)…')
  const require = createRequire(import.meta.url)
  const pkgCli = require.resolve('@yao-pkg/pkg/lib-es5/bin.js')
  const serverExe = path.join(BUILD_DIR, 'ToneferryServer.exe')
  const stagedPkg = path.join(BUILD_DIR, 'ToneferryServer.build.exe')

  tryStopRunningExe()
  await new Promise((r) => setTimeout(r, 200))
  rmrf(stagedPkg)

  execFileSync(
    process.execPath,
    [
      pkgCli,
      'server.cjs',
      '-c',
      'pkg.config.json',
      '--targets',
      'node22-win-x64',
      '--output',
      stagedPkg,
      '--compress',
      'GZip',
    ],
    {
      stdio: 'inherit',
      cwd: BUILD_DIR,
      env: { ...process.env, PKG_NODE_PATH: stampedNode },
    },
  )

  rmrf(serverExe)
  fs.renameSync(stagedPkg, serverExe)
  console.log(`      → ${serverExe}  (${(fs.statSync(serverExe).size / 1048576).toFixed(1)} MB)`)

  console.log('[5/7] embedding server into tray host…')
  const hostAssets = path.join(ROOT, 'host', 'assets')
  ensureDir(hostAssets)
  fs.copyFileSync(serverExe, path.join(hostAssets, 'ToneferryServer.exe'))

  console.log('[6/7] building tray host (Go, windowsgui)…')
  const goBin = findGo()
  execFileSync(
    goBin,
    ['build', '-ldflags', '-s -w -H=windowsgui', '-o', path.join(RELEASE_DIR, EXE_NAME), '.'],
    { cwd: path.join(ROOT, 'host'), stdio: 'inherit', env: process.env },
  )

  console.log('[7/7] stamping icon + version info onto tray exe…')
  const outExe = path.join(RELEASE_DIR, EXE_NAME)
  stampGoExe(outExe, iconIco)

  refreshExplorerIcons()

  const mb = (fs.statSync(outExe).size / 1048576).toFixed(1)
  console.log('')
  console.log(`Single file: ${outExe}  (${mb} MB)`)
  console.log('Double-click Toneferry.exe — 托盘常驻，不弹 cmd 窗口。')
}

function findGo() {
  const candidates = [
    process.env.GOROOT ? path.join(process.env.GOROOT, 'bin', 'go.exe') : null,
    'C:/Program Files/Go/bin/go.exe',
    'C:/Go/bin/go.exe',
  ].filter(Boolean)
  for (const c of candidates) {
    if (fs.existsSync(c)) return c
  }
  try {
    execFileSync('go', ['version'], { stdio: 'ignore' })
    return 'go'
  } catch {
    /* fall through */
  }
  console.error('[error] 找不到 Go 工具链，托盘宿主无法编译。')
  console.error('        安装 Go 1.21+（https://go.dev/dl/）后重试，或设置 GOROOT。')
  process.exit(1)
}

/** Go 产出的 exe 默认没有图标/版本资源，这里用 resedit 补上。 */
function stampGoExe(exePath, iconPath) {
  let exe
  let res
  try {
    exe = ResEdit.NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true })
    res = ResEdit.NtExecutableResource.from(exe)
  } catch (err) {
    console.warn(`[warn] 无法解析托盘 exe，跳过图标：${err.message}`)
    return
  }

  try {
    const iconFile = ResEdit.Data.IconFile.from(fs.readFileSync(iconPath))
    const icons = iconFile.icons.map((item) => item.data)
    const groups = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries)
    if (groups.length === 0) {
      ResEdit.Resource.IconGroupEntry.replaceIconsForResource(res.entries, 1, 1033, icons)
    } else {
      for (const group of groups) {
        ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
          res.entries,
          group.id,
          group.lang,
          icons,
        )
      }
    }
    console.log(`[icon] tray exe icon replaced (${groups.length || 1} group)`)
  } catch (err) {
    console.warn(`[warn] 图标写入失败：${err.message}`)
  }

  try {
    const version = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version
    const parts = version.split('.').map((n) => parseInt(n, 10) || 0)
    while (parts.length < 4) parts.push(0)

    let vi = ResEdit.Resource.VersionInfo.fromEntries(res.entries)[0]
    if (!vi) vi = ResEdit.Resource.VersionInfo.createEmpty()
    vi.setFileVersion(parts[0], parts[1], parts[2], parts[3], 1033)
    vi.setProductVersion(parts[0], parts[1], parts[2], parts[3], 1033)
    vi.setStringValues(
      { lang: 1033, codepage: 1200 },
      {
        FileDescription: 'Toneferry 系统音频推流',
        ProductName: 'Toneferry',
        OriginalFilename: EXE_NAME,
        InternalName: 'Toneferry',
        CompanyName: 'Toneferry',
        FileVersion: version,
        ProductVersion: version,
      },
    )
    vi.outputToResourceEntries(res.entries)
    console.log(`[icon] tray exe version → ${version}`)
  } catch (err) {
    console.warn(`[warn] 版本资源写入失败：${err.message}`)
  }

  try {
    res.outputResource(exe)
    fs.writeFileSync(exePath, Buffer.from(exe.generate()))
  } catch (err) {
    console.warn(`[warn] 回写托盘 exe 失败：${err.message}`)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
