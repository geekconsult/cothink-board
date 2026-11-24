import {createRequire} from 'node:module';
import {join} from 'node:path';
const require = createRequire(join(process.env.COTHINK_TEST_WEB, 'package.json'));
const puppeteer = require('puppeteer-core');
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
const [, , origin, boardID, noteID, file, browserReady] = process.argv;
const browser = await puppeteer.launch({
  executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless:true,
  args:['--no-first-run','--disable-background-networking']
});
try {
  const page = await browser.newPage();
  await page.setViewport({width:1440,height:900});
  const errors=[];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin);
  await page.waitForSelector('.auth-card .brand-version');
  assert.equal(await page.$eval('.brand-version',e=>e.textContent), 'v'+process.env.COTHINK_TEST_VERSION);
  await page.type('[name=email]', process.env.COTHINK_TEST_EMAIL);
  await page.type('[name=password]', process.env.COTHINK_TEST_PASSWORD);
  await page.click('button[type=submit]');
  await page.waitForSelector('.home-page, .home-shell');
  async function checkAccount() {
    await page.click('[aria-label="Account settings"]');
    await page.waitForSelector('dialog[open] .account-actions', {visible:true});
    assert.match(await page.$eval('dialog[open]', dialog=>dialog.textContent), /sync-smoke@example\.test/);
    await page.click('dialog[open] .account-actions button');
    await page.waitForSelector('dialog[open]', {hidden:true});
  }
  await checkAccount();
  const deskBoard = '.home-desk [data-open-board]';
  assert.equal(await page.$eval(deskBoard,e=>e.dataset.openBoard),boardID);
  const initialEdit = await page.$eval('.home-desk time',e=>Date.parse(e.dateTime));
  await page.click('.home-desk [data-desk-toggle]');
  assert.equal(await page.$(deskBoard),null);
  await page.click('.board-card-wrap [data-desk-toggle]');
  assert.equal(await page.$eval('.home-desk time',e=>Date.parse(e.dateTime)),initialEdit);
  assert.equal(await page.$eval('.brand-version',e=>e.textContent), 'v'+process.env.COTHINK_TEST_VERSION);
  assert.equal(await page.$eval('.brandmark',e=>e.complete && e.naturalWidth>0), true);
  assert.equal(await page.$eval('#home-pinned-title', e=>e.textContent), 'Active work');
  assert.equal(await page.$eval('.home-pinned [data-open-board]', e=>e.dataset.openBoard), boardID);
  assert.ok(await page.$eval('.home-pinned', e=>Boolean(e.compareDocumentPosition(document.querySelector('.home-all-heading')) & Node.DOCUMENT_POSITION_FOLLOWING)));
  await page.setViewport({width:390,height:844});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  await page.screenshot({path:process.env.COTHINK_TEST_MOBILE.replace('mobile.png','pinned-home.png')});
  await page.setViewport({width:1440,height:900});
  await page.locator('.home-pinned [data-list-select]').click();
  await page.click('[data-pin-list]');
  await page.click('.home-back');
  assert.equal(await page.$('.home-pinned'), null);
  await page.click('.list-folder[title="Open list Later"]');
  await page.click('[data-pin-list]');
  await page.click('.home-back');
  assert.equal(await page.$eval('#home-pinned-title', e=>e.textContent), 'Later');
  assert.match(await page.$eval('.home-pinned', e=>e.textContent), /No boards in this list yet/);
  await page.waitForFunction(async()=>{
    const data=await (await fetch('/api/workspace',{headers:{'x-cothink-client':'1'}})).json();
    return data.state.lists.find(l=>l.id===data.state.pinnedListID)?.title==='Later';
  });
  await page.goto(origin+'/b/'+boardID);
  const note = `[data-note="${noteID}"]`;
  await page.waitForSelector(note);
  const macImage='.note-asset[aria-label="Open from-mac.png"] img';
  await page.waitForSelector(macImage);
  assert.ok(await page.$eval(macImage, img=>img.complete && img.naturalWidth>0 && img.clientHeight>0));
  await checkAccount();
  assert.match(await page.$eval(note, e=>e.textContent), /Created on Mac/);
  assert.match(await page.$eval('.reminder-box', e=>e.textContent), /Call supplier/);
  assert.match(await page.$eval('.reminder-box', e=>e.textContent), /Check delivery/);
  assert.equal(await page.$$eval('.reminder-box .reminder-entry.complete', nodes => nodes.length), 1);
  assert.equal(await page.$eval('[data-branch=":desk"] [data-board]', e=>e.dataset.board), boardID);
  await page.mouse.move(2,2);
  await page.goto(origin);
  const editorContext = await browser.createBrowserContext();
  const editor = await editorContext.newPage();
  await editor.bringToFront();
  await editor.setViewport({width:1440,height:900});
  await editor.goto(origin + '/b/' + boardID);
  await editor.type('[name=email]', 'shared-editor@example.test');
  await editor.type('[name=password]', process.env.COTHINK_TEST_PASSWORD);
  await editor.click('button[type=submit]');
  await editor.waitForSelector('#board-people');
  async function openPeople() {
    for (let attempt=0;attempt<4;attempt++) {
      await editor.mouse.move(720+attempt,4);
      try {
        await editor.waitForFunction(()=>document.querySelector('#app')?.dataset.chrome!=='hidden',{timeout:600});
        await editor.locator('#board-people').setTimeout(900).click();
        await editor.waitForSelector('.people-dialog[open]',{timeout:600});
        return;
      } catch (error) { if (attempt===3) throw error; }
    }
  }
  const marker = '.object-editors[data-object-id="' + noteID + '"]';
  await editor.waitForSelector(marker);
  assert.equal(await editor.$eval(marker+' img', img=>img.getAttribute('src')), '/avatars/sprout.svg');
  assert.equal(await editor.$eval('#board-people', b=>b.textContent), '2 here');
  await openPeople();
  await editor.waitForSelector('.person-row');
  assert.deepEqual(await editor.$$eval('.person-row small:not(.here-now)', rows=>rows.map(row=>row.textContent)), ['Owner','Can edit']);
  assert.equal(await editor.$eval('.person-row img', img=>img.getAttribute('src')), '/avatars/sprout.svg');
  assert.equal(await editor.$eval('.people-dialog .account-actions',el=>el.textContent), 'Close');
  await editor.click('.people-dialog .account-actions button');
  await editor.click('[aria-label="Account settings"]');
  await editor.click('.avatar-choices [aria-label="Honey"]');
  await editor.waitForFunction(()=>document.querySelector('.avatar-choices [aria-label="Honey"]')?.getAttribute('aria-pressed')==='true');
  await editor.click('dialog[open] .account-actions button');
  const readView=()=>editor.$eval('#canvas',canvas=>{
    const world=canvas.querySelector('.world'), z=world.getBoundingClientRect().width/world.offsetWidth;
    return {x:(canvas.scrollLeft+canvas.clientWidth/2)/z,y:(canvas.scrollTop+canvas.clientHeight/2)/z,
      width:canvas.clientWidth/z,height:canvas.clientHeight/z,zoom:z};
  });
  async function stableView() {
    let view=await readView();
    for (let i=0;i<12;i++) {
      await new Promise(resolve=>setTimeout(resolve,90));
      const next=await readView();
      if (JSON.stringify(view)===JSON.stringify(next)) return next;
      view=next;
    }
    return view;
  }
  const signal=async suffix=>{
    const deadline=Date.now()+10000;
    while(Date.now()<deadline){
      try { await readFile(browserReady+suffix); return; } catch { await new Promise(resolve=>setTimeout(resolve,50)); }
    }
    throw Error('Missing native follow signal '+suffix);
  };
  async function expectView(x,y,z) {
    await editor.waitForFunction((x,y,z)=>{
      const c=document.querySelector('#canvas'), world=c.querySelector('.world');
      const scale=world.getBoundingClientRect().width/world.offsetWidth;
      return Math.abs(scale-z)<0.005 && Math.abs((c.scrollLeft+c.clientWidth/2)/scale-x)<2 &&
        Math.abs((c.scrollTop+c.clientHeight/2)/scale-y)<2;
    },{timeout:9000},x,y,z);
  }
  await writeFile(browserReady+'.start-follow','');
  const prompt='.view-invitation';
  await editor.waitForSelector(prompt+' button');
  const beforeDecline=await stableView();
  assert.match(await editor.$eval(prompt,el=>el.textContent),/sync-smoke@example.test/);
  await editor.click(prompt+' button:nth-of-type(2)');
  await editor.waitForSelector(prompt,{hidden:true});
  assert.deepEqual(await stableView(),beforeDecline);
  await openPeople();
  await editor.waitForSelector('.people-dialog[open]');
  await writeFile(browserReady+'.declined','');
  await editor.waitForSelector(prompt+' button');
  await editor.click(prompt+' button:first-of-type');
  await editor.waitForSelector('.follow-banner');
  await expectView(2650,1820,1.25);
  await writeFile(browserReady+'.pan','');
  await expectView(880,650,1.5);
  await editor.screenshot({path:process.env.COTHINK_TEST_SCREENSHOT.replace('desktop.png','following.png')});
  await writeFile(browserReady+'.end-native','');
  await editor.waitForSelector('.follow-banner',{hidden:true});
  await writeFile(browserReady+'.stopped','');
  await signal('.leader-reset');
  await expectView(880,650,1.5);
  await editor.$eval('#canvas',c=>c.scrollTo(540,410));
  await stableView();
  await openPeople();
  await editor.waitForSelector('.invite-person:not([hidden]):enabled');
  await editor.click('.invite-person:not([hidden]):enabled');
  await editor.click('.people-dialog .account-actions button');
  await writeFile(browserReady+'.web-view-1',JSON.stringify(await stableView()));
  await signal('.mac-view-1');
  await openPeople();
  await editor.waitForFunction(()=>[...document.querySelectorAll('.person-row')].some(row=>row.textContent.includes('sync-smoke@example.test') && row.querySelector('.here-now').textContent==='Following you'),{timeout:5000}).catch(async error=>{
    console.error('Here now:',await editor.$$eval('#board-people,.people-dialog,.follow-banner',nodes=>nodes.map(el=>el.textContent)));
    throw error;
  });
  await editor.click('.people-dialog .account-actions button');
  await editor.click('#zoom-in');
  await editor.$eval('#canvas',c=>c.scrollTo(850,700));
  await writeFile(browserReady+'.web-view-2',JSON.stringify(await stableView()));
  await signal('.mac-view-2');
  await openPeople();
  await editor.waitForSelector('.end-tour:not([hidden]):enabled');
  await editor.click('.end-tour');
  await editor.waitForSelector('.end-tour',{hidden:true});
  await editor.click('.people-dialog .account-actions button');
  await writeFile(browserReady+'.end-web','');
  await signal('.independent');
  await editor.keyboard.down('Meta'); await editor.keyboard.press('0'); await editor.keyboard.up('Meta');
  await editor.click('#zoom-in');
  await editor.$eval('#canvas', el=>el.scrollTo(62,45));
  const atWorldPoint = (x,y) => editor.$eval('.world',(world,{x,y})=>{
    const rect=world.getBoundingClientRect(), scale=rect.width/world.offsetWidth;
    return {x:rect.left+x*scale,y:rect.top+y*scale,scale};
  },{x,y});
  const cursor = '.remote-cursor[data-email="sync-smoke@example.test"]';
  async function expectCursor(x,y) {
    await editor.waitForFunction((selector,x,y)=>{
      const tip=document.querySelector(selector)?.getBoundingClientRect(), world=document.querySelector('.world');
      const bounds=world.getBoundingClientRect(), scale=bounds.width/world.offsetWidth;
      return tip && Math.abs(tip.left-bounds.left-x*scale)<1 && Math.abs(tip.top-bounds.top-y*scale)<1;
    },{timeout:12000},cursor,x,y);
  }
  await expectCursor(150,110);
  assert.equal(await editor.$eval(cursor+' img',img=>img.getAttribute('src')), '/avatars/sprout.svg');
  const target=await atWorldPoint(265,230);
  assert.ok(target.scale>1);
  await editor.mouse.move(target.x,target.y);
  await expectCursor(300,255);
  await editor.screenshot({path:process.env.COTHINK_TEST_SCREENSHOT.replace('desktop.png','shared-cursor.png')});
  await editor.mouse.move(2,2);
  try {
    await editor.waitForSelector(cursor,{hidden:true,timeout:10000});
  } catch (error) {
    console.error('Cursor still on board',await editor.$eval(cursor,node=>node.style.transform));
    throw error;
  }
  assert.equal(await editor.$eval('#board-people', b=>b.textContent), '2 here');
  await editor.click('#zoom-out');
  await editor.click(note);
  await editor.click(note,{clickCount:2});
  await editor.waitForSelector('.inline-note');
  await editor.$eval('.inline-note',input=>input.select());
  await editor.keyboard.type('Edit from shared web account');
  // The native observer clears its own edit after receiving this editor's live target.
  await editor.waitForSelector(marker,{hidden:true,timeout:12000});
  assert.equal(await editor.$eval('.inline-note', field=>field.value),'Edit from shared web account');
  await editor.keyboard.down('Meta');
  await editor.keyboard.press('Enter');
  await editor.keyboard.up('Meta');
  await editor.waitForFunction(async (boardID,noteID)=>{
    const res=await fetch('/api/workspace',{headers:{'x-cothink-client':'1'}});
    const {state}=await res.json();
    return state.boards.find(b=>b.id===boardID)?.notes.find(n=>n.id===noteID)?.text==='Edit from shared web account';
  },{},boardID,noteID);
  await writeFile(browserReady,'ready');
  await editor.waitForFunction(selector=>document.querySelector(selector+' .note-text')?.textContent==='Live edit from Mac',{},note);
  await editor.goto(origin);
  await editor.waitForSelector('.home-page, .home-shell');
  await editorContext.close();
  await page.bringToFront();
  await page.goto(origin+'/b/'+boardID);
  await page.waitForFunction(selector=>document.querySelector(selector+' .note-text')?.textContent==='Live edit from Mac',{},note);
  await page.select('#list-scope', ':unfiled');
  assert.equal(await page.$$('.nav-children [data-board]').then(x=>x.length),0);
  await page.select('#list-scope', '');
  assert.equal(await page.$$('.nav-children [data-board]').then(x=>x.length),3);
  await page.$eval('#list-scope', e=>e.blur());

  const macFile = '.note.file-object [data-open-asset]';
  const tabs = browser.targets().length;
  await page.click(macFile);
  assert.equal(browser.targets().length,tabs,'a single click must select only');
  await page.click(macFile,{clickCount:2});
  const preview = await browser.waitForTarget(t=>t.type()==='page'&&t.url().startsWith('blob:'));
  const previewPage = await preview.page();
  assert.match(await previewPage.$eval('body',e=>e.innerText),/File from Mac/);
  await previewPage.close();
  await page.bringToFront();

  await page.click(note);
  if (!await page.$eval('#inspector-panel',el=>!el.hidden)) await page.click('#toggle-inspector');
  const originalWidth=await page.$eval(note,el=>el.offsetWidth);
  await page.click('#fit-content');
  assert.notEqual(await page.$eval(note,el=>el.offsetWidth),originalWidth);
  assert.ok(await page.$eval(note,el=>{
    const text=el.querySelector('.note-text');
    return text.scrollHeight<=text.clientHeight+1;
  }));
  await page.waitForFunction(()=>document.querySelector('#sync-status-mini')?.dataset.status==='saved');
  const originalX = await page.$eval(note,e=>e.style.left);
  await page.focus(note);
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction((selector,x)=>document.querySelector(selector)?.style.left!==x,{},note,originalX);
  await page.click(note);
  await page.click(note,{clickCount:2});
  await page.waitForSelector('.inline-note');
  await page.$eval('.inline-note',e => {e.select()});
  await page.keyboard.type('Changed in Chrome');
  await page.keyboard.down('Meta');
  await page.keyboard.press('Enter');
  await page.keyboard.up('Meta');
  await page.waitForFunction(selector=>document.querySelector(selector+'.note .note-text')?.textContent==='Changed in Chrome',{},note);

  const content = await readFile(file,'utf8');
  await page.$eval('#canvas',(canvas,value)=>{
    const transfer = new DataTransfer();
    transfer.items.add(new File([value], 'proof-web.txt', {type:'text/plain'}));
    const rect=canvas.getBoundingClientRect();
    canvas.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer,clientX:rect.left+470,clientY:rect.top+310}));
  },content);
  await page.waitForFunction(()=>Array.from(document.querySelectorAll('.note.file-object')).some(node=>node.textContent.includes('proof-web.txt')));
  await page.waitForFunction(()=>document.querySelector('#sync-status-mini')?.dataset.status==='saved');
  await page.click('[data-list-edit]');
  await page.waitForSelector('#list-title', {visible:true});
  await page.$eval('#list-title', input => {
    input.value = 'Work from Chrome';
    input.dispatchEvent(new Event('change', {bubbles:true}));
    input.blur();
  });
  await page.waitForFunction(()=>Array.from(document.querySelectorAll('.nav-title')).some(el=>el.textContent==='Work from Chrome'));
  await page.waitForFunction(()=>document.querySelector('#sync-status-mini')?.dataset.status==='saved');
  await page.screenshot({path:process.env.COTHINK_TEST_SCREENSHOT});
  await page.setViewport({width:390,height:844,isMobile:true,hasTouch:true});
  await page.click('#toggle-sidebar');
  await page.waitForSelector('#boards-panel .nav-branch',{visible:true});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  await page.screenshot({path:process.env.COTHINK_TEST_MOBILE});
  await page.setViewport({width:1440,height:900,isMobile:false,hasTouch:false});
  await page.goto(origin);
  await page.waitForSelector('.home-desk time');
  const latestEdit = await page.$eval('.home-desk time',e=>Date.parse(e.dateTime));
  assert.ok(latestEdit>initialEdit);
  await writeFile(browserReady+'.edited',String(latestEdit));
  await page.click(deskBoard);
  await page.waitForSelector('main header [data-desk-toggle]');
  await page.click('main header [data-desk-toggle]');
  assert.equal(await page.$eval('main header [data-desk-toggle]',el=>el.getAttribute('aria-pressed')),'false');
  for(const pressed of ['true','false']){
    await page.keyboard.down('Meta');
    await page.keyboard.down('Alt');
    await page.keyboard.down('Shift');
    await page.keyboard.press('KeyD');
    await page.keyboard.up('Shift');
    await page.keyboard.up('Alt');
    await page.keyboard.up('Meta');
    assert.equal(await page.$eval('main header [data-desk-toggle]',el=>el.getAttribute('aria-pressed')),pressed);
  }
  await page.waitForFunction(()=>document.querySelector('#sync-status-mini')?.dataset.status==='saved');
  assert.deepEqual(errors,[]);
  console.log('Chrome signed in, verified Mac edits/list/reminder/file, edited the note, and attached a new file.');
} finally {
  await browser.close();
}
