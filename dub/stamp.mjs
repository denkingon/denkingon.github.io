#!/usr/bin/env node
// index.html の ?v= を今の時刻で一括更新する。JS/CSS を変えて公開する前に一度走らせる:
//   node dub/stamp.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const here = path.dirname(fileURLToPath(import.meta.url));
const p = path.join(here, "index.html");
const d = new Date(), z = n => String(n).padStart(2, "0");
const v = `${d.getUTCFullYear()}${z(d.getUTCMonth() + 1)}${z(d.getUTCDate())}${z(d.getUTCHours())}${z(d.getUTCMinutes())}`;
const before = fs.readFileSync(p, "utf8"), after = before.replace(/\?v=\d{12}/g, "?v=" + v);
fs.writeFileSync(p, after);
console.log(`stamped ?v=${v} (${(before.match(/\?v=\d{12}/g) || []).length} places)`);
