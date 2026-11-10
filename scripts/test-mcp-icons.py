import base64, json, os, subprocess, tempfile
from pathlib import Path

binary = os.environ.get("COTHINK_MCP_BIN", str(Path(__file__).resolve().parent.parent / ".build/debug/cothink-mcp"))
temporary_home = tempfile.TemporaryDirectory(prefix="cothink-mcp-icon-test-")
home = temporary_home.name
env={**os.environ,"COTHINK_HOME":home}
p=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
def req(n, method, params=None):
 p.stdin.write(json.dumps({"jsonrpc":"2.0","id":n,"method":method,"params":params or {}})+"\n");p.stdin.flush()
 response=json.loads(p.stdout.readline()); assert response["id"]==n,response;return response["result"]
def call(n,name,args):
 result=req(n,"tools/call",{"name":name,"arguments":args});return result,json.loads(result["content"][0]["text"]) if not result.get("isError") else result["content"][0]["text"]
req(1,"initialize",{"protocolVersion":"2025-11-25"})

icons_tool=[t for t in req(2,"tools/list")["tools"] if t["name"]=="edit_board"][0]
assert "cloud, database, compute, network, users" in icons_tool["description"],icons_tool["description"]

_,ib=call(3,"create_board",{"title":"Icons"})
_,ir=call(4,"e"+"dit_board",{"board_id":ib["id"],"expected_revision":0,"operations":[
 {"action":"add","collection":"notes","item":{"id":"db","text":"Primary DB","x":0,"y":0,"width":160,"height":120,"color":"#F3F1EC","icon":"database"}},
 {"action":"add","collection":"notes","item":{"id":"api","text":"","x":200,"y":0,"width":160,"height":120,"color":"#F3F1EC","icon":"network"}},
 {"action":"add","collection":"connections","item":{"id":"edge","from":"db","to":"api","arrow":True,"direction":"twoWay"}}]})
assert [n for n in ir["notes"] if n["id"]=="db"][0]["icon"]=="database",ir
_,icx=call(5,"get_board_context",{"board_id":ib["id"]})
assert [n for n in icx["notes"] if n["id"]=="db"][0]["icon"]=="database",icx
r,e=call(6,"edit_board",{"board_id":ib["id"],"expected_revision":1,"operations":[{"action":"update","collection":"notes","id":"db","fields":{"icon":"rocket"}}]})
assert r["isError"] and "Invalid icon" in e,e
_,irc=call(7,"edit_board",{"board_id":ib["id"],"expected_revision":1,"operations":[{"action":"update","collection":"notes","id":"db","fields":{"icon":None}}]})
assert [n for n in irc["notes"] if n["id"]=="db"][0].get("icon") is None,irc
r,e=call(8,"edit_board",{"board_id":ib["id"],"expected_revision":2,"operations":[{"action":"add","collection":"connections","item":{"id":"bad","from":"db","to":"api","arrow":True,"icon":"cloud"}}]})
assert r["isError"] and "icon" in e,e
cap,icapmeta=call(9,"capture_board",{"board_id":ib["id"]})
assert not cap.get("isError") and icapmeta["revision"]==2,(cap,icapmeta)
print("ICON-E2E-OK")
p.stdin.close();p.wait(timeout=5);assert p.returncode==0
temporary_home.cleanup()
