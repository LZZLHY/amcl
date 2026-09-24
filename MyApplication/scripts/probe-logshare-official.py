"""Live public API smoke. Uses synthetic content and never prints deletion tokens or reasoning."""
import json, time, urllib.request, urllib.error
from pathlib import Path
from lib.workspace_paths import workspace_path
BASE = 'https://api.logshare.cn/v1'
steps = []
share = None
def request(path, method='GET', data=None, token=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    body = json.dumps(data).encode() if data is not None else None
    return urllib.request.urlopen(urllib.request.Request(BASE + path, data=body, headers=headers, method=method), timeout=320)
def record(name, ok, detail=''):
    steps.append({'name':name,'ok':ok,'detail':detail}); print(name, ok, detail, flush=True)
try:
    with request('/limits') as response: limits = json.load(response)
    record('limits', True, str(limits))
    marker = 'AMCL public API synthetic probe ' + str(int(time.time()))
    with request('/log','POST',{'content':'[12:00:00] [main/INFO]: Starting minecraft client version 1.21.1\n[12:00:01] [main/INFO]: '+marker+'\n[12:00:02] [main/INFO]: Synthetic verification only; no real failure or user data.', 'source':'amcl/integration-probe'}) as response: share = json.load(response)
    record('upload', share.get('success') is True, 'id='+share.get('id','')+' url='+share.get('url',''))
    with request('/raw/'+share['id']) as response: raw = response.read().decode()
    record('raw round-trip', marker in raw)
    with request('/insights/'+share['id']) as response: insights = json.load(response)
    record('insights', 'analysis' in insights, 'type='+str(insights.get('type','')))
    count = 0; done = False; events = 0
    with request('/ai/'+share['id']) as response:
        record('AI HTTP', response.status == 200, str(response.status))
        event = ''
        for raw_line in response:
            line = raw_line.decode('utf-8').strip()
            if line.startswith('event:'): event = line[6:].strip()
            if line.startswith('data:'):
                payload = line[5:].strip()
                if payload == '[DONE]': done=True; break
                try: data = json.loads(payload)
                except json.JSONDecodeError: continue
                if event == 'done': done = data.get('status') == 'completed'; break
                if event == 'status': events += 1
                else:
                    for choice in data.get('choices',[]): count += len(choice.get('delta',{}).get('content',''))
            if not line: event = ''
    record('AI SSE completed', done and count > 0, 'contentChars='+str(count)+' statusEvents='+str(events))
except Exception as error:
    record('error', False, str(error))
finally:
    if share and share.get('id') and share.get('token'):
        try:
            with request('/log/'+share['id'],'DELETE',token=share['token']) as response: result=json.load(response)
            record('cleanup', result.get('success') is True)
        except Exception as error: record('cleanup',False,str(error))
    # 在线探针结果属于这次执行，不再追加到日期写死的历史诊断目录。
    output=workspace_path('run', 'logshare-probe'); output.mkdir(parents=True,exist_ok=True)
    (output/'official-smoke.json').write_text(json.dumps({'time':int(time.time()),'steps':steps},ensure_ascii=False,indent=2),encoding='utf-8')
