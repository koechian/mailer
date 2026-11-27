// Exports the Hugeicons Mailer uses (free set, MIT — LICENSE in the npm
// package @hugeicons/core-free-icons) to plain SVG files in Resources/Icons.
//
//   npm pack @hugeicons/core-free-icons && tar -xzf hugeicons-core-free-icons-*.tgz
//   node tools/export-icons.mjs <path-to-unpacked>/package/dist/esm
//
// Each icon is a list of [tag, attrs] pairs drawn on a 24×24 grid with
// `currentColor`. They are written black, and the app loads them as template
// images so SwiftUI tints them like SF Symbols.

import fs from 'node:fs'
import path from 'node:path'
import url from 'node:url'

const [, , esmDir] = process.argv
if (!esmDir) { console.error('usage: node tools/export-icons.mjs <dist/esm>'); process.exit(1) }

// Mailer name → Hugeicons name.
const ICONS = {
  inbox: 'Inbox', mail: 'Mail01', mailOpen: 'MailOpen01', compose: 'MailAdd01',
  sent: 'MailSend01', reply: 'ArrowTurnBackward', forward: 'ArrowTurnForward', drafts: 'Note01',
  star: 'Star', pin: 'Pin', archive: 'Archive', trash: 'Delete02', spam: 'Spam',
  search: 'Search01', settings: 'Settings02', attachment: 'Attachment01',
  filter: 'Filter', copy: 'Copy01', notification: 'Notification01',
  newsletter: 'News01', calendar: 'Calendar03', folder: 'Folder01', user: 'User',
  verified: 'CheckmarkBadge01', tick: 'Tick02', close: 'Cancel01',
  logout: 'Logout01', refresh: 'Refresh01', more: 'MoreHorizontal',
  back: 'ArrowLeft01', chevronDown: 'ArrowDown01', clock: 'Clock01',
  key: 'Key01', lock: 'SquareLock01', shield: 'Shield01', file: 'File01',
  image: 'Image01', plus: 'PlusSign', markUnread: 'MailOpen02', people: 'UserCircle'
}

const out = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '../Resources/Icons')
fs.mkdirSync(out, { recursive: true })

const attr = (k) => k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())

// Hugeicons draw at 1.5 on the 24 grid; the owner asked for them a touch
// heavier (2026-11-12), so every stroke is drawn at 1.75.
const STROKE = '1.75'

for (const [name, hi] of Object.entries(ICONS)) {
  const mod = await import(path.join(path.resolve(esmDir), `${hi}Icon.js`))
  const nodes = mod.default ?? Object.values(mod)[0]
  const body = nodes.map(([tag, attrs]) => {
    const a = Object.entries(attrs)
      .filter(([k]) => k !== 'key')
      .map(([k, v]) => `${attr(k)}="${k === 'strokeWidth' ? STROKE : String(v).replace(/currentColor/g, '#000')}"`)
      .join(' ')
    return `<${tag} ${a}/>`
  }).join('')
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">${body}</svg>\n`
  fs.writeFileSync(path.join(out, `${name}.svg`), svg)
}
console.log(`wrote ${Object.keys(ICONS).length} icons to ${out}`)
