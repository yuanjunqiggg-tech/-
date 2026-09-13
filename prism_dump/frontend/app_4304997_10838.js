<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Title}}</title>
<style>body{font-family:system-ui;background:#1b1f27;color:#e8eaf0;margin:0;padding:24px}
h1{font-size:20px}.desc{color:#9aa3b5;font-size:13px;margin-bottom:20px}
.ctrl{margin-bottom:18px}.label{font-size:13px;color:#9aa3b5;margin-bottom:6px}
.value{background:#242a36;border-radius:8px;padding:12px;min-height:18px}
input[type=text]{background:#242a36;border:1px solid #3a4252;border-radius:8px;padding:10px;color:#e8eaf0;width:220px}
button{background:#4f8cff;border:0;border-radius:8px;padding:10px 20px;color:#fff;cursor:pointer}
table{border-collapse:collapse;width:100%;max-width:480px}td,th{border:1px solid #3a4252;padding:8px 12px;text-align:left}
.switch{display:inline-flex;align-items:center;gap:8px;font-size:14px}
a.back{color:#4f8cff;text-decoration:none;font-size:13px}</style></head><body>
<a class="back" href="/web/">← 返回门户</a>
<h1>{{.Title}}</h1>
{{if .Desc}}<div class="desc">{{.Desc}}</div>{{end}}
{{range .Controls}}
{{if eq .Type "text"}}<div class="ctrl"><div class="label">{{.Label}}</div><div class="value" data-key="{{.Key}}">-</div></div>{{end}}
{{if eq .Type "button"}}<div class="ctrl"><button data-action="{{.Action}}" onclick="doAction(this)">{{.Label}}</button></div>{{end}}
{{if eq .Type "input"}}<div class="ctrl"><div class="label">{{.Label}}</div><input type="text" data-key="{{.Key}}" placeholder="{{.Placeholder}}"></div>{{end}}
{{if eq .Type "switch"}}<div class="ctrl"><label class="switch"><input type="checkbox" data-key="{{.Key}}">{{.Label}}</label></div>{{end}}
{{if eq .Type "table"}}<div class="ctrl"><div class="label">{{.Label}}</div><table data-key="{{.Key}}"><thead><tr>{{range .Columns}}<th>{{.}}</th>{{end}}</tr></thead><tbody></tbody></table></div>{{end}}
{{end}}
<script>
var PAGE = {{.PageJSON}};
function setVal(key, v) {
  var el = document.querySelector('[data-key="' + key + '"]');
  if (!el) return;
  if (el.tagName === 'TABLE') {
    var tb = el.querySelector('tbody'); tb.innerHTML = '';
    (v || []).forEach(function(row) {
      var tr = document.createElement('tr');
      (row || []).forEach(function(cell) {
        var td = document.createElement('td'); td.textContent = cell; tr.appendChild(td);
      });
      tb.appendChild(tr);
    });
  } else if (el.type === 'checkbox') el.checked = !!v;
  else if (el.tagName === 'INPUT') el.value = v;
  else el.textContent = v;
}
var es = new EventSource('/web/events/' + PAGE.plugin);
es.addEventListener(PAGE.page, function(e) {
  var d = JSON.parse(e.data);
  for (var k in d) setVal(k, d[k]);
});
function doAction(btn) {
  var args = {};
  document.querySelectorAll('[data-key]').forEach(function(el) {
    var k = el.getAttribute('data-key');
    if (el.type === 'checkbox') args[k] = el.checked;
    else if (el.value !== undefined) args[k] = el.value;
  });
  fetch('/web/api/' + PAGE.plugin + '/' + PAGE.page, {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({action: btn.getAttribute('data-action'), args: args})
  }).then(function(r) {
    if (!r.ok) return r.text().then(function(t) { throw new Error('HTTP ' + r.status + (t ? ': ' + t : '')); });
    return r.json();
  }).then(function(res) { if (res.ok === false) alert('操作失败: ' + (res.error || '')); })
    .catch(function(e) { alert('请求失败: ' + e.message); });
}
</script></body></html>async function Rtsk(){
  var r=await A('GET','/api/task/list'),h='<div class="content-inner" style="padding:4px 0">';
  if(!r.ok||!r.tasks||!r.tasks.length){h+='<div class="card"><p style="text-align:center;color:var(--phx-text-secondary);padding:20px;font-size:13px">暂无断点任务</p></div>'}
  else r.tasks.forEach(function(t){
    var tn=t.name&&t.name!='import'&&t.name!='mapart'&&t.name!='export'?t.name:t.type+' #'+t.task_id.slice(0,6);
    var pp={};try{pp=JSON.parse(t.params)}catch(e){}var ppath=pp.path||'';var isMc=ppath.toLowerCase().endsWith('.mcworld');
    var stCl=t.status==='running'?'color:var(--phx-success)':t.status==='paused'?'color:var(--phx-warning)':t.status==='failed'?'color:var(--phx-error)':'color:var(--phx-text-disabled)';
    var stLabel=t.status==='running'?'运行中':t.status==='paused'?'已暂停':t.status==='failed'?'失败':t.status==='done'?'完成':t.status;
    h+='<div class="qcard" data-taskid="'+t.task_id+'" data-path="'+ppath.replace(/"/g,'&quot;')+'" data-ismc="'+(isMc?1:0)+'" data-progress="'+t.progress+'" data-msg="'+(t.message||'')+'" data-status="'+t.status+'" data-name="'+tn+'" onclick="var d=this.dataset;showTaskDetail(d.taskid,d.name,parseFloat(d.progress),d.msg,d.status,d.path,d.ismc==1)">'+
      '<div class="qc-icon" style="font-size:16px">'+(t.status==='running'?ICONS.radio:t.status==='done'?ICONS.check:ICONS.close)+'</div>'+
      '<div class="qc-body"><div class="qc-title">'+tn+'</div><div class="qc-sub">'+(t.message||'')+' · '+Math.round(t.progress*100)+'%</div></div>'+
      '<span style="font-size:10px;font-weight:700;'+stCl+'">'+stLabel+'</span></div>'
  });
  h+='</div>';document.getElementById('tab-tasks').innerHTML=h
}

function showTaskDetail(id,name,prog,msg,st,path,isMc){
  var m=document.createElement('div');m.className='modal-overlay';
  m.innerHTML='<div class="modal-box">'+
    '<div style="font-weight:800;font-size:16px;margin-bottom:10px">'+name+'</div>'+
    '<div class="dim" style="margin-bottom:2px">进度: '+Math.round(prog*100)+'%</div>'+
    '<div class="dim" style="margin-bottom:4px">'+msg+'</div>'+
    '<div style="font-size:12px;font-weight:700;margin-bottom:14px;color:'+(st==='running'?'var(--phx-success)':st==='failed'?'var(--phx-error)':st==='paused'?'var(--phx-warning)':'var(--phx-text-disabled)')+'">状态: '+st+'</div>'+
    (path?'<button class="btn" style="width:100%;margin-bottom:8px" onclick="closeModalOverlay(this);impPath=\''+path+'\';doAnalyze(\''+path+'\','+isMc+')">查看文件</button>':'')+
    (st==='running'?'<button class="btn-d" style="width:100%" onclick="stopT();closeModalOverlay(this)">停止</button>':
     st!=='done'?'<div class="row"><button class="btn" onclick="resT(\''+id+'\');closeModalOverlay(this)">恢复</button><button class="btn-s" onclick="delT(\''+id+'\');closeModalOverlay(this)">删除</button></div>':
     '<button class="btn-s" style="width:100%" onclick="delT(\''+id+'\');closeModalOverlay(this)">删除</button>')+
    '<button class="btn-s" style="width:100%;margin-top:8px" onclick="closeModalOverlay(this)">关闭</button></div>';
  document.body.appendChild(m);m.addEventListener('click',function(e){if(e.target===m)m.remove()})
}
async function resT(id){var r=await A('POST','/api/task/resume',{task_id:id});T(r.ok?'已恢复':r.error,'o');Rtsk();if(typeof refreshHomeTasks==='function')refreshHomeTasks()}
async function stopT(){await A('POST','/api/task/stop');Rtsk();if(typeof refreshHomeTasks==='function')refreshHomeTasks()}
async function delT(id){await A('POST','/api/task/delete',{task_id:id});Rtsk();if(typeof refreshHomeTasks==='function')refreshHomeTasks()}
function RmapDisplayHTML(){
  return '<div class="card"><div style="font-size:16px;font-weight:800;margin-bottom:10px">展示框显示器</div>'+
    '<label>扫描区域</label><div class="row"><input id="md-x1" type="number" placeholder="X1"><input id="md-y1" type="number" placeholder="Y1"><input id="md-z1" type="number" placeholder="Z1"></div>'+
    '<div class="row"><input id="md-x2" type="number" placeholder="X2"><input id="md-y2" type="number" placeholder="Y2"><input id="md-z2" type="number" placeholder="Z2"></div>'+
    '<button class="btn" onclick="doMapScan()" style="margin:6px 0">扫描展示框区域</button>'+
    '<div id="md-grid-info" class="gone" style="margin-bottom:8px"></div>'+
    '<div id="md-file-section" class="gone">'+
    '<label>选择图片或视频</label><div class="pick" onclick="doMapPick()"><i class="pi">' + ICONS.upload + '</i><div id="md-pick-txt">点击选择文件</div></div>'+
    '<div class="row">'+
    '<button class="btn" id="md-display-btn" onclick="doMapDisplay()">显示图片</button>'+
    '<button class="btn" id="md-play-btn" onclick="doMapPlay()">播放视频</button></div></div>'+
    '<div class="row"><button class="btn-d gone" id="md-stop" onclick="doMapStop()">停止</button></div></div>'+
    '<div class="card gone" id="md-log-card"><div class="log" id="md-log"></div></div>'
}

var mapGridInfo=null;

async function doMapScan(){
  var fd=new FormData();
  fd.append('x1',document.getElementById('md-x1').value||0);
  fd.append('y1',document.getElementById('md-y1').value||0);
  fd.append('z1',document.getElementById('md-z1').value||0);
  fd.append('x2',document.getElementById('md-x2').value||0);
  fd.append('y2',document.getElementById('md-y2').value||0);
  fd.append('z2',document.getElementById('md-z2').value||0);
  var r=await fetch('/api/map/scan',{method:'POST',body:fd}).then(function(x){return x.json()});
  if(!r.ok){T('扫描失败: '+r.error,'e');return}
  mapGridInfo=r;
  document.getElementById('md-grid-info').classList.remove('gone');
  document.getElementById('md-grid-info').innerHTML='<div class="stats"><div class="s"><div class="n">'+r.rows+'×'+r.cols+'</div><div class="l">网格</div></div>'+
    '<div class="s"><div class="n">'+(r.planeType||'未知')+'</div><div class="l">平面</div></div></div>';
  document.getElementById('md-file-section').classList.remove('gone');
  T('扫描完成: '+r.rows+'行×'+r.cols+'列','o')
}

async function doMapPick(){
  var p=await pick('image');if(!p)return;
  document.getElementById('md-pick-txt').textContent=p.split('/').pop();
  document.getElementById('md-pick-txt').dataset.path=p
}

async function doMapDisplay(){
  var path=document.getElementById('md-pick-txt').dataset.path;
  if(!path){T('请先选择文件','e');return}
  var fd=new FormData();fd.append('path',path);
  var r=await fetch('/api/map/display',{method:'POST',body:fd}).then(function(x){return x.json()});
  if(r.ok){T('正在显示...','o');document.getElementById('md-log-card').classList.remove('gone')}
  else T('显示失败: '+r.error,'e')
}

async function doMapPlay(){
  var path=document.getElementById('md-pick-txt').dataset.path;
  if(!path){T('请先选择文件','e');return}
  var fd=new FormData();fd.append('path',path);fd.append('fps','10');
  var r=await fetch('/api/map/play',{method:'POST',body:fd}).then(function(x){return x.json()});
  if(r.ok){T('开始播放','o');document.getElementById('md-stop').classList.remove('gone');document.getElementById('md-log-card').classList.remove('gone')}
  else T('播放失败: '+r.error,'e')
}

function doMapStop(){fetch('/api/map/stop',{method:'POST'});T('已停止');document.getElementById('md-stop').classList.add('gone')}
