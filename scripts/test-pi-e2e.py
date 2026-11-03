import http.server,threading,subprocess,json,tempfile,os
from pathlib import Path
root=str(Path(__file__).resolve().parent.parent)
pi=os.environ.get('PI_BIN')
if not pi:
 raise SystemExit('Set PI_BIN to the Pi 0.73.1 executable before running this test')
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));requests.append(body)
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  if len(requests)==1:
   names=[t['function']['name'] for t in body.get('tools',[])];assert 'cothink_edit_board' in names,names
   delta={'role':'assistant','tool_calls':[{'index':0,'id':'call1','type':'function','function':{'name':'cothink_edit_board','arguments':json.dumps({'expected_revision':0,'operations':[{'action':'add','collection':'notes','item':{'id':'pi-e2e-note','text':'Created by Pi','x':100,'y':100,'width':200,'height':100,'color':'#FFF1AF'}}]})}}]};finish='tool_calls'
  else:
   delta={'role':'assistant','content':'Board inspected successfully'};finish='stop'
  def send(d,f):
   x={'id':'mock','object':'chat.completion.chunk','created':1,'model':'test','choices':[{'index':0,'delta':d,'finish_reason':f}]};self.wfile.write(('data: '+json.dumps(x)+'\n\n').encode())
  send(delta,None);send({},finish);self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
 def log_message(self,*args):pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='cothink-pi-e2e-') as tmp:
 env={**os.environ,'PI_CODING_AGENT_DIR':tmp,'COTHINK_HOME':tmp+'/home','COTHINK_MCP_PATH':root+'/.build/debug/cothink-mcp'}
 m=subprocess.Popen([env['COTHINK_MCP_PATH']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
 m.stdin.write(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'create_board','arguments':{'title':'Isolated E2E'}}})+'\n');m.stdin.flush();board=json.loads(json.loads(m.stdout.readline())['result']['content'][0]['text']);m.stdin.close();m.wait()
 env['COTHINK_PI_BOARD_ID']=board['id']
 json.dump({'providers':{'mock':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'testing','models':[{'id':'test','input':['text'],'contextWindow':8192,'maxTokens':1024}]}}},open(tmp+'/models.json','w'))
 command=[pi,'--mode','rpc','--no-session','--no-extensions','--no-skills','--no-prompt-templates','--no-context-files','--offline','--provider','mock','--model','test','--no-builtin-tools','--extension',root+'/Assets/CoThinkPiExtension.ts']
 p=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env,bufsize=1)
 p.stdin.write(json.dumps({'id':'1','type':'prompt','message':'Inspect board'})+'\n');p.stdin.flush();events=[]
 for line in p.stdout:
  event=json.loads(line);events.append(event)
  if event.get('type')=='agent_end':break
 p.stdin.close();p.wait(timeout=10);err=p.stderr.read()
 print('exit',p.returncode,'stderr',err[:1000]); print('events',[(e.get('type'),e.get('toolName'),e.get('isError')) for e in events if e.get('type') in ('tool_execution_start','tool_execution_end','agent_end')]);print('model_calls',len(requests))
 assert p.returncode==0 and 'COTHINK_MCP_READY' in err and len(requests)==2
 assert any(e.get('type')=='tool_execution_end' and e.get('toolName')=='cothink_edit_board' and not e.get('isError') for e in events)
 assert any('Created by Pi' in json.dumps(m) for m in requests[1]['messages'] if m.get('role')=='tool')
 verify=subprocess.Popen([env['COTHINK_MCP_PATH']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
 verify.stdin.write(json.dumps({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'get_board','arguments':{'board_id':board['id']}}})+'\n');verify.stdin.flush()
 updated=json.loads(json.loads(verify.stdout.readline())['result']['content'][0]['text']);verify.stdin.close();verify.wait()
 assert updated['revision']==1 and updated['notes'][0]['text']=='Created by Pi'
 print('PASS real Pi RPC → MCP edit_board → isolated board store → response')
server.shutdown()
