# แนวทางพัฒนา Object ใหม่บน CoThink Board (สำหรับทีม Web)

เอกสารนี้สรุปสถาปัตยกรรมของระบบ object บนบอร์ด (shape / icon) จาก implementation จริงในแอป macOS
(commits `08ffb66 → 4acf887 → a486da6`, 10 พ.ย. 2569) และกำหนดสูตรลัด + เกณฑ์ตรวจรับ
สำหรับการเพิ่ม object ชุดใหม่ใน web app ให้ได้เทียบเท่ากันทุก surface

---

## 1. หลักการพื้นฐาน — object คือ note ไม่ใช่ entity ใหม่

**ห้ามสร้างตาราง/ทรงพลังแยกต่างหาก** ทุก object บนบอร์ดคือ `Note` ที่มี field เสริมแบบ orthogonal:

```json
{
  "id": "db1",
  "text": "Primary DB",
  "x": 0, "y": 0, "width": 160, "height": 120,
  "color": "#F3F1EC",
  "shape": "rectangle",          // ทรงกรอบ (มีอยู่แล้ว) — null = สี่เหลี่ยมมุมมน
  "icon": "database"             // ← field ใหม่: null = ไม่มี icon
}
```

เพราะ object เป็น note มาแต่ต้น สิ่งเหล่านี้ทำงาน **ฟรีทันที ไม่ต้องเขียนโค้ดเพิ่ม**:
connection/arrow เข้า-ออก, groups (lock/move รวมกัน), undo/redo, marquee select,
copy/paste, mindmap tree (parentID), MCP `edit_board` ทุก action

**กฎเหล็ก:** field ใหม่ต้องเป็น optional + tolerant — ค่าที่ client เก่าไม่รู้จักต้อง render
เป็น note ปกติ (ไม่ crash ไม่หาย) ทั้งสองทิศทาง (เก่าอ่านใหม่ / ใหม่อ่านเก่า)

---

## 2. สถาปัตยกรรม icon (งานล่าสุด) — ตัวอย่างบังคับ

### 2.1 Catalog = enum เดียว เป็น single source of truth

```
NoteIcon (String enum, Codable): cloud | database | compute | network | users
  ├── rawValue     → ค่าที่เก็บใน board JSON (ต้อง stable ตลอดชีพ — ห้ามเปลี่ยนชื่อ)
  ├── displayName  → ชื่อแสดง (UI, inspector, menu)
  └── svgPath      → geometry เดียวของ icon ในกรอบ 24×24
```

### 2.2 กฎที่สำคัญที่สุด: "geometry ชุดเดียว ทุก surface"

เก็บ path data แบบ SVG (viewBox 24×24, stroke-based, `stroke-width: 2`, round cap/join —
รูปแบบ feather/lucide ซึ่งเป็น MIT license ใช้ได้) แล้วดึงไปใช้ **สองทาง**:

| Surface | วิธีใช้ |
|---|---|
| PDF / capture_board (SVG overview) | เอา path string ไปใส่ตรง ๆ `<g transform="translate(..) scale(s)"><path d="…" fill="none" stroke="…"/></g>` |
| Canvas (web/app) | parse path → vector commands (`M/L/H/V/C/S/Q/T/A/Z` รองรับทั้ง absolute/relative, arc แปลงเป็น cubic Bézier ตามสเปก SVG) → วาดเป็น path |

ห้ามใช้ SF Symbols / ชุด glyph ของ platform ใน canvas แล้ว SVG แยกใน PDF —
จะเบี้ยวกันแน่นอน ให้เวลาตรวจ ใช้ `capture_board` เทียบกับ canvas ได้ตรง ๆ

ขนาด glyph ใช้ **สูตรกลางเดียวกัน** (อย่าให้แต่ละ client คิดเอง):

```
glyphSize(w, h) = max(22, min( min(w, h) × 0.52, min(w, h) − 40 ))
```

layout ใน tile: glyph กึ่งกลางแนวตั้ง, label ใต้ glyph (spacing 6, `fontSize` ของ note),
ความสูง content = `glyph + (มี label ? 6 + fontSize×1.2 : 0)`, กึ่งกลางในความสูง tile

### 2.3 พฤติกรรมโมเดลที่ต้องเหมือน

- note ที่มี `icon` **ไม่ autofit ความสูง** (มีสัดส่วนคงที่เหมือน shape — geometry เป็นของ user)
- ค่า `icon` ที่ไม่อยู่ใน catalog → ถือเป็น icon ปกติ/nil ตอน render (tolerant decode)
- `icon` กับ `shape` ตั้งรวมกันได้ (icon วาดทับ layout ของ shape แบบ centered)

### 2.4 การสร้างบน canvas (armed-tool pattern — ให้ทุก object ชนิดใหม่ใช้เหมือนกัน)

1. ปุ่ม/เมนูใน toolbar → **arm tool** (ยังไม่เกิด object)
2. ลากบน canvas = กำหนดกรอบ (มี dashed preview + glyph จาง) ; คลิกเฉย ๆ = ขนาด default 160×120
3. tool **ยังคง armed** หลังสร้าง (วางซ้ำได้เร็ว), Esc ยกเลิก
4. ⌘-ลาก (macOS) / ลากบนที่ว่างแบบเดิม (web: ปุ่ม select หรือ modifier) ยัง marquee เลือกได้เสมอ
5. ปรับ/เอาออกได้ที่ Inspector (picker: None + ทุกค่าใน catalog)

### 2.5 MCP / AI agent surface — ครบทั้ง 5 จุดนี้เท่านั้นถึงจะ "ปล่อยได้"

1. `edit_board` ตรวจค่า (`icon` ไม่อยู่ใน catalog → error ที่อ่านง่าย พร้อมระบุ allowed list,
   `null` = ล้าง)
2. key guard: `shape`/`lineFlipped`/`icon` ใช้ได้เฉพาะ notes (ยิงใส่ connection/group ต้อง error)
3. description ของ `edit_board` อัปเดตบอก enum ใหม่
4. `get_board_context`/`get_board` emit field ใหม่ **เมื่อมีค่าเท่านั้น** (absent = default)
5. system prompt ของ Pi (2 บ้าน: `~/.zcode/skills/cothink-board/SKILL.md` +
   `CoThinkBoardSkill.swift` ต้อง sync กัน) + test ที่ pin ข้อความ enum

---

## 3. สูตรลัด: เพิ่ม object ชุดใหม่ 8 ขั้น (ใช้ได้ทั้ง web และ app)

เช่น จะเพิ่ม icon set "network devices": router, firewall, load balancer, switch, dns

1. **Catalog** — เพิ่ม case ใน enum + `rawValue` (snake_case, ห้ามแก้ทีหลัง) + displayName
   + `svgPath` (24×24 stroke path, ทดสอบว่า parse ได้และ bounds อยู่ใน [0,24] ทุกด้าน ±0.01)
2. **โมเดล** — ยืนยันว่า field มีอยู่แล้ว (icon เป็น field เดียวกับชุดเก่า — set ใหม่คือเพิ่ม "ค่า"
   ไม่ใช่เพิ่ม "field") ; ถ้าเป็น object ประเภทใหม่จริง ๆ (field ใหม่) ให้ทำตาม §1 และทำ tolerant
   decode ทันที
3. **Canvas** — render ผ่าน glyph path เดิม + armed tool (เมนูจัดกลุ่มได้ถ้า item เยอะ)
4. **Inspector** — picker แสดงค่าใหม่อัตโนมัติจาก enum (อย่า hardcode รายชื่อซ้ำ)
5. **PDF/capture** — path เดียวกัน, สูตร glyphSize เดียวกัน
6. **MCP** — §2.5 ครบ 5 ข้อ (allowed list ใน error message ต้อง generate จาก enum ไม่ใช่พิมพ์ซ้ำ)
7. **Prompt ของ agent** — สอน enum ใหม่ใน 2 บ้าน + pin ด้วย test
8. **Tests + e2e** — ตาม §4

ข้อห้าม: เพิ่ม icon โดยเขียน branch `if icon == "rocket"` กระจายในโค้ด — ทุกอย่างต้องขับเคลื่อน
จาก enum/data (web: เก็บ catalog เป็นโมดูลเดียว export `{ rawValue, displayName, path }[]`)

---

## 4. เกณฑ์ตรวจรับ (Definition of Done) ต่อ object ชุดใหม่

**Unit tests**
- [ ] catalog มีจำนวน case ตรงที่ประกาศ + rawValue ไม่ซ้ำ
- [ ] JSON round-trip คงค่า icon/shape (encode → decode = เท่าเดิม)
- [ ] path ของทุก icon parse สำเร็จ และ bounds อยู่ในกรอบ 24×24 (±0.01)
- [ ] icon note ไม่ autofit ความสูง ; glyphSize ได้ค่าตามสูตรที่ boundary (160×120, 80×50)
- [ ] ค่า icon แปลกหน้า (unknown rawValue) ไม่ทำให้ decode/render พัง

**MCP e2e** (แพทเทิร์น: `scripts/test-mcp-icons.py` — spawn binary + scratch COTHINK_HOME)
- [ ] add note พร้อม icon → `get_board_context` เห็นค่านั้น
- [ ] update เป็นค่าใหม่ / เป็น null (ล้าง) สำเร็จ
- [ ] ค่า invalid → error "Invalid icon … allowed: …" (ตรวจว่ามีชื่อจาก enum ใหม่ด้วย)
- [ ] ใส่ `icon` บน connection → error อ้างว่าเป็นของ notes
- [ ] `capture_board` ของบอร์ดที่มี icon ทุกตัว ไม่ error

**Visual**
- [ ] capture_board เทียบ canvas: glyph, ขนาด, ตำแหน่ง label ตรงกัน (นี่คือเกณฑ์ WYSIWYG)
- [ ] dark mode: glyph ใช้ stroke สีจาก note (default `#6F7785`) ไม่ใช่สีคงที่

**Prompt**
- [ ] test pin ว่า system prompt มี enum ครบ และไม่มีชื่อ server ต้องห้าม

---

## 5. สิ่งที่ web ต้องทำ "ตอนนี้" เพื่อตามให้ทัน

CoThink Cloud API **ยังไม่มี field `shape` และ `icon`** (ปัญหาเดิมจาก PRD shapes) —
งานแรกของ web คือ:

1. เพิ่ม `shape`, `lineFlipped`, `icon` เข้า API และ persistence (ทั้งหมด nullable, pass-through
   แบบไม่ validate ตายตัวก็ได้ — ให้ client เป็นคนตีความ)
2. render `icon` บน canvas (parser SVG path ฝั่ง web: ใช้ lib สำเร็จ เช่น
   `svg-path-properties` หรือทำ Path2D จาก `new Path2D(d)` ได้เลย เพราะ browser parse SVG
   path เองได้ — **ง่ายกว่าฝั่ง native มาก**)
3. PDF/ส่งออกฝั่ง web ใช้ `<path d>` ตรง ๆ (browser แจกใช้ได้ทันที)
4. UI สร้าง: เมนู Icon ใน toolbar + inspector picker ตาม §2.4
5. หลังจากนั้น ชุด icon ใหม่ที่เพิ่ม = ข้อ 3.1–3.8 ต่อชุด

---

## 6. ทิศทางชุด object ที่แนะนำให้พัฒนาต่อ (เรียงตามความคุ้ม)

| ชุด | ตัวอย่าง (5 ตัว/ชุด) | เหมาะกับ |
|---|---|---|
| Network devices | router, firewall, load balancer, switch, dns | สถาปัตยกระบบ/infra diagram |
| Storage & data | bucket, queue, cache, warehouse, stream | สถาปัตยกรรมข้อมูล |
| Security | lock, shield, key, certificate, audit log | งาน compliance/PMQA |
| Flow elements | start (วงรี), process (สี่เหลี่ยม), decision (สี่เหลี่ยมข้าวหลามตัด — มี shape แล้ว), document, terminator | flowchart กระบวนงาน |
| People & roles | user, team, admin, customer, stakeholder | service blueprint |
| Integration | API, webhook, event, connector, scheduler | ผัง integration |

หลักคัดเลือก: 5–8 ตัวต่อชุด (เมนูเกินจะพอง), ทุกตัวต้องอ่านรู้เรื่องตอนเล็ก (24×24 stroke),
ชื่อ rawValue เป็นคำเดียว/สองคำ ไม่ใช่วลี, อย่าทำ icon ที่ซีนเดียวกับ shape ที่มีอยู่
(เช่น ไม่ต้องมี icon "diamond")

---

## 7. ตัวอย่างอ้างอิงจากโค้ดจริง (แอป macOS)

| ไฟล์ | หน้าที่ |
|---|---|
| `Sources/BoardCore/BoardCore.swift` | `NoteIcon` enum + `svgPath` + `glyphSize` + `Note.icon` |
| `Sources/BoardCore/SVGPathParser.swift` | parser path → `NoteIconCommand` (arc→cubic ตามสเปก) |
| `Sources/BoardCore/BoardPDFHTML.swift` | SVG overview ฝัง `<g><path>` ของ icon |
| `Sources/CoThinkApp/IconGlyph.swift` | commands → SwiftUI Path (canvas) |
| `Sources/CoThinkApp/CoThinkApp.swift` | armed tool, drag-create, NoteTile render |
| `Sources/CoThinkApp/InspectorView.swift` | icon picker |
| `Sources/CoThinkMCP/main.swift` | validation + guards + description + emission |
| `scripts/test-mcp-icons.py` | MCP e2e ตาม §4 |

บทเรียนเฉพาะจากการ implement (เลี่ยงให้ web เจอซ้ำ): การแปลง arc→cubic ต้องใช้กฎ
Δθ อิง **sweep flag** (ไม่ใช่ large-arc flag) และ center ของวงรีต้องอยู่ในพิกัดสุดทั้งที่
จุด/คอนโทรลของ segment ห้าม transform ซ้ำ — ถ้าใช้ `Path2D`/lib ของ browser ฝั่ง web
จะไม่เจอปัญหาพวกนี้เลย
