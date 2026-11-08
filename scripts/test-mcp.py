import base64, json, os, shutil, struct, subprocess, tempfile
from pathlib import Path

binary = os.environ.get('COTHINK_MCP_BIN', str(Path(__file__).resolve().parent.parent / '.build/debug/cothink-mcp'))
temporary_home = tempfile.TemporaryDirectory(prefix='cothink-mcp-test-')
home = temporary_home.name
env={**os.environ,'COTHINK_HOME':home,'DYLD_LIBRARY_PATH':os.environ.get('DYLD_LIBRARY_PATH', '')}
p=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
def req(n, method, params=None):
 p.stdin.write(json.dumps({'jsonrpc':'2.0','id':n,'method':method,'params':params or {}})+'\n');p.stdin.flush()
 response=json.loads(p.stdout.readline()); assert response['id']==n,response;return response['result']
def call(n,name,args):
 result=req(n,'tools/call',{'name':name,'arguments':args});return result,json.loads(result['content'][0]['text']) if not result.get('isError') else result['content'][0]['text']
assert req(1,'initialize',{'protocolVersion':'2025-11-25'})['protocolVersion']=='2025-11-25'
assert 'unlock_note' in [tool['name'] for tool in req(2,'tools/list')['tools']]
_,b=call(3,'create_board',{'title':'Smoke'})
_,b2=call(4,'edit_board',{'board_id':b['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'a','text':'Hello','x':0,'y':0,'width':100,'height':60,'color':'#ffffff','fontSize':24}},{'action':'add','collection':'notes','item':{'id':'b','text':'World','x':200,'y':0,'width':100,'height':60,'color':'#ffffff'}},{'action':'add','collection':'connections','item':{'id':'e','from':'a','to':'b','arrow':True,'route':'custom','routePoints':[{'x':150,'y':200}],'fontSize':18}}]})
assert b2['revision']==1 and len(b2['connections'])==1
capture,meta=call(150,'capture_board',{'board_id':b['id']})
assert not capture.get('isError') and meta['revision']==1 and meta['board_id']==b['id']
assert capture['content'][1]['type']=='image' and capture['content'][1]['mimeType']=='image/png'
png=base64.b64decode(capture['content'][1]['data'],validate=True)
assert png.startswith(b'\x89PNG\r\n\x1a\n') and struct.unpack('>II',png[16:24])==(meta['width'],meta['height'])
assert meta['board_bounds']['width'] >= 300 and meta['board_bounds']['height'] >= 200

_,route_context=call(105,'get_board_context',{'board_id':b['id']});assert route_context['connections'][0]['route']=='custom' and route_context['connections'][0]['routePoints'][0]['y']==200 and route_context['notes'][0]['fontSize']==24
r,e=call(5,'edit_board',{'board_id':b['id'],'expected_revision':0,'operations':[{'action':'rename','title':'stale'}]});assert r['isError'] and 'conflict' in e.lower(),e
_,b3=call(6,'edit_board',{'board_id':b['id'],'expected_revision':1,'operations':[{'action':'delete','collection':'notes','id':'a'}]});assert len(b3['notes'])==1 and not b3['connections']
r,e=call(60,'undo',{'board_id':b['id'],'expected_revision':1});assert r['isError'] and 'changed' in e.lower(),e
_,b4=call(7,'undo',{'board_id':b['id'],'expected_revision':2});assert len(b4['notes'])==2 and len(b4['connections'])==1
_,b5=call(8,'redo',{'board_id':b['id'],'expected_revision':3});assert len(b5['notes'])==1
_,hist=call(9,'board_history',{'board_id':b['id']});assert len(hist)==5
_,copy=call(80,'import_board',{'board':b5});assert copy['id']!=b5['id'] and copy['notes']==b5['notes']
copy['title']='Renamed copy'
_,copy=call(81,'replace_board',{'board':copy,'expected_revision':0});assert copy['title']=='Renamed copy' and copy['revision']==1
_,copy=call(83,'edit_board',{'board_id':copy['id'],'expected_revision':1,'operations':[{'action':'update','collection':'notes','id':'b','fields':{'strokeColor':'#FF0000','strokeWidth':3,'strokeStyle':'dashed'}}]});assert copy['notes'][0]['strokeStyle']=='dashed' and copy['notes'][0]['strokeWidth']==3
_,copy=call(84,'edit_board',{'board_id':copy['id'],'expected_revision':2,'operations':[{'action':'add','collection':'groups','item':{'id':'g','title':'Group','x':0,'y':0,'width':300,'height':200,'color':'#ffffff','memberIDs':['b']}}]})
_,copy=call(85,'edit_board',{'board_id':copy['id'],'expected_revision':3,'operations':[{'action':'update','collection':'groups','id':'g','fields':{'x':50,'y':30}}]});assert copy['notes'][0]['x']==250 and copy['notes'][0]['y']==30
_,copy=call(87,'edit_board',{'board_id':copy['id'],'expected_revision':4,'operations':[{'action':'update','collection':'notes','id':'b','fields':{'x':280,'y':50}}]});assert copy['groups'][0]['x']==80 and copy['groups'][0]['y']==50 and copy['notes'][0]['x']==280
_,copy=call(88,'unlock_note',{'board_id':copy['id'],'note_id':'b','expected_revision':5});assert copy['groups'][0]['memberIDs']==[]
_,copy=call(89,'edit_board',{'board_id':copy['id'],'expected_revision':6,'operations':[{'action':'update','collection':'notes','id':'b','fields':{'x':320}}]});assert copy['notes'][0]['x']==320 and copy['groups'][0]['x']==80
_,copy=call(86,'edit_board',{'board_id':copy['id'],'expected_revision':7,'operations':[{'action':'delete','collection':'notes','id':'b'}]});assert copy['groups'][0]['memberIDs']==[]
r,e=call(82,'replace_board',{'board':copy,'expected_revision':0});assert r['isError'] and 'changed' in e.lower(),e
_,lst=call(100,'create_board_list',{'title':'Research'})
lst.update(description='Research context',boardIDs=[b['id']],tags=['planning'],flagged=True,color='#669AD2')
_,lst=call(101,'update_board_list',{'list':lst,'expected_revision':0})
_,ctx=call(102,'get_board_context',{'board_id':b['id']});assert ctx['lists'][0]['description']=='Research context'
r,e=call(103,'update_board_list',{'list':lst,'expected_revision':0});assert r['isError'] and 'changed' in e.lower()
_,lists=call(104,'list_board_lists',{});assert lists[0]['boardIDs']==[b['id']]
_,far=call(152,'create_board',{'title':'Off-screen overview'})
_,far=call(153,'edit_board',{'board_id':far['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'far','text':'Far away','x':9500,'y':6000,'width':200,'height':100,'color':'#00FF00'}}]})
far_image,far_meta=call(154,'capture_board',{'board_id':far['id']});assert not far_image.get('isError') and far_meta['board_bounds']['width']>=9700 and far_meta['board_bounds']['height']>=6100
r,e=call(155,'capture_board',{'board_id':'missing'});assert r['isError']
_,extra=call(90,'create_board',{'title':'Delete check'})
_,lockboard=call(110,'create_board',{'title':'Lock check'})
_,lockboard=call(111,'edit_board',{'board_id':lockboard['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'n','text':'Note','x':20,'y':30,'width':100,'height':60,'color':'#ffffff'}},{'action':'add','collection':'groups','item':{'id':'g','title':'Group','x':0,'y':0,'width':300,'height':200,'color':'#ffffff'}}]})
_,locked=call(112,'lock_note',{'board_id':lockboard['id'],'note_id':'n','group_id':'g','expected_revision':1});assert locked['groups'][0]['memberIDs']==['n'] and locked['notes'][0]['x']==20
r,e=call(113,'lock_note',{'board_id':lockboard['id'],'note_id':'n','group_id':'g','expected_revision':1});assert r['isError']
_,unlocked=call(114,'unlock_note',{'board_id':lockboard['id'],'note_id':'n','expected_revision':2});assert unlocked['groups'][0]['memberIDs']==[]
_,wallboard=call(120,'create_board',{'title':'Wallpaper check'})
_,wallboard=call(121,'set_board_wallpaper',{'board_id':wallboard['id'],'expected_revision':0,'color':'#DDEEFF'});assert wallboard['wallpaperColor']=='#DDEEFF'
_,wallboard=call(122,'add_project_file',{'board_id':wallboard['id'],'expected_revision':1,'source_path':str(Path(__file__).resolve().parent.parent/'Assets/Mascot.png')});wall_asset=wallboard['assets'][0]['id']
_,wallboard=call(123,'set_board_wallpaper',{'board_id':wallboard['id'],'expected_revision':2,'asset_id':wall_asset,'opacity':0.5});assert wallboard['wallpaperAssetID']==wall_asset
_,wall_context=call(124,'get_board_context',{'board_id':wallboard['id']});assert wall_context['wallpaper']['asset_id']==wall_asset and wall_context['wallpaper']['opacity']==0.5
r,e=call(125,'set_board_wallpaper',{'board_id':wallboard['id'],'expected_revision':3,'opacity':2});assert r['isError']
_,wallboard=call(126,'edit_board',{'board_id':wallboard['id'],'expected_revision':3,'operations':[{'action':'delete','collection':'assets','id':wall_asset}]});assert 'wallpaperAssetID' not in wallboard
_,wallboard=call(127,'undo',{'board_id':wallboard['id'],'expected_revision':4});assert wallboard['wallpaperAssetID']==wall_asset
r,e=call(91,'delete_board',{'board_id':extra['id'],'expected_revision':1});assert r['isError'] and 'changed' in e.lower(),e
_,deleted=call(92,'delete_board',{'board_id':extra['id'],'expected_revision':0});assert deleted['deleted']
if os.environ.get('COTHINK_TEST_PDF') == '1':
 for i,template in enumerate(('editorial','studio','minimal')):
  pdf_path=os.path.join(home,f'agent-{template}.pdf')
  pdf_args={'board_id':b5['id'],'expected_revision':b5['revision'],'destination_path':pdf_path,'template':template}
  _,pdf=call(115+i,'export_board_pdf',pdf_args);assert pdf['path']==pdf_path and pdf['template']==template and Path(pdf_path).read_bytes().startswith(b'%PDF-')
 r,e=call(116,'export_board_pdf',pdf_args);assert r['isError'] and 'exists' in e.lower()
 r,e=call(117,'export_board_pdf',{**pdf_args,'expected_revision':0,'overwrite':True});assert r['isError'] and 'changed' in e.lower()
 _,pdf=call(118,'export_board_pdf',{**pdf_args,'overwrite':True});assert pdf['path']==pdf_path and Path(pdf_path).read_bytes().startswith(b'%PDF-')
 wallpaper_pdf=os.path.join(home,'wallpaper.pdf')
 _,pdf=call(128,'export_board_pdf',{'board_id':wallboard['id'],'expected_revision':wallboard['revision'],'destination_path':wallpaper_pdf,'template':'minimal'})
 assert Path(wallpaper_pdf).read_bytes().startswith(b'%PDF-')
 if shutil.which('pdfimages'):
  image_report=subprocess.check_output(['pdfimages','-list',wallpaper_pdf],text=True)
  assert any(len(row.split())>2 and row.split()[2]=='image' for row in image_report.splitlines()),image_report
mindnames=[t['name'] for t in req(200,'tools/list')['tools']]
assert {'add_child_note','set_note_parent','tidy_tree_layout'} <= set(mindnames),mindnames
_,treeboard=call(201,'create_board',{'title':'Mindmap'})
_,treeboard=call(202,'edit_board',{'board_id':treeboard['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'a','text':'Root','x':0,'y':0,'width':100,'height':60,'color':'#ffffff'}}]})
assert treeboard['revision']==1
r,c1board=call(203,'add_child_note',{'board_id':treeboard['id'],'parent_id':'a','text':'First child','expected_revision':1})
assert not r.get('isError')
c1=[n for n in c1board['notes'] if n.get('parentID')=='a'][0]
assert c1board['revision']==2 and c1['x']==160 and c1['y']==0 and c1['width']==200 and c1['height']==100 and c1['text']=='First child'
_,treeread=call(204,'get_board',{'board_id':treeboard['id']});assert [n for n in treeread['notes'] if n['id']==c1['id']][0].get('parentID')=='a'
_,treecontext=call(205,'get_board_context',{'board_id':treeboard['id']})
assert [n for n in treecontext['notes'] if n['id']=='a'][0]['child_note_ids']==[c1['id']]
assert [n for n in treecontext['notes'] if n['id']==c1['id']][0]['parent_note_id']=='a'
r,e=call(206,'add_child_note',{'board_id':treeboard['id'],'parent_id':'a','expected_revision':1});assert r['isError'] and 'conflict' in e.lower(),e
r,e=call(207,'add_child_note',{'board_id':treeboard['id'],'parent_id':'zzz','expected_revision':2});assert r['isError'] and 'not found' in e.lower(),e
_,c2board=call(208,'add_child_note',{'board_id':treeboard['id'],'parent_id':'a','text':'Second child','expected_revision':2})
c2=[n for n in c2board['notes'] if n.get('parentID')=='a' and n['id']!=c1['id']][0]
assert c2board['revision']==3 and c2['x']==160 and c2['y']==124
r,detached=call(209,'set_note_parent',{'board_id':treeboard['id'],'note_id':c2['id'],'parent_id':None,'expected_revision':3})
assert detached['revision']==4 and [n for n in detached['notes'] if n['id']==c2['id']][0].get('parentID') is None
r,reattached=call(210,'set_note_parent',{'board_id':treeboard['id'],'note_id':c2['id'],'parent_id':c1['id'],'expected_revision':4})
assert reattached['revision']==5 and [n for n in reattached['notes'] if n['id']==c2['id']][0].get('parentID')==c1['id']
_,deepcontext=call(211,'get_board_context',{'board_id':treeboard['id']})
assert [n for n in deepcontext['notes'] if n['id']=='a'][0]['child_note_ids']==[c1['id']]
assert [n for n in deepcontext['notes'] if n['id']==c1['id']][0]['child_note_ids']==[c2['id']]
assert [n for n in deepcontext['notes'] if n['id']==c2['id']][0]['parent_note_id']==c1['id']
r,e=call(212,'set_note_parent',{'board_id':treeboard['id'],'note_id':'a','parent_id':c2['id'],'expected_revision':5});assert r['isError'] and 'cycle' in e.lower(),e
_,still=call(213,'get_board',{'board_id':treeboard['id']});assert still['revision']==5
r,e=call(214,'set_note_parent',{'board_id':treeboard['id'],'note_id':c2['id'],'parent_id':c1['id'],'expected_revision':4});assert r['isError'] and 'conflict' in e.lower(),e
_,withd=call(220,'edit_board',{'board_id':treeboard['id'],'expected_revision':5,'operations':[{'action':'add','collection':'notes','item':{'id':'d','text':'Via edit','x':400,'y':0,'width':100,'height':60,'color':'#ffffff','parentID':'a'}}]})
assert withd['revision']==6 and [n for n in withd['notes'] if n['id']=='d'][0].get('parentID')=='a'
_,cleared=call(221,'edit_board',{'board_id':treeboard['id'],'expected_revision':6,'operations':[{'action':'update','collection':'notes','id':'d','fields':{'parentID':None}}]})
assert cleared['revision']==7 and [n for n in cleared['notes'] if n['id']=='d'][0].get('parentID') is None
r,e=call(222,'edit_board',{'board_id':treeboard['id'],'expected_revision':7,'operations':[{'action':'add','collection':'notes','item':{'id':'d2','text':'x','x':0,'y':0,'width':10,'height':10,'color':'#ffffff','parent_id':'a'}}]});assert r['isError'] and 'parentID' in e,e
r,e=call(223,'edit_board',{'board_id':treeboard['id'],'expected_revision':7,'operations':[{'action':'update','collection':'notes','id':'d','fields':{'parentId':'a'}}]});assert r['isError'] and 'parentID' in e,e
_,unchanged=call(224,'get_board',{'board_id':treeboard['id']});assert unchanged['revision']==7
_,casc=call(230,'create_board',{'title':'Cascade'})
_,casc=call(231,'edit_board',{'board_id':casc['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'gp','text':'Grand','x':0,'y':0,'width':100,'height':60,'color':'#ffffff'}},{'action':'add','collection':'notes','item':{'id':'p','text':'Parent','x':160,'y':0,'width':100,'height':60,'color':'#ffffff','parentID':'gp'}},{'action':'add','collection':'notes','item':{'id':'k','text':'Kid','x':320,'y':0,'width':100,'height':60,'color':'#ffffff','parentID':'p'}},{'action':'add','collection':'connections','item':{'id':'e','from':'p','to':'k','arrow':True}},{'action':'add','collection':'groups','item':{'id':'gg','title':'G','x':0,'y':0,'width':300,'height':200,'color':'#ffffff','memberIDs':['p','k']}}]})
assert casc['revision']==1
_,promoted=call(232,'edit_board',{'board_id':casc['id'],'expected_revision':1,'operations':[{'action':'delete','collection':'notes','id':'p'}]})
assert promoted['revision']==2
kid=[n for n in promoted['notes'] if n['id']=='k'][0]
assert len(promoted['notes'])==2 and kid.get('parentID')=='gp' and not promoted['connections'] and promoted['groups'][0]['memberIDs']==['k']
_,tidyboard=call(240,'create_board',{'title':'Tidy'})
_,tidyboard=call(241,'edit_board',{'board_id':tidyboard['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'r','text':'Root','x':100,'y':200,'width':100,'height':60,'color':'#ffffff'}},{'action':'add','collection':'notes','item':{'id':'k1','text':'One','x':0,'y':1000,'width':100,'height':60,'color':'#ffffff','parentID':'r'}},{'action':'add','collection':'notes','item':{'id':'k2','text':'Two','x':0,'y':500,'width':100,'height':60,'color':'#ffffff','parentID':'r'}}]})
assert tidyboard['revision']==1
_,tidied=call(242,'tidy_tree_layout',{'board_id':tidyboard['id'],'root_id':'r','expected_revision':1})
assert tidied['revision']==2
pos={n['id']:(n['x'],n['y']) for n in tidied['notes']}
assert pos['r']==(100,200) and pos['k2']==(260,158) and pos['k1']==(260,242),pos
_,tidied2=call(243,'tidy_tree_layout',{'board_id':tidyboard['id'],'root_id':'r','expected_revision':2})
assert {n['id']:(n['x'],n['y']) for n in tidied2['notes']}==pos
r,e=call(244,'tidy_tree_layout',{'board_id':tidyboard['id'],'expected_revision':1});assert r['isError'] and 'conflict' in e.lower(),e
r,e=call(245,'tidy_tree_layout',{'board_id':tidyboard['id'],'root_id':'zzz','expected_revision':3});assert r['isError'] and 'not found' in e.lower(),e
capture,meta=call(246,'capture_board',{'board_id':tidyboard['id']});assert not capture.get('isError') and meta['revision']==3 and capture['content'][1]['type']=='image'
_,fb=call(247,'edit_board',{'board_id':tidyboard['id'],'expected_revision':3,'operations':[{'action':'update','collection':'notes','id':'r','fields':{'collapsed':True}}]})
assert fb['revision']==4
_,fc=call(248,'get_board_context',{'board_id':tidyboard['id']})
rn=[n for n in fc['notes'] if n['id']=='r'][0]
assert rn['collapsed'] is True and rn['child_note_ids'],rn
_,fb=call(249,'edit_board',{'board_id':tidyboard['id'],'expected_revision':4,'operations':[{'action':'update','collection':'notes','id':'r','fields':{'collapsed':None}}]})
assert fb['revision']==5
_,fd=call(250,'get_board_context',{'board_id':tidyboard['id']})
rn=[n for n in fd['notes'] if n['id']=='r'][0]
assert rn['collapsed'] is False,rn
shapes=[t for t in req(290,'tools/list')['tools'] if t['name']=='edit_board'][0]
assert 'lineFlipped' in shapes['description'] and 'text' in shapes['description'],shapes['description']
_,sh=call(300,'create_board',{'title':'Shapes'})
_,sh=call(301,'edit_board',{'board_id':sh['id'],'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'ln','text':'','x':0,'y':0,'width':120,'height':0,'color':'#F3F1EC','shape':'line'}},{'action':'add','collection':'notes','item':{'id':'ln2','text':'','x':200,'y':0,'width':120,'height':0,'color':'#F3F1EC','shape':'line','lineFlipped':True}}]})
assert sh['revision']==1 and [n for n in sh['notes'] if n['id']=='ln'][0]['shape']=='line' and [n for n in sh['notes'] if n['id']=='ln2'][0]['lineFlipped'] is True,sh
_,shc=call(302,'get_board_context',{'board_id':sh['id']})
ln=[n for n in shc['notes'] if n['id']=='ln'][0]; ln2=[n for n in shc['notes'] if n['id']=='ln2'][0]
assert ln['shape']=='line' and 'lineFlipped' not in ln,ln
assert ln2['shape']=='line' and ln2['lineFlipped'] is True,ln2
_,sh=call(303,'edit_board',{'board_id':sh['id'],'expected_revision':1,'operations':[{'action':'add','collection':'notes','item':{'id':'rc','text':'','x':400,'y':0,'width':120,'height':60,'color':'#F3F1EC','shape':'rectangle'}},{'action':'add','collection':'connections','item':{'id':'e','from':'ln','to':'ln2','arrow':True}},{'action':'add','collection':'groups','item':{'id':'g','title':'G','x':0,'y':0,'width':600,'height':200,'color':'#ffffff'}}]})
assert sh['revision']==2 and [n for n in sh['notes'] if n['id']=='rc'][0]['shape']=='rectangle',sh
r,e=call(304,'edit_board',{'board_id':sh['id'],'expected_revision':2,'operations':[{'action':'update','collection':'notes','id':'ln','fields':{'shape':'box'}}]});assert r['isError'] and 'diamond' in e and sh['revision']==2,(e,sh['revision'])
r,e=call(305,'edit_board',{'board_id':sh['id'],'expected_revision':2,'operations':[{'action':'add','collection':'notes','item':{'id':'x1','text':'','x':0,'y':0,'width':10,'height':10,'color':'#fff','shape':'circle'}}]});assert r['isError'] and 'rectangle' in e,(e)
r,e=call(306,'edit_board',{'board_id':sh['id'],'expected_revision':2,'operations':[{'action':'update','collection':'notes','id':'ln','fields':{'lineFlipped':'yes'}}]});assert r['isError'] and 'lineFlipped' in e,e
r,e=call(307,'edit_board',{'board_id':sh['id'],'expected_revision':2,'operations':[{'action':'update','collection':'connections','id':'e','fields':{'shape':'rectangle'}}]});assert r['isError'] and 'notes' in e,e
r,e=call(308,'edit_board',{'board_id':sh['id'],'expected_revision':2,'operations':[{'action':'add','collection':'notes','item':{'id':'x2','text':'','x':0,'y':0,'width':80,'height':0,'color':'#fff'}}]});assert r['isError'],e
_,sh=call(309,'edit_board',{'board_id':sh['id'],'expected_revision':2,'operations':[{'action':'update','collection':'notes','id':'ln2','fields':{'lineFlipped':None}}]})
assert sh['revision']==3 and [n for n in sh['notes'] if n['id']=='ln2'][0].get('lineFlipped') is None,sh
_,shc=call(310,'get_board_context',{'board_id':sh['id']})
assert [n for n in shc['notes'] if n['id']=='ln2'][0].get('lineFlipped') is None,shc
r,e=call(311,'edit_board',{'board_id':sh['id'],'expected_revision':3,'operations':[{'action':'update','collection':'groups','id':'g','fields':{'shape':'rectangle'}}]});assert r['isError'] and 'notes' in e,e
p.stdin.close();p.wait(timeout=5);assert p.returncode==0,p.stderr.read()
env['COTHINK_MCP_READ_ONLY']='1'
p=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
r,e=call(10,'create_board',{'title':'forbidden'});assert r['isError'] and 'read-only' in e
_,lists=call(12,'list_board_lists',{});assert lists[0]['title']=='Research'
r,e=call(13,'delete_board_list',{'list_id':lists[0]['id'],'expected_revision':lists[0]['revision']});assert r['isError'] and 'read-only' in e
r,e=call(15,'set_board_wallpaper',{'board_id':wallboard['id'],'expected_revision':wallboard['revision'],'color':'#000000'});assert r['isError'] and 'read-only' in e
r,e=call(250,'add_child_note',{'board_id':tidyboard['id'],'parent_id':'r','expected_revision':0});assert r['isError'] and 'read-only' in e
r,e=call(251,'set_note_parent',{'board_id':tidyboard['id'],'note_id':'k2','parent_id':None,'expected_revision':0});assert r['isError'] and 'read-only' in e
r,e=call(252,'tidy_tree_layout',{'board_id':tidyboard['id'],'expected_revision':0});assert r['isError'] and 'read-only' in e
if os.environ.get('COTHINK_TEST_PDF') == '1':
 r,e=call(14,'export_board_pdf',pdf_args);assert r['isError'] and 'read-only' in e
_,b=call(11,'get_board',{'board_id':b['id']});assert len(b['notes'])==1
capture,meta=call(151,'capture_board',{'board_id':b['id']});assert not capture.get('isError') and meta['revision']==b['revision'] and capture['content'][1]['type']=='image'
p.stdin.close();p.wait(timeout=5);assert p.returncode==0
temporary_home.cleanup()
print('PASS initialize, list, create, atomic edit, conflicts, cascade, undo, redo, delete, history, import, replace, readonly, persistence, mindmap tree, shapes')
