# PRD: Diagram Shapes — CoThink Board

> เอกสารส่งให้ทีมเว็บพอร์ตฟีเจอร์ shapes ขึ้น web app ให้ตรงกับของจริงบน macOS (คอมมิต `bf9e1d3` → `2cfbbf6`, พ.ย. 2569) ข้อกำหนดเชิง model อ้างจาก `DECISIONS.md` และ `Note.hasValidExtent` ใน `Sources/BoardCore/BoardCore.swift`

## เป้าหมาย

ผู้ใช้วาง object สำหรับเขียน diagram (กล่อง, วงรี, ตัดสินใจ, เส้น) ลง canvas ได้ เชื่อมด้วย connection ปักหมุดใส่ group และย่อขยายได้ เหมือนโน้ตทุกด้าน ผู้ใช้ที่เปิดกระดานเดียวกันจากเว็บและจากแอป macOS ต้องเห็น shape ชุดเดียวกัน

## โมเดลข้อมูล (สัญญาที่ต้องตรงทุกฝั่ง)

- เพิ่ม field บน note สองตัว: `shape: string?` ค่าที่อนุญาต `rectangle | ellipse | diamond | line | text | null` — `null` = โน้ตข้อความธรรมดา (มีกล่อง) และ `lineFlipped: bool?` (เฉพาะ line: `true` = เส้นทแยงวิ่งจากขวาบนไปซ้ายล่าง, `null`/`false` = ซ้ายบนไปขวาล่าง) ไม่มีเอนทิตีใหม่ ไม่มี collection ใหม่
- Field เป็น optional ทั้งคู่ ข้อมูลเก่าที่ไม่มีคีย์ decode เป็น `null` โดยไม่แตะ schema version (ฝั่งแมคพินด้วยเทสต์ `testShapeFieldDecodesLegacyJSONAsNil` และ `testLineFlippedDecodesLegacyJSONAsNil`)
- **Line คือเส้นทแยงของ bounding box** ของโน้ต เพราะ bounding box เก็บทิศทแยงไม่ได้ จึงมี `lineFlipped` เสริม เส้นนอนล้วนมี height = 0 ได้
- กฎ extent ที่ validate บังคับตอน save (จุดเดียวของระบบ):
  - พิกัด x, y, width, height ต้องเป็น finite number ทุกโน้ต
  - โน้ตที่ไม่ใช่ line: `width > 0 && height > 0`
  - **line: `width > 0 || height > 0`** (ยอมให้มิติใดมิติหนึ่งเป็นศูนย์)
- ทุกอย่างที่เคยผูกกับโน้ตมีผลกับ shape ทันที: connection endpoints, สมาชิก group, `parentID` (tree), copy-paste, undo snapshot ทั้งกระดาน — ห้ามเขียน exception แยกตามชนิด

## การสร้าง (drag-to-create)

| รายการ | ค่าที่ฝั่งแมคใช้ (ให้ตรง) |
|---|---|
| จุดเข้าถึง | เมนู Shape (4 ชนิด) ถัดจากปุ่ม Note บน toolbar — กดเลือกชนิด = **arm tool** ไม่ได้วางทันที |
| วาด | ลากบนพื้นที่ว่างของ canvas = สร้างตามกรอบที่ลาก มี preview เส้นประสี accent โชว์สดระหว่างลาก ปล่อยมือ = สร้างจริง (1 mutate ต่อ shape, undo ครั้งเดียว) |
| ดับเบิลแท็ปตอน armed | วาง shape ขนาด default ตรงจุดแท็ป (มิฉะนั้นดับเบิลแท็ปพื้นที่ว่าง = สร้างโน้ตตามเดิม) |
| ลากสั้น (< 8pt) | สร้างขนาด default (160×120, line 160×80) ที่จุดเริ่มลาก |
| สีเริ่ม | `#F3F1EC`, ข้อความเริ่มว่าง |
| หลังสร้าง | เลือก object ไว้, **ไม่เปิด text editor**, และ **tool ยังค้าง armed** วาดต่อได้เรื่อย ๆ จนกด Esc หรือเปลี่ยนบอร์ด |
| ทิศเส้น Line | ตามทิศลากจริง: ลากลงขวา/ขึ้นซ้าย = ทแยงซ้ายบน→ขวาล่าง, ลากลงซ้าย/ขึ้นขวา = ทแยงขวาบน→ซ้ายล่าง (`lineFlipped`) |
| **⌘-drag ตอน armed** | **ยังเป็น marquee เลือก object เหมือนเดิมทุกประการ** (⌘+shift ลาก = เลือกเพิ่ม) โหมดตัดสินที่จุดเริ่มลาก แล้วคงโหมดนั้นจนปล่อยมือ |
| Toolbar caption ตอน armed | "Drag on the canvas to draw a rectangle · ⌘-drag to select · Esc to cancel" (รูปแบบเดียวกับ caption กลุ่ม) |
| ลากบน object อื่น | ยังเป็นการย้าย/เลือก object นั้นตามเดิม (gesture ของ tile ชนะ) การวาดเริ่มได้เฉพาะบนพื้นที่ว่าง |
| ขนาด default ตอนแตะ/ลากสั้น | 160×120 (line 160×80, **text 160×40**) วางที่จุดเริ่มลาก |

## กฎการลากย้ายบน canvas (ทีมเว็บต้องทำให้เหมือน)

- **ลากโน้ตใด ๆ ที่เลือกเดี่ยว: subtree ตามมาเสมอ** (ลูกทุกชั้นผ่าน `parentID`) และถ้าโน้ตอยู่ใน group ที่ lock ก็ลากทั้ง group — เป็น fixed point เดียวกับ multi-select drag (`selectionMovement`) ทดสอบไว้แล้วที่ `testSelectionMoveCarriesSubtreeAndLockedGroups`
- ลากโน้ตลูกเดี่ยว = ย้ายเฉพาะตัวมันกับ subtree ของมันเอง ไม่แตะพ่อ
- ⇧-click ยังเลือกทั้งกิ่งแบบ toggle เพื่อแก้ property ร่วมกันเหมือนเดิม, marquee เลือกตามจุดกึ่งกลางกรอบเหมือนเดิม
- ตำแหน่งถูก clamp ไม่ให้ติดลบ (ห้ามลากออกนอกกระดานทางซ้าย/บน)

- Esc / เปลี่ยนบอร์ด / บอร์ดถูกปิด = เคลียร์ tool และ preview ทิ้ง
- การลากวาดใช้พิกัดชื่อ "boardCanvas" ตรง ๆ **ห้ามหาร zoom** (ช่องว่าง gesture นี้เป็นพื้นที่ unscaled แล้ว การหารจะทำให้ขนาดเพี้ยนเมื่อ zoom ≠ 100%)

## การแสดงผล

- rectangle: มุมโค้ง 6, ellipse: วงรีเต็มกรอบ, diamond: polygon จากจุดกึ่งกลางขอบทั้งสี่ด้าน, line: เส้นเฉียงตั้งแต่มุมซ้ายบนถึงมุมขวาล่าง ไม่มีพื้น
- **text: ไม่มีกล่องเลย** ไม่มีพื้น ไม่มีขอบ ข้อความชิดซ้าย สีเป็นสีหลักของธีม (adaptive) ถ้าว่างจะแสดง ghost "Empty text" ที่ opacity 0.35 ให้ยังจับได้; **auto-fit ความสูงตามเนื้อหาเหมือนโน้ตธรรมดา** (ข้อยกเว้นเดียวของกฎไม่ auto-fit ด้านล่าง) และตอนสร้างจะเปิด editor ให้พิมพ์ทันที
- พื้นและขอบใช้ field เดิมของโน้ตครบชุด: `color` (พื้น), `strokeColor` (ค่าเริ่ม `#6F7785`), `strokeWidth` (ค่าเริ่ม 1), `strokeStyle` (dashed = dash 8 5, dotted = dash 1 4)
- ข้อความ: rect / ellipse / diamond แสดง text กึ่งกลางกล่อง, line และ text ต่างจากนี้ตามที่ระบุ
- **ไม่มี placeholder "Empty note" บน shape กล่อง** (text มี ghost ของตัวเอง) กล่องว่างเปล่าคือสถานะที่ถูกต้อง โน้ตธรรมดาคง placeholder เดิม
- ดับเบิลคลิก: shape ทุกชนิดเปิด editor ได้ ยกเว้น **line ดับเบิลคลิก = เลือกอย่างเดียว**
- **พื้นที่คลิกของ line: แถบล่องหนหนา 14pt ตามแนวเส้น** (ไม่ใช่ทั้ง bounding box และไม่ใช่เส้น 1pt) คลิกนอกแถบ = ทำงานกับชั้นพื้นหลังตามปกติ เมื่อเลือก line หรือ text จะมีกรอบ selection มุมโค้ง 4 รอบ bounding box
- Fold badge, รูปแนบ, asset preview ทำงานกับ shape เหมือนโน้ต ไม่ต้อง special case
- ความสูงของ shape กล่องเป็น geometry ของผู้ใช้ **ห้าม auto-fit จากเนื้อหาเด็ดขาด** (text กับโน้ตธรรมดาคง refit เดิม)

## Interaction และ Inspector

- ลากย้าย / resize ด้วยจุดยึดมุม / เลือกหลายอัน / marquee / copy-paste / undo: ใช้ระบบเดิมของโน้ตทั้งหมด
- ค่า min ตอน resize: ทั่วไป 80×50, **line = 1×1** (min 1 ไม่ใช่ 0 เพื่อกันผลลัพธ์ 0×0 ที่ validate จะปฏิเสธ)
- Inspector มีแถว Shape (None + 4 ชนิด) ใช้แปลงโน้ต ↔ shape กลับไปมาได้ field เดียว ไม่ต้องสร้างใหม่
- ปุ่ม "Fit heights to content" แบบเลือกหลายอัน ต้อง**ข้าม shape** (เหตุผลเดียวกับห้าม auto-fit)
- จุดที่พลาดกันง่าย: ตอน save จาก Inspector ต้อง**เขียน `shape` ก่อน clamp width/height** เพราะค่า min ขึ้นกับชนิดใหม่ ถ้า clamp ก่อน จะยืดเส้นนอน h=0 กลายเป็น h=50 เองโดยไม่มีใครสั่ง
- connection ปลายเส้นตัดที่กรอบ bounding ของ shape (ไม่ใช่ขอบวงรี/เพชรจริง) เป็น approximation ที่ฝั่งแมครับไว้ใน v1 เว็บใช้นิยามเดียวกันเพื่อให้ภาพตรงกัน

## API และ agent

- Local MCP `edit_board` (note op) รับ `shape` ผ่าน raw merge อยู่แล้ว คำอธิบาย tool บอก enum ครบ (รวม `text`) และ `lineFlipped` (line only; true = ทแยงขวาบน→ซ้ายล่าง, absent = ซ้ายบน→ขวาล่าง) แล้ว (คอมมิต `857e627`)
- `get_board_context` ส่ง `shape` **เฉพาะเมื่อไม่ null** และส่ง `lineFlipped` **เฉพาะเมื่อ true** (absent = ทแยง default ซ้ายบน→ขวาล่าง — false คือค่า default ที่ bounding box บอกอยู่แล้ว ไม่ต้องส่งซ้ำ)
- Generic edit op reject ค่าผิดแบบบอกค่าที่อนุญาตแล้วบนแมค (`857e627`): `shape` ที่ไม่อยู่ใน enum → error บอก allowed list, `lineFlipped` ที่ไม่ใช่ boolean → error, และห้ามส่ง `shape`/`lineFlipped` ลง connection/group (ทีมเว็บต้องทำนิยามเดียวกัน)
- **ช่องว่างที่ทีมเว็บต้องเติม:** CoThink Cloud API ปัจจุบันยังไม่รับ/ไม่ส่ง `shape` (ต่างจาก `parentID`/`collapsed` ที่เว็บมีแล้วเฉพาะ local) ให้เพิ่ม field นี้ใน REST และ cloud tool schema ให้ครบ พร้อมกัน

## PDF และภาพ overview (capture)

- SVG overview เรนเดอร์ geometry จริงทุกชนิด: rect rx=6, ellipse, diamond polygon, `<line>` โดยรองรับ `lineFlipped` (สลับ x1/x2 เมื่อ true); ข้อความ centered (baseline = กึ่งกลาง + fontSize×0.35) และไม่มี clipPath/ข้อความสำหรับ line
- ส่วนรายการข้อความเต็มใน PDF (note cards) ยังรวม shape note ตามลำดับ array เหมือนเดิม ไม่ต้องแยกหมวด

## Acceptance criteria

1. กระดานเก่าทุกใบเปิดได้ field หาย = โน้ตข้อความ ไม่มี error
2. บันทึก line height = 0 ผ่าน, บันทึก rect height = 0 ถูกปฏิเสธด้วย error "geometry"
3. เลือกชนิดในเมนู Shape แล้วลากบนพื้นที่ว่าง = สร้างตามกรอบที่ลาก มี preview เส้นประระหว่างลาก ปล่อยแล้ว tool ยังค้าง กด Esc ปิดได้ ไม่มี editor เด้งขึ้นเอง
4. ดับเบิลแท็ปพื้นที่ว่างตอน tool armed = วาง shape ขนาด default ตรงจุด (ไม่ใช่โน้ต)
5. แปลงโน้ตเป็น shape และกลับ None ได้ ข้อความ/สี/เส้นขอบคงเดิมตลอดการแปลง
6. เส้นนอนย่อเหลือ height = 1 ได้จากทั้ง canvas และ Inspector และ 0×0 ทำได้ไม่ถึง ไม่ว่าทางไหน
7. พิมพ์ label ใน diamond แล้วข้อความกึ่งกลาง ความสูงกล่องไม่เปลี่ยนตามเนื้อหา
8. ลบ shape ที่มี connection ติดอยู่ = เส้นหายไปด้วย (cascade เดิม) undo กู้ครบทั้งคู่
9. ลากสร้าง line แบบลากขึ้นขวา ได้เส้นทแยงขวาบน→ซ้ายล่าง และ PDF/capture แสดงทิศนั้นตรงกัน (`lineFlipped`)
10. คลิกใกล้ ๆ เส้น (ในรัศมี ~7pt จากแนวเส้น) = เลือกเส้น และเมื่อเลือกแล้วมีกรอบ selection รอบกรอบเส้น
11. ลาก parent ที่เลือกเดี่ยว ลูกทุกชั้นขยับตามใน preview สดและตอน commit; ลากลูกเดี่ยวไม่ลากพ่อ; undo กลับได้ทั้งก้อน
12. สร้าง text object แล้ว editor เปิดให้พิมพ์ทันที พิมพ์จบความสูง auto-fit; PDF/capture แสดงเป็นข้อความล้วนไม่มีกล่อง
13. PDF และ capture ของกระดานที่มี shape แสดงรูปทรงจริงทุกชนิด

## นอกขอบเขต v1 (ฝั่งแมคยังไม่ทำ)

rotation, การสั่ง z-order (bring to front), freehand/polyline/ลูกศรอิสระ, มุมโค้งปรับได้ต่อ shape, ข้อความบน line

## ลำดับงานแนะนำสำหรับทีมเว็บ

1. Model + validate + API field ก่อน (ฝั่งแมคทั้งหมดใช้ ~65 บรรทัด) เทสต์แบบ literal ตาม acceptance 1-2
2. Rendering ทั้ง canvas และ SVG ในชุดเดียวกัน (ตัว render ซ้ำกันหลายที่จะคลาดกันได้ ให้ใช้ข้อกำหนดเดียวในตารางการแสดงผล)
3. Toolbar/Inspector interaction ตามด้วย อย่าลืมกฎสองข้อ: ไม่ auto-open editor, ไม่ auto-fit height
4. Cloud API + reject-คีย์ผิดปิดท้าย

## สถานะ

- macOS: **ship แล้ว** (คอมมิต `bf9e1d3` model + `2cfbbf6` surfaces + `857e627` MCP lineFlipped/validate, deploy แล้วใน /Applications, เทสต์ BoardCoreTests 43 ตัวครบ + e2e test-mcp.py ส่วน shapes ผ่านทั้ง debug และ deployed binary, DECISIONS.md บันทึกแล้ว)
- skill prompt สองบ้าน (`~/.zcode/skills/cothink-board/SKILL.md` + `CoThinkBoardSkill.swift`) อัปเดตแล้วให้ agent รู้จัก field นี้
- เว็บ: ยังไม่มี เอกสารนี้คือจุดเริ่มงาน
