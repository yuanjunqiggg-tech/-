// 插件管理：导入/创建、代码编辑(语法高亮+搜索)、数据目录(文本可点开编辑)、配置、分享。
// 复用 filepicker.js 的 showFilePicker；上传复用 /api/file/upload multipart。
// 子页统一用 openSubPage(title, html)，配置/数据页通过 delete subPageCache[title] 强制刷新。

/* ═══ 导入 / 创建入口 ═══ */

// 点「导入插件」：弹窗三个选项 —— 从外部导入 / 自己编写 / 从插件市场获取。
function plgImport(){
  var ov=document.createElement('div');ov.className='modal-overlay';
  ov.innerHTML='<div class="modal-box" style="max-width:320px">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:14px">导入插件</div>'
    +'<button class="btn" style="width:100%;padding:14px;margin-bottom:10px;font-size:14px" onclick="plgImportLocal();closeModalOverlay(this)">📂 从外部导入</button>'
    +'<button class="btn" style="width:100%;padding:14px;margin-bottom:10px;font-size:14px" onclick="plgCreate();closeModalOverlay(this)">✍️ 自己编写</button>'
    +'<button class="btn" style="width:100%;padding:14px;font-size:14px" onclick="closeModalOverlay(this);pmOpenMarket()">🛒 从插件市场获取</button></div>';
  document.body.appendChild(ov);
  ov.addEventListener('click',function(e){if(e.target===ov)closeOverlay(ov)});
}

// 从本地导入：内置选择器优先；若用户关闭(取消)内置选择器，回退到系统选择器选 ZIP。
function plgImportLocal(){
  if (useBuiltinPicker && typeof showFilePicker==='function') {
    showFilePicker('/storage/emulated/0','zip',function(path){
      if(path) uploadAndImport(path);
    }, null, function(){ plgImportSystem(); }); // 关闭内置 → 系统选择器
  } else {
    plgImportSystem();
  }
}
// 系统选择器：Android 原生 pickFile(默认 */* 可选 zip) 或 HTML input(.zip)。
function plgImportSystem(){
  if (typeof android!=='undefined' && android.pickFile) {
    fw=function(path){ if(path) uploadAndImport(path); };
    android.pickFile('zip');
  } else {
    var i=document.createElement('input');i.type='file';i.accept='.zip,application/zip';
    i.onchange=function(){var f=i.files[0];if(!f)return;var d=new FormData();d.append('file',f);
      fetch('/api/file/upload',{method:'POST',body:d}).then(function(r){return r.json()})
      .then(function(j){ if(j.ok&&j.path) uploadAndImport(j.path); }).catch(function(){});};
    i.click();
  }
}
// 选定插件包路径 → 后端 import。path 为服务器端路径（内置/系统选择器选中的已是服务器路径）。
async function uploadAndImport(path){
  T('正在导入插件...','w');
  var r=await A('POST','/api/plugin/import',{path:path});
  if(!r.ok){ T((r.error||'导入失败'),'e'); return; }
  T('插件已导入: '+(r.id||''),'o');
  if(typeof Rplg==='function')Rplg();
}

// 创建：底部弹出选类型(Lua/词库) → 填名称+描述 → 创建并自动进入编辑。
function plgCreate(){
  var so=document.createElement('div');so.className='bs-overlay';
  so.innerHTML='<div class="bs-sheet">'
    +'<div class="bs-title">选择要创建的插件类型</div>'
    +'<div class="bs-body">'
    +'<div class="bs-option" data-ptype="lua"><span class="bs-dot"></span><span class="bs-label">Lua 插件</span><span style="font-size:12px;color:var(--phx-text-secondary)">脚本逻辑</span></div>'
    +'<div class="bs-option" data-ptype="wordbank"><span class="bs-dot"></span><span class="bs-label">词库插件</span><span style="font-size:12px;color:var(--phx-text-secondary)">触发词菜单</span></div>'
    +'</div>'
    +'<div class="bs-footer"><button class="bs-btn bs-btn-cancel" id="plg-create-cancel">取消</button></div></div>';
  document.body.appendChild(so);
  so.querySelectorAll('.bs-option').forEach(function(el){
    el.addEventListener('click',function(){
      so.querySelectorAll('.bs-option').forEach(function(x){x.classList.remove('active')});
      el.classList.add('active');
      setTimeout(function(){ closeOverlay(so); plgCreateForm(el.dataset.ptype); },150);
    });
  });
  document.getElementById('plg-create-cancel').addEventListener('click',function(){closeOverlay(so)});
  so.addEventListener('click',function(e){if(e.target===so)closeOverlay(so)});
}
function plgCreateForm(ptype){
  var ov=document.createElement('div');ov.className='modal-overlay';
  var title=ptype==='wordbank'?'创建词库插件':'创建 Lua 插件';
  ov.innerHTML='<div class="modal-box" style="max-width:340px">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:12px">'+title+'</div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:6px">插件名称</div>'
    +'<input id="plg-new-name" type="text" placeholder="例如：领地系统" style="width:100%;padding:10px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);font-size:14px;color:var(--phx-text);box-sizing:border-box;margin-bottom:10px;outline:none">'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:6px">插件描述（可选）</div>'
    +'<input id="plg-new-desc" type="text" placeholder="一句话说明" style="width:100%;padding:10px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);font-size:14px;color:var(--phx-text);box-sizing:border-box;margin-bottom:14px;outline:none">'
    +'<div style="display:flex;gap:8px">'
    +'<button class="bs-btn bs-btn-cancel" onclick="closeModalOverlay(this)">取消</button>'
    +'<button class="bs-btn bs-btn-confirm" onclick="plgDoCreate(\''+ptype+'\')">创建并编辑</button></div></div>';
  document.body.appendChild(ov);
}
async function plgDoCreate(ptype){
  var name=(document.getElementById('plg-new-name').value||'').trim();
  var desc=(document.getElementById('plg-new-desc').value||'').trim();
  if(!name){ T('请填写插件名称','e'); return; }
  T('正在创建...','w');
  var r=await A('POST','/api/plugin/create',{type:ptype,name:name,description:desc});
  if(!r.ok){ T((r.error||'创建失败'),'e'); return; }
  document.querySelectorAll('.modal-overlay').forEach(function(o){o.remove()});
  T('已创建: '+(r.id||''),'o');
  if(typeof Rplg==='function')Rplg();
  openPluginEditor(r.id); // 自动跳转到代码编辑
}

/* ═══ 插件代码编辑器（代码 / 文档 / API + 搜索） ═══ */

function plgEdit(id){ openPluginEditor(id); }

function openPluginEditor(id){
  var title='编辑·'+id;
  delete subPageCache[title];
  var h='<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;flex-wrap:wrap">'
    +'<input id="plg-srch" type="text" placeholder="搜索当前内容..." style="flex:1;min-width:120px;padding:8px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:13px;outline:none">'
    +'<span id="plg-srch-cnt" style="font-size:12px;color:var(--phx-text-secondary)"></span>'
    +'<button class="btn" style="width:auto;padding:8px 14px;font-size:14px;font-weight:600;flex-shrink:0" onclick="openAIAssist(\''+id+'\')">AI 帮写</button></div>'
    +'<div style="display:flex;gap:6px;margin-bottom:10px">'
    +'<button class="edit-tab active" data-tab="code" onclick="plgEditTab(\''+id+'\',\'code\')">代码</button>'
    +'<button class="edit-tab" data-tab="docs" onclick="plgEditTab(\''+id+'\',\'docs\')">插件说明</button>'
    +'<button class="edit-tab" data-tab="api" onclick="plgEditTab(\''+id+'\',\'api\')">开发文档</button></div>'
    +'<div id="plg-edit-body"></div>';
  openSubPage(title,h);
  window.__plgEdit={id:id,tab:'code',term:'',content:{},codeName:'',codeLang:'lua'};
  var srch=document.getElementById('plg-srch');
  srch.addEventListener('input',function(){ window.__plgEdit.term=this.value; plgRenderSearch(); });
  plgEditTab(id,'code');
}

// 切换标签：代码 / 文档 / API（内容懒加载，缓存于 window.__plgEdit）。
async function plgEditTab(id,tab){
  var st=window.__plgEdit; if(!st)return;
  st.tab=tab;
  document.querySelectorAll('.edit-tab').forEach(function(b){b.classList.toggle('active',b.dataset.tab===tab)});
  if(st.content[tab]===undefined){
    if(tab==='api'){
      // 开发文档按插件类型展示：词库→词库文档，Lua→Lua API 文档
      if(st.isWordbank===undefined){
        var nr=await A('GET','/api/plugin/file/read?id='+encodeURIComponent(id)+'&scope=code&file=');
        st.isWordbank=!!(nr.name&&/\.json$/.test(nr.name.toLowerCase()));
      }
      var r=await A('GET', st.isWordbank ? '/api/plugin/wordbank-doc' : '/api/plugin/api-doc');
      st.content.api=r.ok?(r.content||''):('加载失败: '+(r.error||''));
    } else if(tab==='docs'){
      var r=await A('GET','/api/plugin/file/read?id='+encodeURIComponent(id)+'&scope=docs&file=');
      st.content.docs=r.ok?(r.content||''):('加载失败: '+(r.error||''));
    } else {
      var r=await A('GET','/api/plugin/file/read?id='+encodeURIComponent(id)+'&scope=code&file=');
      st.content.code=r.ok?(r.content||''):('加载失败: '+(r.error||''));
      st.codeName=r.name||''; st.codeLang=r.name&&(r.name.indexOf('词库')>=0||r.name.toLowerCase().endsWith('.json'))?'json':'lua';
      st.isWordbank=!!(r.name&&/\.json$/.test(r.name.toLowerCase()));
    }
  }
  var term=st.term||'';
  if(tab==='code') renderCodeEditor(st,term);
  else if(tab==='docs') renderDocsEditor(st,term);
  else renderMarkdown(st,tab,term);
}
function renderCodeEditor(st,term){
  var body=document.getElementById('plg-edit-body');
  if(!term) document.getElementById('plg-srch-cnt').textContent='';
  if(st.isWordbank){
    renderWordBankEditor(st, body);
    return;
  }
  var lang=st.codeLang||'lua';
  body.innerHTML='<div class="code-wrap">'
    +'<pre class="code-pre" id="plg-code-pre" aria-hidden="true"></pre>'
    +'<textarea class="code-input" id="plg-code-ta" spellcheck="false"></textarea></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px">'
    +'<button class="btn" style="width:auto;padding:8px 16px" onclick="plgSaveCode(\''+st.id+'\')">保存</button></div>';
  var ta=document.getElementById('plg-code-ta'),pre=document.getElementById('plg-code-pre');
  ta.value=st.content.code;
  function paint(){ pre.innerHTML=highlightCode(ta.value,lang); sync(); }
  function sync(){ pre.scrollTop=ta.scrollTop; pre.scrollLeft=ta.scrollLeft; }
  ta.addEventListener('input',paint);
  ta.addEventListener('scroll',sync);
  paint();
  if(term){
    var cnt=countMatches(ta.value,term);
    document.getElementById('plg-srch-cnt').textContent=cnt+' 个匹配';
    var idx=ta.value.toLowerCase().indexOf(term.toLowerCase());
    if(idx>=0){ ta.focus(); ta.setSelectionRange(idx,idx+term.length); }
  }
}
function renderMarkdown(st,tab,term){
  var body=document.getElementById('plg-edit-body');
  document.getElementById('plg-srch-cnt').textContent='';
  var md=tab==='docs'?st.content.docs:st.content.api;
  var html=(typeof marked!=='undefined'&&marked.parse)?marked.parse(md||'')
    :'<pre style="white-space:pre-wrap;font-family:monospace;font-size:12px">'+escHtml(md||'')+'</pre>';
  body.innerHTML='<div class="md-view" style="background:var(--phx-bg);border:2px solid var(--phx-border-light);border-radius:10px;padding:14px;font-size:13px;line-height:1.7">'+html+'</div>';
  if(term) markSearch(body.querySelector('.md-view'),term);
}
// 文档页签：可编辑 markdown 源码（编辑/预览 切换）+ 保存。
function renderDocsEditor(st,term){
  var body=document.getElementById('plg-edit-body');
  if(!term) document.getElementById('plg-srch-cnt').textContent='';
  body.innerHTML='<div style="display:flex;gap:6px;margin-bottom:8px">'
    +'<button class="edit-tab active" data-md="edit" onclick="plgMdMode(\''+st.id+'\',\'edit\')">编辑</button>'
    +'<button class="edit-tab" data-md="prev" onclick="plgMdMode(\''+st.id+'\',\'prev\')">预览</button></div>'
    +'<div id="plg-md-body">'
    +'<div class="code-wrap"><pre class="code-pre" id="plg-docs-pre" aria-hidden="true"></pre>'
    +'<textarea class="code-input" id="plg-docs-ta" spellcheck="false"></textarea></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px">'
    +'<button class="btn" style="width:auto;padding:8px 16px" onclick="plgSaveDocs(\''+st.id+'\')">保存</button></div></div>';
  var ta=document.getElementById('plg-docs-ta'),pre=document.getElementById('plg-docs-pre');
  ta.value=st.content.docs||'';
  function paint(){ pre.innerHTML=highlightCode(ta.value,null); sync(); }
  function sync(){ pre.scrollTop=ta.scrollTop; pre.scrollLeft=ta.scrollLeft; }
  ta.addEventListener('input',function(){ st.content.docs=ta.value; paint(); });
  ta.addEventListener('scroll',sync);
  paint();
  if(term){
    var cnt=countMatches(ta.value,term);
    document.getElementById('plg-srch-cnt').textContent=cnt+' 个匹配';
    var idx=ta.value.toLowerCase().indexOf(term.toLowerCase());
    if(idx>=0){ ta.focus(); ta.setSelectionRange(idx,idx+term.length); }
  }
}
function plgMdMode(id,mode){
  var st=window.__plgEdit; if(!st)return;
  var ta=document.getElementById('plg-docs-ta');
  if(ta) st.content.docs=ta.value; // 切换前保存当前编辑内容
  document.querySelectorAll('[data-md]').forEach(function(b){b.classList.toggle('active',b.dataset.md===mode)});
  var body=document.getElementById('plg-md-body');
  if(mode==='prev'){
    var md=st.content.docs||'';
    var html=(typeof marked!=='undefined'&&marked.parse)?marked.parse(md):'<pre style="white-space:pre-wrap">'+escHtml(md)+'</pre>';
    body.innerHTML='<div class="md-view" style="background:var(--phx-bg);border:2px solid var(--phx-border-light);border-radius:10px;padding:14px;font-size:13px;line-height:1.7">'+html+'</div>';
  } else {
    renderDocsEditor(st,st.term||'');
  }
}
async function plgSaveDocs(id){
  var st=window.__plgEdit; if(!st)return;
  var ta=document.getElementById('plg-docs-ta'); if(ta) st.content.docs=ta.value;
  T('正在保存...','w');
  var r=await A('POST','/api/plugin/file/write',{id:id,scope:'docs',file:'',content:st.content.docs||''});
  if(!r.ok){ T((r.error||'保存失败'),'e'); return; }
  T('文档已保存','o');
  if(typeof Rplg==='function')Rplg();
}
function plgRenderSearch(){
  var st=window.__plgEdit; if(!st)return;
  var term=st.term||'';
  if(st.tab==='code'||st.tab==='docs'){
    var ta=st.tab==='code'?document.getElementById('plg-code-ta'):document.getElementById('plg-docs-ta');
    if(ta){
      var cnt=term?countMatches(ta.value,term):0;
      document.getElementById('plg-srch-cnt').textContent=cnt?cnt+' 个匹配':'';
      var idx=ta.value.toLowerCase().indexOf(term.toLowerCase());
      if(idx>=0){ ta.focus(); ta.setSelectionRange(idx,idx+term.length); }
    }
    return;
  }
  plgEditTab(st.id,st.tab); // API：重渲染并高亮命中
}
async function plgSaveCode(id){
  var ta=document.getElementById('plg-code-ta'); if(!ta)return;
  var st=window.__plgEdit; if(st)st.content.code=ta.value;
  T('正在保存...','w');
  var r=await A('POST','/api/plugin/file/write',{id:id,scope:'code',file:'',content:ta.value});
  if(!r.ok){ T((r.error||'保存失败'),'e'); return; }
  await A('POST','/api/plugin/reload',{id:id}); // 运行中则热重载，未运行报错忽略
  T('已保存','o');
  if(typeof Rplg==='function')Rplg();
}

/* ═══ 数据目录（文本可点开编辑） ═══ */

function isTextFile(name){
  var ext=(String(name).split('.').pop()||'').toLowerCase();
  return ['txt','json','lua','md','log','yml','yaml','xml','cfg','conf','ini','csv','js','ts','py','go','sh','bat','properties'].indexOf(ext)>=0;
}
async function plgDataDir(id){
  var r=await A('GET','/api/plugin/data?id='+encodeURIComponent(id));
  if(!r.ok){ T((r.error||'读取数据目录失败'),'e'); return; }
  var files=r.files||[];
  var title='数据目录·'+id;
  delete subPageCache[title];
  var h;
  if(!files.length){
    h='<p style="text-align:center;color:var(--phx-text-secondary);padding:20px;font-size:13px">数据目录为空</p>';
  } else {
    h='<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:8px">点击文本文件可编辑</div>'
      + files.map(function(f){
          var editable=isTextFile(f);
          var on=editable?'onclick="plgDataOpen(\''+id+'\',\''+String(f).replace(/'/g,"\\'")+'\')"':'';
          return '<div class="df-row'+(editable?' df-clickable':'')+'" style="display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:8px;background:rgba(128,128,128,.06);margin-bottom:6px;cursor:'+(editable?'pointer':'default')+'" '+on+'>'
            +'<span style="font-family:monospace;font-size:12px;flex:1;word-break:break-all">'+escHtml(f)+'</span>'
            +(editable?'<span style="font-size:11px;color:var(--phx-primary);flex-shrink:0">编辑</span>':'')
            +'</div>';
        }).join('');
  }
  openSubPage(title,h);
}
function plgDataOpen(id,f){ openDataFileEditor(id,f); }

// 数据目录文本文件编辑器（语法高亮 + 保存）。
async function openDataFileEditor(id,file){
  var title='编辑·'+file;
  delete subPageCache[title];
  T('加载中...','w');
  var r=await A('GET','/api/plugin/file/read?id='+encodeURIComponent(id)+'&scope=data&file='+encodeURIComponent(file));
  if(!r.ok){ T((r.error||'读取失败'),'e'); return; }
  var lang=fileLang(file);
  var h='<div class="code-wrap">'
    +'<pre class="code-pre" id="plg-df-pre" aria-hidden="true"></pre>'
    +'<textarea class="code-input" id="plg-df-ta" spellcheck="false"></textarea></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px">'
    +'<button class="btn" style="width:auto;padding:8px 16px" onclick="plgSaveDataFile(\''+id+'\',\''+String(file).replace(/'/g,"\\'")+'\')">保存</button></div>';
  openSubPage(title,h);
  var ta=document.getElementById('plg-df-ta'),pre=document.getElementById('plg-df-pre');
  ta.value=r.content||'';
  function paint(){ pre.innerHTML=highlightCode(ta.value,lang); sync(); }
  function sync(){ pre.scrollTop=ta.scrollTop; pre.scrollLeft=ta.scrollLeft; }
  ta.addEventListener('input',paint);
  ta.addEventListener('scroll',sync);
  paint();
}
async function plgSaveDataFile(id,file){
  var ta=document.getElementById('plg-df-ta'); if(!ta)return;
  T('正在保存...','w');
  var r=await A('POST','/api/plugin/file/write',{id:id,scope:'data',file:file,content:ta.value});
  if(!r.ok){ T((r.error||'保存失败'),'e'); return; }
  T('已保存','o');
  delete subPageCache['数据目录·'+id]; // 下次打开数据目录刷新
}
function fileLang(name){
  var ext=(String(name).split('.').pop()||'').toLowerCase();
  return ext==='json'?'json':(ext==='lua'?'lua':null);
}

/* ═══ 轻量语法高亮（离线，无外部依赖） ═══ */

var LUA_KW={local:1,function:1,end:1,if:1,then:1,else:1,elseif:1,for:1,while:1,do:1,return:1,nil:1,true:1,false:1,and:1,or:1,not:1,in:1,repeat:1,until:1,break:1};
var LUA_API={game:1,system:1,api:1,plugin:1,util:1,bot:1,building:1,media:1,world:1,player:1,events:1,http:1,web:1};

function hlEsc(t){return String(t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}

function highlightCode(src,lang){
  if(lang==='json') return highlightJSON(src);
  if(lang==='lua') return highlightLua(src);
  return hlEsc(src);
}
function highlightLua(src){
  var out='',i=0,n=src.length;
  while(i<n){
    var c=src[i];
    if(c==='-'&&src[i+1]==='-'){ // 注释
      var j=src.indexOf('\n',i); if(j<0)j=n;
      out+='<span class="tk-c">'+hlEsc(src.slice(i,j))+'</span>'; i=j; continue;
    }
    if(c==='"'||c==="'"){ // 字符串
      var q=c,j=i+1; while(j<n&&src[j]!==q){ if(src[j]==='\\')j++; j++; } if(j<n)j++;
      out+='<span class="tk-s">'+hlEsc(src.slice(i,j))+'</span>'; i=j; continue;
    }
    if(/[A-Za-z_]/.test(c)){ // 单词
      var j=i; while(j<n&&/[A-Za-z0-9_]/.test(src[j]))j++;
      var w=src.slice(i,j);
      if(LUA_KW[w]) out+='<span class="tk-k">'+w+'</span>';
      else if(LUA_API[w]) out+='<span class="tk-f">'+w+'</span>';
      else out+=hlEsc(w);
      i=j; continue;
    }
    if(/[0-9]/.test(c)){ // 数字
      var j=i; while(j<n&&/[0-9A-Fa-fxX.+-]/.test(src[j]))j++;
      out+='<span class="tk-n">'+hlEsc(src.slice(i,j))+'</span>'; i=j; continue;
    }
    out+=hlEsc(c); i++;
  }
  return out;
}
function highlightJSON(src){
  var out='',i=0,n=src.length;
  while(i<n){
    var c=src[i];
    if(c==='"'){ // 字符串 / 键
      var j=i+1; while(j<n&&src[j]!=='"'){ if(src[j]==='\\')j++; j++; } if(j<n)j++;
      var str=src.slice(i,j), k=j; while(k<n&&/\s/.test(src[k]))k++;
      if(src[k]===':') out+='<span class="tk-key">'+hlEsc(str)+'</span>';
      else out+='<span class="tk-s">'+hlEsc(str)+'</span>';
      i=j; continue;
    }
    if(/[0-9-]/.test(c)){ // 数字
      var j=i; while(j<n&&/[0-9.eE+-]/.test(src[j]))j++;
      out+='<span class="tk-n">'+hlEsc(src.slice(i,j))+'</span>'; i=j; continue;
    }
    if(/[A-Za-z]/.test(c)){ // true/false/null
      var j=i; while(j<n&&/[A-Za-z]/.test(src[j]))j++;
      var w=src.slice(i,j);
      out+=(w==='true'||w==='false'||w==='null')?'<span class="tk-k">'+w+'</span>':hlEsc(w);
      i=j; continue;
    }
    out+=hlEsc(c); i++;
  }
  return out;
}
function countMatches(text,term){
  if(!term)return 0;
  var re=new RegExp(term.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'gi');
  var m=text.match(re); return m?m.length:0;
}
// 在 markdown 视图里高亮搜索命中（包裹 <mark>）。
function markSearch(el,term){
  if(!el)return;
  if(!term){ el.querySelectorAll('mark').forEach(function(m){m.replaceWith(document.createTextNode(m.textContent))}); return; }
  var re=new RegExp(term.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'gi');
  var walk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);
  var nodes=[]; while(walk.nextNode())nodes.push(walk.currentNode);
  nodes.forEach(function(tn){
    if(tn.parentNode&&tn.parentNode.tagName==='MARK')return;
    var txt=tn.nodeValue; re.lastIndex=0; if(!re.test(txt))return; re.lastIndex=0;
    var frag=document.createDocumentFragment(),last=0,m;
    while((m=re.exec(txt))){
      if(m.index>last)frag.appendChild(document.createTextNode(txt.slice(last,m.index)));
      var mk=document.createElement('mark'); mk.textContent=m[0]; frag.appendChild(mk);
      last=m.index+m[0].length;
      if(m[0].length===0)re.lastIndex++;
    }
    if(last<txt.length)frag.appendChild(document.createTextNode(txt.slice(last)));
    tn.parentNode.replaceChild(frag,tn);
  });
}

/* ═══ 原有：编辑配置 / 保存配置 / 分享 ═══ */

async function plgEditConfig(id){
  var r=await A('GET','/api/plugin/config?id='+encodeURIComponent(id));
  if(!r.ok){ T((r.error||'读取配置失败'),'e'); return; }
  var cfg=r.config||{};
  var title='插件配置·'+id;
  delete subPageCache[title];
  var h='<textarea id="plg-cfg" spellcheck="false" style="width:100%;min-height:300px;box-sizing:border-box;font-family:monospace;font-size:12px;padding:8px;border-radius:8px;border:1px solid rgba(128,128,128,.3);background:rgba(128,128,128,.06);color:inherit;resize:vertical">'+escHtml(JSON.stringify(cfg,null,2))+'</textarea>'
    +'<div style="margin-top:10px;display:flex;gap:8px;justify-content:flex-end">'
    +'<button class="btn" style="width:auto;padding:8px 16px" onclick="plgSaveConfig(\''+id+'\')">保存</button></div>';
  openSubPage(title,h);
}
async function plgSaveConfig(id){
  var ta=document.getElementById('plg-cfg');
  if(!ta)return;
  var cfg;
  try{ cfg=JSON.parse(ta.value); }
  catch(e){ T('JSON 格式错误: '+e.message,'e'); return; }
  var r=await A('POST','/api/plugin/config',{id:id,config:cfg});
  if(!r.ok){ T((r.error||'保存失败'),'e'); return; }
  T('配置已保存','o');
}
// 分享：弹窗二选一 —— 导出成 zip / 上传到插件市场。
function plgExport(id){
  var esc=String(id).replace(/'/g,"\\'");
  var ov=document.createElement('div');ov.className='modal-overlay';
  ov.innerHTML='<div class="modal-box" style="max-width:320px">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:14px">分享插件</div>'
    +'<button class="btn" style="width:100%;padding:14px;margin-bottom:10px;font-size:14px" onclick="plgExportZip(\''+esc+'\');closeModalOverlay(this)">📦 导出</button>'
    +'<button class="btn" style="width:100%;padding:14px;font-size:14px" onclick="closeModalOverlay(this);pmOpenUpload(\''+esc+'\')">⬆️ 上传市场</button></div>';
  document.body.appendChild(ov);
  ov.addEventListener('click',function(e){if(e.target===ov)closeOverlay(ov)});
}
// 导出成 zip 包下载。
async function plgExportZip(id){
  var r=await A('POST','/api/plugin/export',{id:id});
  if(!r.ok){ T((r.error||'导出失败'),'e'); return; }
  var path=r.path||'';
  if(path&&path.indexOf('/uploads/')===0){
    T('已导出','o');
    var a=document.createElement('a');a.href=path;a.download='';a.click();
  } else {
    T('已导出: '+path,'o');
  }
}
// 用系统文件选择器(SAF)直接把插件私有文件导出到用户选的位置（不经 Download 镜像）。
async function plgExportSAF(id){
  var r=await A('POST','/api/plugin/export-saf',{id:id});
  if(!r.ok){ T((r.error||'导出失败'),'e'); return; }
  if(typeof android!=='undefined'&&android.exportFile){
    android.exportFile(r.src_path, r.name);
  } else {
    T('当前环境不支持系统文件选择器，请用「分享」','w');
  }
}
// SAF 导出结果回调（Java 端完成后调用）
window.__onExportResult__ = function(ok){ T(ok?'导出成功':'导出失败', ok?'o':'e'); };

/* ═══ 词库卡片树图形化编辑器 ═══
   编辑状态 st.wb = {菜单项:[node,...]}
   node = {说明, 触发词:[], 功能简介, 仅OP可用, 参数:[{参数名,类型,默认值}],
           动作:{类型,指令[]|子菜单[]|判断{条件,成功,失败,成功提示,失败提示}}}
   节点定位用 JS 路径字符串，如 "root[0].动作.子菜单[1]"，配合 wbGet/wbSet。 */

function wbGet(root, path){
  if(!path) return root;
  var parts=path.split('.');
  var cur=root;
  for(var i=0;i<parts.length;i++){
    if(cur==null) return null;
    var m=parts[i].match(/^(.*?)\[(\d+)\]$/);
    if(m){ cur=cur[m[1]]; if(cur==null) return null; cur=cur[+m[2]]; }
    else cur=cur[parts[i]];
  }
  return cur;
}
function wbSet(root, path, val){
  var parts=path.split('.');
  var cur=root;
  for(var i=0;i<parts.length-1;i++){
    var m=parts[i].match(/^(.*?)\[(\d+)\]$/);
    if(m){ cur=cur[m[1]]; cur=cur[+m[2]]; }
    else cur=cur[parts[i]];
  }
  var last=parts[parts.length-1];
  var m2=last.match(/^(.*?)\[(\d+)\]$/);
  if(m2){
    var arr=cur[m2[1]]||[];
    if(val===null) arr.splice(+m2[2],1);
    else arr[+m2[2]]=val;
    cur[m2[1]]=arr;
  } else {
    if(val===null) delete cur[last];
    else cur[last]=val;
  }
}

function renderWordBankEditor(st, body){
  var root;
  try{ root=JSON.parse(st.content.code||'{}'); }catch(e){ root={}; }
  if(!root.菜单项||!Array.isArray(root.菜单项)) root.菜单项=[];
  st.wb=root;
  body.innerHTML=
    '<div style="display:flex;gap:6px;margin-bottom:8px">'
    +'<button class="edit-tab active" data-wb="gui" onclick="wbMode(\''+st.id+'\',\'gui\')">图形化</button>'
    +'<button class="edit-tab" data-wb="src" onclick="wbMode(\''+st.id+'\',\'src\')">源码</button></div>'
    +'<div id="wb-body"></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px">'
    +'<button class="btn" style="width:auto;padding:8px 16px" onclick="wbSave(\''+st.id+'\')">保存</button></div>';
  wbMode(st.id,'gui');
}

function wbMode(id, mode){
  var st=window.__plgEdit; if(!st||!st.wb) return;
  document.querySelectorAll('[data-wb]').forEach(function(b){b.classList.toggle('active',b.dataset.wb===mode)});
  var box=document.getElementById('wb-body');
  if(mode==='src'){
    box.innerHTML='<div class="code-wrap"><pre class="code-pre" id="wb-pre" aria-hidden="true"></pre>'
      +'<textarea class="code-input" id="wb-ta" spellcheck="false"></textarea></div>';
    var ta=document.getElementById('wb-ta'), pre=document.getElementById('wb-pre');
    ta.value=JSON.stringify(st.wb,null,2);
    function paint(){ pre.innerHTML=highlightCode(ta.value,'json'); pre.scrollTop=ta.scrollTop; pre.scrollLeft=ta.scrollLeft; }
    ta.addEventListener('input',function(){ try{ st.wb=JSON.parse(ta.value); }catch(e){} paint(); });
    ta.addEventListener('scroll',paint);
    paint();
  } else {
    box.innerHTML=wbTreeHtml(st.wb);
    bindWbEvents(box, st.wb);
  }
}

function wbTreeHtml(root){
  var h='<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:8px">'
    +'根菜单：'+escHtml(root.菜单项.length?root.菜单项.map(function(n){return n.说明||'?'}).join('、'):'(空)')+'</div>'
    +'<div style="margin-bottom:8px"><button class="btn" style="width:auto;padding:6px 12px" onclick="wbAddRoot()">＋ 新增根菜单</button></div>';
  root.菜单项.forEach(function(node,i){ h+=wbCardHtml(node,'root['+i+']',0); });
  return h;
}

function wbCardHtml(node, path, depth){
  var act=node.动作||{};
  var badge=act.类型==='指令'?'指令':(act.类型==='判断'?'判断':(act.类型==='子菜单'?'子菜单':'指令'));
  var op=node.仅OP可用?' ·仅OP':'';
  return '<div class="wb-card" style="margin-left:'+(depth*18)+'px;border:2px solid var(--phx-border-light);border-radius:8px;padding:6px 10px;margin-bottom:6px;background:var(--phx-bg)">'
    +'<div class="wb-head" style="display:flex;align-items:center;gap:8px;cursor:pointer">'
    +'<span class="wb-toggle" data-path="'+path+'" style="flex-shrink:0">▸</span>'
    +'<span style="flex:1;font-weight:600;font-size:13px">'+escHtml(node.说明||'(未命名)')+'</span>'
    +'<span style="font-size:11px;color:var(--phx-primary)">'+badge+'</span>'
    +'<span style="font-size:11px;color:var(--phx-text-secondary)">'+op+'</span></div>'
    +'<div class="wb-body" style="display:none;padding:6px 0 0">'
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:6px">'
    +'<button class="btn wb-edit" data-path="'+path+'" style="width:auto;padding:4px 10px">编辑</button>'
    +'<button class="btn" onclick="wbAddChild(\''+path+'\')" style="width:auto;padding:4px 10px">＋子项</button>'
    +'<button class="btn" onclick="wbDel(\''+path+'\')" style="width:auto;padding:4px 10px">删除</button></div>'
    +'<div class="wb-children"></div></div></div>';
}

function bindWbEvents(box, root){
  box.querySelectorAll('.wb-toggle').forEach(function(el){
    el.addEventListener('click',function(){
      var path=el.dataset.path, node=wbGet(root,path);
      var bodyEl=el.closest('.wb-card').querySelector('.wb-body');
      var open=bodyEl.style.display!=='none';
      bodyEl.style.display=open?'none':'block';
      el.textContent=open?'▸':'▾';
      if(!open && bodyEl.querySelector('.wb-children').childNodes.length===0 && node.动作&&node.动作.子菜单){
        var childrenHtml=node.动作.子菜单.map(function(c,i){return wbCardHtml(c,path+'.动作.子菜单['+i+']',1)}).join('');
        bodyEl.querySelector('.wb-children').innerHTML=childrenHtml;
        bindWbEvents(bodyEl, root);
      }
    });
  });
  box.querySelectorAll('.wb-edit').forEach(function(el){
    el.addEventListener('click',function(){ wbEditCard(el.dataset.path, root); });
  });
}

/* ═══ 增删与保存 ═══ */

function wbAddRoot(){
  var st=window.__plgEdit; if(!st||!st.wb)return;
  st.wb.菜单项.push({说明:'新菜单',触发词:['菜单'],动作:{类型:'指令',指令:['say hi']}});
  wbMode(st.id,'gui');
}
function wbAddChild(path){
  var st=window.__plgEdit, node=wbGet(st.wb,path);
  if(!node.动作||node.动作.类型!=='子菜单') node.动作={类型:'子菜单',子菜单:[]};
  node.动作.子菜单.push({说明:'新选项',触发词:['选项'],动作:{类型:'指令',指令:['say hi']}});
  wbMode(st.id,'gui');
}
function wbDel(path){
  var st=window.__plgEdit; if(!st||!st.wb)return;
  wbSet(st.wb, path, null);
  wbMode(st.id,'gui');
}
async function wbSave(id){
  var st=window.__plgEdit; if(!st||!st.wb)return;
  var body={菜单项:st.wb.菜单项||[]};
  T('正在保存...','w');
  var r=await A('POST','/api/plugin/file/write',{id:id,scope:'code',file:'',content:JSON.stringify(body,null,2)});
  if(!r.ok){ T((r.error||'保存失败'),'e'); return; }
  await A('POST','/api/plugin/reload',{id:id});
  st.content.code=JSON.stringify(body,null,2);
  T('已保存','o');
  if(typeof Rplg==='function')Rplg();
}

/* ═══ 编辑弹层 ═══ */

var WB_INPUT='width:100%;padding:8px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);font-size:13px;color:var(--phx-text);box-sizing:border-box;outline:none';
var WB_SMALL='padding:6px;border:2px solid var(--phx-border);border-radius:6px;background:var(--phx-bg);font-size:12px;color:var(--phx-text);box-sizing:border-box;outline:none';

function wbEditCard(path, root){
  var st=window.__plgEdit; if(!st||!st.wb)return;
  var node=wbGet(root,path)||{};
  var ov=document.createElement('div'); ov.className='modal-overlay';
  ov.innerHTML='<div class="modal-box" style="max-width:460px;max-height:80vh;overflow:auto">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:12px">编辑菜单项</div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">说明（玩家看到）</div>'
    +'<input id="wb-e-desc" value="'+escHtml(node.说明||'')+'" style="'+WB_INPUT+'">'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">触发词（每行一个）</div>'
    +'<textarea id="wb-e-trig" rows="2" style="'+WB_INPUT+';resize:vertical">'+escHtml((node.触发词||[]).join('\n'))+'</textarea>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">功能简介（可选）</div>'
    +'<input id="wb-e-usage" value="'+escHtml(node.功能简介||'')+'" style="'+WB_INPUT+'">'
    +'<label style="display:flex;align-items:center;gap:6px;margin:10px 0;font-size:13px">'
    +'<input id="wb-e-op" type="checkbox"'+(node.仅OP可用?' checked':'')+'> 仅OP可用</label>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">参数（可选，玩家触发时可带）</div>'
    +'<div id="wb-e-args"></div>'
    +'<div id="wb-e-action"></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px">'
    +'<button class="bs-btn bs-btn-cancel" onclick="closeModalOverlay(this)">取消</button>'
    +'<button class="bs-btn bs-btn-confirm" onclick="wbEditSave()">确定</button></div></div>';
  document.body.appendChild(ov);
  window.__wbEdit={root:root,path:path,node:node,
    act: JSON.parse(JSON.stringify(node.动作||{类型:'指令',指令:['']})),
    args: JSON.parse(JSON.stringify(node.参数||[]))};
  wbRenderArgs();
  wbRenderActionEditor();
}

function wbEditSave(){
  var e=window.__wbEdit; if(!e)return;
  var node=e.node;
  node.说明=(document.getElementById('wb-e-desc').value||'').trim();
  node.触发词=document.getElementById('wb-e-trig').value.split('\n').map(function(s){return s.trim()}).filter(Boolean);
  node.功能简介=(document.getElementById('wb-e-usage').value||'').trim();
  node.仅OP可用=!!document.getElementById('wb-e-op').checked;
  node.参数=e.args;
  node.动作=e.act;
  wbSet(e.root, e.path, node);
  var st=window.__plgEdit;
  if(st&&st.id) wbMode(st.id,'gui');
  var ov=document.querySelector('.modal-overlay'); if(ov) ov.remove();
}

/* 参数编辑器 */
function wbRenderArgs(){
  var e=window.__wbEdit; var box=document.getElementById('wb-e-args'); if(!box)return;
  var rows=(e.args||[]).map(function(a,i){
    return '<div style="display:flex;gap:6px;margin-bottom:6px;align-items:center">'
      +'<input data-ai="'+i+'" data-f="参数名" value="'+escHtml(a.参数名||'')+'" placeholder="参数名" style="flex:1;'+WB_SMALL+'">'
      +'<select data-ai="'+i+'" data-f="类型" style="'+WB_SMALL+'">'
      +['str','int','float','bool'].map(function(t){return '<option value="'+t+'"'+(a.类型===t?' selected':'')+'>'+t+'</option>'}).join('')+'</select>'
      +'<input data-ai="'+i+'" data-f="默认值" value="'+(a.默认值==null||a.默认值===false?'':a.默认值)+'" placeholder="默认值" style="width:80px;'+WB_SMALL+'">'
      +'<button class="btn" style="padding:4px 8px" onclick="wbArgDel('+i+')">×</button></div>';
  }).join('');
  box.innerHTML=rows+'<button class="btn" style="width:auto;padding:4px 10px" onclick="wbArgAdd()">＋ 参数</button>';
  box.querySelectorAll('[data-f]').forEach(function(el){
    el.addEventListener('input',function(){ wbArgField(el); });
    el.addEventListener('change',function(){ wbArgField(el,true); });
  });
}
function wbArgField(el, isChange){
  var e=window.__wbEdit; var a=e.args[+el.dataset.ai]; if(!a)return;
  var f=el.dataset.f, v=el.value;
  if(f==='参数名'){ a.参数名=v; return; }
  if(f==='类型'){ a.类型=v; return; }
  if(f==='默认值'){
    if(v===''){ a.默认值=null; return; }
    if(a.类型==='int') a.默认值=parseInt(v);
    else if(a.类型==='float') a.默认值=parseFloat(v);
    else if(a.类型==='bool') a.默认值=(v==='true'||v==='1');
    else a.默认值=v;
  }
}
function wbArgAdd(){
  var e=window.__wbEdit; if(!e)return; e.args.push({参数名:'',类型:'str',默认值:null}); wbRenderArgs();
}
function wbArgDel(i){
  var e=window.__wbEdit; if(!e)return; e.args.splice(i,1); wbRenderArgs();
}

/* 动作编辑器（主动作） */
function wbRenderActionEditor(){
  var e=window.__wbEdit; if(!e)return;
  var box=document.getElementById('wb-e-action'); if(!box)return;
  var act=e.act;
  var sel='<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">动作</div>'
    +'<select id="wb-a-type" style="'+WB_INPUT+'">'
    +'<option value="指令"'+(act.类型==='指令'?' selected':'')+'>执行指令</option>'
    +'<option value="子菜单"'+(act.类型==='子菜单'?' selected':'')+'>子菜单</option>'
    +'<option value="判断"'+(act.类型==='判断'?' selected':'')+'>判断</option></select>';
  box.innerHTML=sel+'<div id="wb-a-body"></div>';
  document.getElementById('wb-a-type').addEventListener('change',function(){
    var t=this.value;
    e.act={类型:t};
    if(t==='指令') e.act.指令=[''];
    if(t==='子菜单') e.act.子菜单=e.act.子菜单||[];
    if(t==='判断') e.act.判断={条件:{类型:'是否OP'},成功:{类型:'指令',指令:['']},失败:{类型:'指令',指令:['']},成功提示:'',失败提示:''};
    wbRenderActionBody();
  });
  wbRenderActionBody();
}
function wbRenderActionBody(){
  var e=window.__wbEdit; var act=e.act; var box=document.getElementById('wb-a-body'); if(!box)return;
  if(act.类型==='指令'){
    box.innerHTML='<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">指令（每行一条，支持 [玩家名] [参数:N]）</div>'
      +'<textarea id="wb-a-cmds" rows="3" style="'+WB_INPUT+';resize:vertical">'+escHtml((act.指令||[]).join('\n'))+'</textarea>';
    document.getElementById('wb-a-cmds').addEventListener('input',function(){
      e.act.指令=this.value.split('\n').map(function(s){return s.trim()}).filter(Boolean);
    });
  } else if(act.类型==='子菜单'){
    box.innerHTML='<div style="font-size:12px;color:var(--phx-text-secondary);padding:8px 0">子项用卡片树的「＋子项」添加（保存后生效）</div>';
  } else if(act.类型==='判断'){
    box.innerHTML='<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">判断条件</div>'
      +'<div id="wb-cond"></div>'
      +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">成功提示（可选）</div>'
      +'<input id="wb-a-oktip" value="'+escHtml(act.判断.成功提示||'')+'" style="'+WB_INPUT+'">'
      +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">失败提示（可选）</div>'
      +'<input id="wb-a-failtip" value="'+escHtml(act.判断.失败提示||'')+'" style="'+WB_INPUT+'">'
      +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:10px 0 4px;border-top:1px solid var(--phx-border-light);padding-top:8px">成功时执行</div>'
      +'<div id="wb-a-ok"></div>'
      +'<div style="font-size:12px;color:var(--phx-text-secondary);margin:10px 0 4px;border-top:1px solid var(--phx-border-light);padding-top:8px">失败时执行</div>'
      +'<div id="wb-a-fail"></div>';
    document.getElementById('wb-a-oktip').addEventListener('input',function(){ e.act.判断.成功提示=this.value; });
    document.getElementById('wb-a-failtip').addEventListener('input',function(){ e.act.判断.失败提示=this.value; });
    wbRenderCond();
    wbRenderBranch('wb-a-ok','ok');
    wbRenderBranch('wb-a-fail','fail');
  }
}

/* 判断分支动作编辑器（成功/失败，各是一个动作） */
function wbRenderBranch(containerId, key){
  var e=window.__wbEdit; if(!e||!e.act.判断)return;
  var box=document.getElementById(containerId); if(!box)return;
  var b=e.act.判断[key];
  if(!b) b=e.act.判断[key]={类型:'指令',指令:['']};
  var sel='<select id="wb-b-'+key+'-type" style="'+WB_INPUT+'">'
    +'<option value="指令"'+(b.类型==='指令'?' selected':'')+'>执行指令</option>'
    +'<option value="子菜单"'+(b.类型==='子菜单'?' selected':'')+'>子菜单</option>'
    +'<option value="判断"'+(b.类型==='判断'?' selected':'')+'>判断</option></select>';
  box.innerHTML=sel+'<div id="wb-b-'+key+'-body"></div>';
  document.getElementById('wb-b-'+key+'-type').addEventListener('change',function(){
    var t=this.value, nb={类型:t};
    if(t==='指令') nb.指令=[''];
    if(t==='子菜单') nb.子菜单=[];
    if(t==='判断') nb.判断={条件:{类型:'是否OP'},成功:{类型:'指令',指令:['']},失败:{类型:'指令',指令:['']}};
    e.act.判断[key]=nb;
    wbRenderBranchBody(key);
  });
  wbRenderBranchBody(key);
}
function wbRenderBranchBody(key){
  var e=window.__wbEdit; var b=e.act.判断[key];
  var box=document.getElementById('wb-b-'+key+'-body'); if(!box)return;
  if(b.类型==='指令'){
    box.innerHTML='<textarea id="wb-b-'+key+'-cmds" rows="2" style="'+WB_INPUT+';margin-top:6px;resize:vertical">'+escHtml((b.指令||[]).join('\n'))+'</textarea>';
    document.getElementById('wb-b-'+key+'-cmds').addEventListener('input',function(){
      b.指令=this.value.split('\n').map(function(s){return s.trim()}).filter(Boolean);
    });
  } else if(b.类型==='子菜单'){
    box.innerHTML='<div style="font-size:12px;color:var(--phx-text-secondary);padding:6px 0">子项在卡片树中维护</div>';
  } else if(b.类型==='判断'){
    box.innerHTML='<div style="font-size:12px;color:var(--phx-text-secondary);padding:6px 0">判断里再嵌套判断较复杂，建议此分支用指令或子菜单</div>';
  }
}

/* 条件编辑器 */
var WB_COND_TYPES={是否OP:'是否OP',是否名单内:'是否名单内',数值范围:'数值范围',目标在线:'目标在线',服务器数值:'服务器数值'};
function wbRenderCond(){
  var e=window.__wbEdit; var cond=e.act.判断.条件||{};
  var box=document.getElementById('wb-cond'); if(!box)return;
  var opts=Object.keys(WB_COND_TYPES).map(function(k){return '<option value="'+k+'"'+(cond.类型===k?' selected':'')+'>'+WB_COND_TYPES[k]+'</option>'}).join('');
  box.innerHTML='<select id="wb-cond-type" style="'+WB_INPUT+'">'+opts+'</select><div id="wb-cond-body"></div>';
  document.getElementById('wb-cond-type').addEventListener('change',function(){
    e.act.判断.条件={类型:this.value};
    wbRenderCondBody();
  });
  wbRenderCondBody();
}
function wbRenderCondBody(){
  var e=window.__wbEdit; var cond=e.act.判断.条件; var box=document.getElementById('wb-cond-body'); if(!box)return;
  var h='';
  if(cond.类型==='是否名单内'){
    h='<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">名单（每行一个玩家名）</div>'
      +'<textarea id="wb-cond-list" rows="3" style="'+WB_INPUT+';resize:vertical">'+escHtml((cond.名单||[]).join('\n'))+'</textarea>';
  } else if(cond.类型==='数值范围'){
    h='<div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;align-items:center">'
      +'<label style="font-size:12px;color:var(--phx-text-secondary)">第<input id="wb-cond-idx" type="number" value="'+(cond.参数序号||1)+'" min="1" style="width:50px;'+WB_SMALL+'">个参数</label>'
      +'<input id="wb-cond-min" type="number" placeholder="最小值" value="'+(cond.最小值==null?'':cond.最小值)+'" style="flex:1;min-width:80px;'+WB_SMALL+'">'
      +'<input id="wb-cond-max" type="number" placeholder="最大值" value="'+(cond.最大值==null?'':cond.最大值)+'" style="flex:1;min-width:80px;'+WB_SMALL+'"></div>';
  } else if(cond.类型==='目标在线'){
    h='<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">目标（支持 [玩家名] [参数:N]）</div>'
      +'<input id="wb-cond-target" value="'+escHtml(cond.目标||'')+'" style="'+WB_INPUT+'">';
  } else if(cond.类型==='服务器数值'){
    h='<div style="font-size:12px;color:var(--phx-text-secondary);margin:8px 0 4px">查询命令（支持占位符，如 scoreboard players get [玩家名] 积分）</div>'
      +'<input id="wb-cond-cmd" value="'+escHtml(cond.命令||'')+'" style="'+WB_INPUT+'">'
      +'<div style="display:flex;gap:8px;margin-top:8px;align-items:center">'
      +'<select id="wb-cond-op" style="'+WB_SMALL+'">'+['>','>=','<','<=','==','!='].map(function(o){return '<option value="'+o+'"'+(cond.操作符===o?' selected':'')+'>'+o+'</option>'}).join('')+'</select>'
      +'<input id="wb-cond-cmp" type="number" value="'+(cond.比较值==null?0:cond.比较值)+'" style="width:90px;'+WB_SMALL+'"></div>';
  }
  box.innerHTML=h;
  if(cond.类型==='是否名单内'){
    document.getElementById('wb-cond-list').addEventListener('input',function(){ cond.名单=this.value.split('\n').map(function(s){return s.trim()}).filter(Boolean); });
  } else if(cond.类型==='数值范围'){
    document.getElementById('wb-cond-idx').addEventListener('input',function(){ cond.参数序号=parseInt(this.value)||1; });
    document.getElementById('wb-cond-min').addEventListener('input',function(){ cond.最小值=this.value===''?null:parseFloat(this.value); });
    document.getElementById('wb-cond-max').addEventListener('input',function(){ cond.最大值=this.value===''?null:parseFloat(this.value); });
  } else if(cond.类型==='目标在线'){
    document.getElementById('wb-cond-target').addEventListener('input',function(){ cond.目标=this.value; });
  } else if(cond.类型==='服务器数值'){
    document.getElementById('wb-cond-cmd').addEventListener('input',function(){ cond.命令=this.value; });
    document.getElementById('wb-cond-op').addEventListener('change',function(){ cond.操作符=this.value; });
    document.getElementById('wb-cond-cmp').addEventListener('input',function(){ cond.比较值=parseFloat(this.value)||0; });
  }
}
