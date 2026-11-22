# สรุปฟีเจอร์ Mindmap Mode — CoThink Board

> เอกสารสรุปสำหรับทีมเว็บที่จะพอร์ตฟีเจอร์ขึ้น web app อ้างอิงของจริงบน macOS (คอมมิต f697b72 → e45ed4b, พ.ย. 2569) — ส่วนรายละเอียดเชิงลึก (invariants, สูตรพิกัด, ข้อความ error) ให้ใช้ **`docs/CoThink-Mindmap-Mode-Spec.zip`** (Mindmap-Mode-Spec.md + ภาพประกอบ 4 ภาพ) เป็นตัวตั้งต้น

## ภาพรวม

โน้ตทุกแผ่นมีพ่อได้หนึ่งตัว รวมกันเป็น tree หลายต้นต่อกระดาน (forest) โครงสร้าง tree เป็น relation แยกจาก connection (ลูกศรอิสระ) และแยกจาก group — โน้ตแผ่นเดียวมีทั้งสามอย่างพร้อมกันได้ tree หุบ/กางได้เป็นกิ่ง และทุก operation รองรับ undo ครบ

## รายการฟีเจอร์

### โมเดลข้อมูล (เพิ่ม 2 ฟิลด์ ไม่มีเอนทิตีใหม่)

- `parentID: string?` — id พ่อ (ทิศลูกชี้หาพ่อ), `null` = root/โน้ตอิสระ
- `collapsed: bool?` — `true` = หุบ subtree ของโน้ตนี้ (เก็บได้เฉพาะโน้ตที่มีลูกโดยตรง)
- ทั้งคู่ optional → back-compat กับข้อมูลเก่าโดยไม่ต้องขยับ schema version
- Invariants บังคับที่จุดตรวจเดียวตอน save: พ่อเดียว, พ่อต้องอยู่บนกระดานเดียวกัน, ไม่มีวงวน (self-parent รวมอยู่ด้วย)
- ลบพ่อ = ลูกถูก **promote** ไปหาบรรพบุรุษที่รอดชีวิตใกล้ที่สุด ไม่ลบซ้อนทั้งกิ่ง

### Interaction บน canvas

| การกระทำ | คีย์ |
|---|---|
| สร้างลูกจากโน้ตที่เลือกใดก็ได้ (เริ่ม tree ใหม่ก็ได้) | `⇧Tab` |
| สร้างลูกจากโน้ตที่อยู่ใน tree แล้ว | `Tab` |
| สร้างพี่น้อง (โน้ตใน tree) | `Return` |
| สร้างโน้ตเชื่อมด้านขวา/ด้านล่าง (โน้ตธรรมดา — พฤติกรรมเดิม) | `Tab` / `Return` |
| เลือก/ถอนทั้ง subtree | `⇧Click` |
| หุบ/กาง subtree | `⌥Click` (เว็บ: `Alt+Click`) |
| จัดผัง tree ทั้งกระดาน | `⇧⌘T` |

- `⇧⌘T` จัดผังต่อ tree: รากไม่ขยับ ลูกไปซ้อนขวาของพ่อ (gapY = 24) พ่อกึ่งกลางเหนือก้อนลูก ลำดับพี่น้อง = y ปัจจุบันแล้วตามลำดับใน array, compute-then-apply, idempotent — ใส่ `root_id` เพื่อ tidy เฉพาะกิ่งได้ โน้ตที่ไม่มี tree ไม่ขยับ
- **Tab / ⇧Tab ใช้ได้ทั้งตอนเลือกโน้ตและตอนพิมพ์ข้อความอยู่ (inline edit):** ระหว่างพิมพ์ กด Tab = commit ข้อความแล้วสร้างโน้ตถัดไปตามกติกาเดียวกัน (routing เดียวกันทั้งสองสถานะ) แล้วเปิด editor ของโน้ตใหม่ทันที — ต้อง commit ความสูงที่ fit แล้วก่อนคำนวณตำแหน่งโน้ตใหม่ ส่วน Return ระหว่างพิมพ์ยังเป็นการขึ้นบรรทัดใหม่และ Esc ยัง commit ตามเดิม
- **⇧Enter ระหว่างพิมพ์ใน child note = สร้างพี่น้อง** (commit ข้อความ → sibling ใต้พ่อเดียวกัน → เปิด editor ทันที) ใช้เฉพาะโน้ตที่มีพ่อ (`parentID != nil`) เท่านั้น — โน้ต root และโน้ตธรรมดา ⇧Enter ยังเป็นการขึ้นบรรทัดใหม่ตาม default
- **เมนูคลิกขวาบนโน้ต:** Add Child Note / Add Sibling Note / Select Subtree / Remove from Tree (แสดงเฉพาะโน้ตที่มีพ่อ)
- ลากโน้ต = **subtree ตามมาด้วย** และ compose กับกฎ group เดิม (ลูกที่ถูก lock ใน group ดึง group ทั้งอันมาด้วย จนจุดตรึง)
- Tab/Return ต้อง route ตามสถานะโน้ตที่เลือก: โน้ตที่ผูก tree ได้คีย์ mindmap, โน้ตธรรมดาคงพฤติกรรมเดิม (ห้ามเปลี่ยน Tab ทั้งระบบ)

### การแสดงผล

- **เส้น tree** วาด derived จาก `parentID` (ไม่เก็บเป็นข้อมูล) รูปตัวแอล สี `#7A8BA8` หนา 1.5 หัวลูกศรปลายด้านลูก ไม่รับ click ลำดับ layer: groups → tree edges → connections → notes
- **ป้ายแคปซูล** มุมขวาล่างของโน้ตที่มีลูก: จำนวนลูกโดยตรง (พื้นโปร่ง) → fold แล้วเป็นพื้น `#7A8BA8` ตัวขาว `+N`
- กระดานโหมด mindmap มี toggle ใน Inspector

### Fold (หุบกิ่ง)

- โน้ตถูกซ่อน ก็ต่อเมื่อมีบรรพบุรุษ strict ที่ `collapsed = true` — นิยามเดียวใช้ทุก surface: canvas, minimap, marquee ลากเลือก, การสร้าง/lock group, ขอบเขต scroll, ภาพ overview ใน capture/PDF
- ขอบเขต fit ของ canvas/capture หดตามเฉพาะโน้ตที่มองเห็นเมื่อ fold
- PDF export: ภาพ overview ซ่อน subtree ที่ fold + ป้าย `+N` แต่ส่วนข้อความเต็มยังรวมทุกโน้ต (เอกสารไม่หลอก)
- undo/redo ครอบ fold ทุกเส้นทาง รวม `⌥Click`

### API (MCP — เว็บทำ REST รูปเดียวกันได้)

| เรียก | พฤติกรรม |
|---|---|
| `add_child_note(board_id, parent_id, text?, expected_revision)` | server สุ่ม id + วางตำแหน่งเองตามกฎ (ขวาของพ่อ ซ้อนใต้ลูกตัวสุดท้าย) คืนบอร์ดใหม่ ลูกค้าไม่ต้องคิดพิกัด |
| `set_note_parent(board_id, note_id, parent_id\|null, expected_revision)` | ย้ายที่/ปลด (`null`) — reject self-parent และ ancestor-target พร้อมเหตุผล |
| `tidy_tree_layout(board_id, root_id?, expected_revision)` | จัดผังต่อ tree หรือทั้งกระดาน |
| `get_board_context` | ต่อโน้ตมี `parent_note_id`, `child_note_ids`, `collapsed` — fold แล้วยังลิสต์ครบทุกโน้ต |
| `edit_board` (note op) | รับ `parentID` / `collapsed` โดยตรง (`null` = เคลียร์) |

- ทุก write ผ่าน CAS (`expected_revision`) และ undo ครอบทุก operation
- **Gotcha ที่ต้องทำ:** generic edit ops ต้อง reject คีย์สะกดผิด (`parent_id`/`parentId`) พร้อมบอกว่าคีย์ที่ถูกคือ `parentID` — parser ส่วนใหญ่เมินคีย์แปลกแบบเงียบๆ ทำให้ client ได้โน้ตไม่มีพ่อโดยไม่รู้ตัว

## ลำดับงานแนะนำสำหรับทีมเว็บ

1. โมเดล + API ก่อน ทดสอบแบบ literal (พิกัดเป็นตัวเลขตรงตัว, ข้อความ error ตรงข้อความ) — งานโมเดลสั้น (ฝั่งแมค ~130 บรรทัด) ผ่านเร็ว
2. เส้น tree + ป้ายแคปซูล (แสดงผล derived จาก parentID)
3. Interaction ให้ครบ: ⇧Tab/Tab/Return routing, ⇧Click subtree-select, ⌥Click fold, drag-with-subtree (compose กับ group), tidy
4. Fold สุดท้าย เพราะต้องแตะทุก surface (canvas, minimap, marquee, group, scroll bounds, capture/PDF) — ใช้นิยาม visibility นิยามเดียวกันทุกจุด

## สถานะ

- macOS: **ship แล้ว** (ใช้งานจริง, ทดสอบครบ, เอกสาร README + board-skill prompt อัปเดตแล้ว)
- ชื่อ tool เดียวกัน (`add_child_note`, `set_note_parent`, `tidy_tree_layout`) เปิดใช้แล้วทั้ง local MCP และ CoThink Cloud
- เว็บ: ยังไม่มี — เอกสารนี้ + spec zip คือจุดเริ่มงาน
