import json, os, subprocess, tempfile
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
_,extra=call(90,'create_board',{'title':'Delete check'})
r,e=call(91,'delete_board',{'board_id':extra['id'],'expected_revision':1});assert r['isError'] and 'changed' in e.lower(),e
_,deleted=call(92,'delete_board',{'board_id':extra['id'],'expected_revision':0});assert deleted['deleted']
p.stdin.close();p.wait(timeout=5);assert p.returncode==0,p.stderr.read()
env['COTHINK_MCP_READ_ONLY']='1'
p=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
r,e=call(10,'create_board',{'title':'forbidden'});assert r['isError'] and 'read-only' in e
_,lists=call(12,'list_board_lists',{});assert lists[0]['title']=='Research'
r,e=call(13,'delete_board_list',{'list_id':lists[0]['id'],'expected_revision':lists[0]['revision']});assert r['isError'] and 'read-only' in e
_,b=call(11,'get_board',{'board_id':b['id']});assert len(b['notes'])==1
p.stdin.close();p.wait(timeout=5);assert p.returncode==0
temporary_home.cleanup()
print('PASS initialize, list, create, atomic edit, conflicts, cascade, undo, redo, delete, history, import, replace, readonly, persistence')
