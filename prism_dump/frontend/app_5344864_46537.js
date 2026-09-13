// AI 帮写：插件编辑器内嵌的 ChatGPT 式助手（全屏页，移动端单列大字号）。
// 复用 openSubPage 全屏子页；模型自配置（Claude/OpenAI兼容）、流式回复、
// 工具调用（网络/搜索/读写插件/游戏 game API），AI 可直接把代码写入插件文件。

/* ═══ 入口 ═══ */

var __ai = { pluginId:'', pluginType:'lua', modelName:'', mode:'', sessionName:'', messages:[], busy:false, models:[] };

// 从插件编辑器进入：openAIAssist(pluginId)。pluginType 可省（由后端按文件类型判定）。
function openAIAssist(pluginId){
  __ai = { pluginId:pluginId||'', pluginType:'lua', modelName:'', mode:'', sessionName:'', messages:[], busy:false, models:[], totalIn:0, totalOut:0, liveOut:0, lastIn:0, lastOut:0 };
  var title='AI 帮写';
  delete subPageCache[title];
  var h='<style>'
    +'#ai-chat{overflow-x:hidden}'
    +'#ai-chat pre{white-space:pre-wrap!important;word-break:break-word!important;max-width:100%;box-sizing:border-box}'
    +'#ai-chat code{white-space:pre-wrap!important;word-break:break-word!important}'
    +'#ai-chat > div{min-width:0;max-width:100%;box-sizing:border-box;overflow-wrap:break-word;flex-shrink:0}'
    +'#ai-chat table{max-width:100%;display:block;overflow-x:auto}'
    +'/* 代码块强制黑底浅字，保证在任何主题/背景图下可读 */'
    +'#ai-chat pre{background:#0d1117!important;color:#e6edf3!important;border:1px solid #30363d;border-radius:8px;padding:12px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;line-height:1.6}'
    +'#ai-chat pre code{background:transparent!important;color:inherit!important;padding:0;border:none}'
    +'#ai-chat :not(pre)>code{background:#0d1117;color:#ffd7a0;padding:2px 5px;border-radius:4px;font-size:12px}'
    +'#ai-chat .hljs,#ai-chat .hljs-ln{background:transparent!important}'
    +'</style>'
    +'<div style="display:flex;flex-direction:column;height:100%;box-sizing:border-box;min-height:0">'
    +'<div style="flex-shrink:0">'
    +'<div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;flex-wrap:wrap">'
    +'<div id="ai-model-box" style="flex:1;min-width:150px"></div>'
    +'<div style="display:flex;gap:6px;flex-shrink:0">'
    +'<button class="btn" style="width:auto;padding:9px 11px;font-size:12px;margin:0" onclick="aiOpenManage()">模型设置</button>'
    +'<button class="btn" style="width:auto;padding:9px 11px;font-size:12px;margin:0" onclick="aiOpenSkills()">技能库</button>'
    +'<button class="btn" style="width:auto;padding:9px 11px;font-size:12px;margin:0" onclick="aiOpenSession()">会话/存档</button></div></div>'
    +'<div style="display:flex;align-items:center;justify-content:flex-end;margin-bottom:8px">'
    +'<span id="ai-token" style="font-size:11px;color:var(--phx-text-secondary)"></span></div>'
    +'<div id="ai-nomodel" class="gone" style="font-size:13px;color:var(--phx-text-secondary);padding:10px;border:1px dashed rgba(128,128,128,.4);border-radius:8px;margin-bottom:8px">'
    +'还没有模型。点右上角「模型设置」添加一个（填入供应商/请求地址/密钥，可一键获取模型列表）。</div>'
    +'</div>'
    +'<div id="ai-chat" style="flex:1;min-height:0;overflow-y:auto;overflow-x:hidden;display:flex;flex-direction:column;gap:10px;padding:4px 2px 10px;-webkit-overflow-scrolling:touch"></div>'
    +'<div id="ai-input-row" style="display:flex;gap:8px;align-items:flex-end;flex-shrink:0;margin-top:8px;padding-top:8px;border-top:1px solid rgba(128,128,128,.12)">'
    +'<textarea id="ai-input" rows="1" placeholder="描述你想要的功能…" style="flex:1;min-width:0;height:48px;min-height:48px;max-height:120px;padding:10px 12px;border:2px solid var(--phx-border);border-radius:10px;background:var(--phx-bg);color:var(--phx-text);font-size:15px;outline:none;resize:none;box-sizing:border-box;line-height:1.5"></textarea>'
    +'<button id="ai-send" class="btn" title="发送" style="width:48px;flex:0 0 auto;height:48px;padding:0;margin:0;display:flex;align-items:center;justify-content:center" onclick="aiSend()">'+AI_ICON_SEND+'</button></div>'
    +'</div>';
  openSubPage(title,h);
  document.getElementById('ai-input').addEventListener('keydown',function(e){ if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();aiSend();} });
  document.getElementById('ai-input').addEventListener('input',function(){ this.style.height='48px'; this.style.height=Math.min(this.scrollHeight,120)+'px'; });
  aiLoadModels();
  aiResume(); // 读回最近一个会话
}

/* ═══ 模型管理 ═══ */

async function aiLoadModels(){
  var r=await A('GET','/api/ai/models');
  __ai.models=r.ok?(r.models||[]):[];
  // 记忆上次选择:优先 localStorage,其次第一个模型,都不存在则空。
  var saved=null;
  try{saved=localStorage.getItem('ai_last_model');}catch(e){}
  var found=saved&&__ai.models.some(function(m){return m.name===saved});
  if(!__ai.modelName){
    if(found)__ai.modelName=saved;
    else if(__ai.models.length)__ai.modelName=__ai.models[0].name;
    else __ai.modelName='';
  }
  var box=document.getElementById('ai-model-box');
  if(box){
    if(!box._dd)box._dd=prismDropdown(box,{placeholder:'选择模型',onChange:function(v){aiPickModel(v);}});
    box._dd.setOptions(__ai.models.map(function(m){return {value:m.name,label:m.name+' ('+m.model_id+')'};}));
    box._dd.setValue(__ai.modelName||'');
  }
  var nm=document.getElementById('ai-nomodel');
  if(nm)nm.classList.toggle('gone',__ai.models.length>0);
  var sb=document.getElementById('ai-send');
  if(sb)sb.disabled=!__ai.modelName;
}
function aiPickModel(v){ __ai.modelName=v; var sb=document.getElementById('ai-send'); if(sb)sb.disabled=!v; var box=document.getElementById('ai-model-box'); if(box&&box._dd)box._dd.setValue(v); try{localStorage.setItem('ai_last_model',v||'');}catch(e){} }

// 模型管理弹窗：已配置列表 + 添加表单
function aiOpenManage(){
  var ov=document.createElement('div');ov.className='modal-overlay';
  ov.innerHTML='<div class="modal-box" style="max-width:420px;max-height:80vh;overflow-y:auto">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:4px">模型管理</div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:12px">配置你自己的模型（密钥保存在本机）</div>'
    +'<div id="ai-mlist" style="margin-bottom:12px"></div>'
    +'<div style="font-weight:600;font-size:13px;margin-bottom:8px">＋ 添加 / 编辑模型</div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">供应商</div>'
    +'<div id="ai-provider-box" style="margin-bottom:10px"></div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">请求地址 BaseURL（如 https://api.deepseek.com 或 http://localhost:11434）</div>'
    +'<input id="ai-base" type="text" placeholder="https://api.deepseek.com" style="width:100%;padding:9px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:14px;margin-bottom:10px;box-sizing:border-box;outline:none">'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">API 密钥</div>'
    +'<input id="ai-key" type="password" placeholder="sk-…" style="width:100%;padding:9px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:14px;margin-bottom:10px;box-sizing:border-box;outline:none">'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">模型 ID（可点下方按钮获取列表）</div>'
    +'<div style="display:flex;gap:8px;margin-bottom:10px">'
    +'<input id="ai-mid" type="text" placeholder="deepseek-chat" style="flex:1;padding:9px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:14px;box-sizing:border-box;outline:none">'
    +'<button class="btn" style="width:auto;padding:9px 12px;font-size:13px;flex-shrink:0" onclick="aiFetchModels()">获取模型列表</button></div>'
    +'<div id="ai-mcand" class="gone" style="margin-bottom:10px"></div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">本地自定义名（自己起，方便记忆）</div>'
    +'<input id="ai-name" type="text" placeholder="我的 DeepSeek" style="width:100%;padding:9px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:14px;margin-bottom:10px;box-sizing:border-box;outline:none">'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:4px">思考强度</div>'
    +'<select id="ai-thinking" style="width:100%;padding:9px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:14px;margin-bottom:10px;outline:none">'
    +'<option value="off">关闭</option><option value="low">低</option><option value="medium" selected>中</option><option value="high">高</option></select>'
    +'<div style="display:flex;align-items:center;gap:8px;font-size:14px;margin-bottom:12px">'
    +'<label class="lbl-cb" style="margin:0;cursor:pointer"><input type="checkbox" id="ai-stream" checked><span class="tgl"></span></label>'
    +'<span>流式输出（推荐，边生成边显示）</span></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end">'
    +'<button class="bs-btn bs-btn-cancel" onclick="closeOverlay(this.closest(\'.modal-overlay\'))">关闭</button>'
    +'<button class="bs-btn bs-btn-confirm" onclick="aiSaveModel()">保存模型</button></div></div>';
  document.body.appendChild(ov);
  ov.addEventListener('click',function(e){if(e.target===ov)closeOverlay(ov)});
  // 供应商下拉用自定义组件
  var pbox=document.getElementById('ai-provider-box');
  if(pbox){
    if(!pbox._dd)pbox._dd=prismDropdown(pbox,{placeholder:'选择供应商'});
    pbox._dd.setOptions([{value:'openai',label:'OpenAI 及兼容系（DeepSeek/Qwen/GLM/Ollama…）'},{value:'anthropic',label:'Claude（Anthropic）'}]);
    pbox._dd.setValue('openai');
  }
  aiRenderMlist();
}
function aiRenderMlist(){
  var el=document.getElementById('ai-mlist'); if(!el)return;
  if(!__ai.models.length){ el.innerHTML='<div style="font-size:13px;color:var(--phx-text-secondary)">暂无模型</div>'; return; }
  el.innerHTML=__ai.models.map(function(m){
    var actions;
    if(m.builtin){
      // 内置模型：显示「内置」标签，不可删除/编辑
      actions='<span style="font-size:11px;color:var(--phx-accent);border:1px solid var(--phx-accent);border-radius:4px;padding:1px 6px;white-space:nowrap">内置</span>';
    }else{
      actions='<button class="tsk-act" onclick="aiEditModel(\''+escHtml(m.name)+'\')">改</button>'
        +'<button class="tsk-act" onclick="aiDeleteModel(\''+escHtml(m.name)+'\')">删</button>';
    }
    return '<div style="display:flex;align-items:center;gap:8px;padding:8px 10px;border-radius:8px;background:rgba(128,128,128,.06);margin-bottom:6px">'
      +'<div style="flex:1;min-width:0"><div style="font-size:13px;font-weight:600">'+escHtml(m.name)+'</div>'
      +'<div style="font-size:11px;color:var(--phx-text-secondary)">'+escHtml(m.provider)+' · '+escHtml(m.model_id)+'</div></div>'
      +actions+'</div>';
  }).join('');
}
function aiDeleteModel(name){
  showConfirm({title:'删除模型',message:'确定删除模型「'+name+'」吗？',confirmText:'删除',onConfirm:function(){
    A('DELETE','/api/ai/models',{name:name}).then(function(){
      if(__ai.modelName===name)__ai.modelName='';
      aiLoadModels(); aiRenderMlist();
    });
  }});
}
async function aiEditModel(name){
  var m=__ai.models.filter(function(x){return x.name===name})[0];
  if(!m)return;
  var pb=document.getElementById('ai-provider-box'); if(pb&&pb._dd)pb._dd.setValue(m.provider);
  document.getElementById('ai-base').value=m.base_url;
  document.getElementById('ai-key').value='';
  document.getElementById('ai-key').placeholder=m.api_key||'';
  document.getElementById('ai-mid').value=m.model_id;
  document.getElementById('ai-name').value=m.name;
  document.getElementById('ai-thinking').value=m.thinking||'off';
  document.getElementById('ai-stream').checked=!!m.streaming;
}
// 拉取该供应商模型列表 → 显示候选
async function aiFetchModels(){
  var pbox=document.getElementById('ai-provider-box'); var prov=(pbox&&pbox._dd)?pbox._dd.getValue():'openai';
  var base=document.getElementById('ai-base').value.trim();
  var key=document.getElementById('ai-key').value.trim();
  var cand=document.getElementById('ai-mcand');
  if(!base){T('请先填请求地址','e');return;}
  T('正在获取模型列表…','w');
  var r=await A('POST','/api/ai/models/fetch',{provider:prov,base_url:base,api_key:key});
  if(!r.ok){T(r.error||'获取失败','e');return;}
  var ids=r.models||[];
  if(!ids.length){T('该地址没有返回模型','w');return;}
  cand.classList.remove('gone');
  cand.innerHTML='<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:6px">点选一个填入模型ID：</div>'
    +'<div style="display:flex;flex-wrap:wrap;gap:6px">'+ids.map(function(id){
      return '<button class="tsk-act" onclick="document.getElementById(\'ai-mid\').value=\''+escHtml(id).replace(/'/g,"\\'")+'\'">'+escHtml(id)+'</button>';
    }).join('')+'</div>';
  T('找到 '+ids.length+' 个模型','o');
}
async function aiSaveModel(){
  var m={
    provider:(function(){var pb=document.getElementById('ai-provider-box');return (pb&&pb._dd)?pb._dd.getValue():'openai'})(),
    base_url:document.getElementById('ai-base').value.trim(),
    api_key:document.getElementById('ai-key').value.trim(),
    model_id:document.getElementById('ai-mid').value.trim(),
    name:document.getElementById('ai-name').value.trim(),
    thinking:document.getElementById('ai-thinking').value,
    streaming:document.getElementById('ai-stream').checked
  };
  if(!m.name){T('请填本地自定义名','e');return;}
  if(!m.base_url){T('请填请求地址','e');return;}
  if(!m.model_id){T('请填模型ID','e');return;}
  T('保存中…','w');
  var r=await A('POST','/api/ai/models',m);
  if(!r.ok){T(r.error||'保存失败','e');return;}
  T('模型已保存','o');
  closeOverlay(document.querySelector('.modal-overlay'));
  __ai.modelName=m.name;
  aiLoadModels();
}

/* ═══ 技能（从 GitHub 拉取的知识包） ═══ */

// 技能管理弹窗：列出可加载的技能，加载后注入 AI 上下文。
function aiOpenSkills(){
  var ov=document.createElement('div');ov.className='modal-overlay';
  ov.innerHTML='<div class="modal-box" style="max-width:420px;max-height:80vh;overflow-y:auto">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:4px">技能知识库</div>'
    +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-bottom:12px">加载后会把对应知识注入 AI 的上下文（内容来自 GitHub）。用不到时可卸载节省上下文。</div>'
    +'<div id="ai-sklist"></div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px">'
    +'<button class="bs-btn bs-btn-cancel" onclick="closeOverlay(this.closest(\'.modal-overlay\'))">关闭</button></div></div>';
  document.body.appendChild(ov);
  ov.addEventListener('click',function(e){if(e.target===ov)closeOverlay(ov)});
  aiRenderSkills();
}
async function aiRenderSkills(){
  var el=document.getElementById('ai-sklist'); if(!el)return;
  el.innerHTML='<div style="font-size:13px;color:var(--phx-text-secondary)">加载中…</div>';
  var r=await A('GET','/api/ai/skills');
  var skills=r.ok?(r.skills||[]):[];
  if(!skills.length){ el.innerHTML='<div style="font-size:13px;color:var(--phx-text-secondary)">暂无可加载技能</div>'; return; }
  el.innerHTML=skills.map(function(s){
    return '<div style="padding:10px;border-radius:8px;background:rgba(128,128,128,.06);margin-bottom:8px">'
      +'<div style="display:flex;align-items:center;gap:8px">'
      +'<div style="flex:1;min-width:0"><div style="font-size:14px;font-weight:600">'+escHtml(s.name)+'</div>'
      +'<div style="font-size:12px;color:var(--phx-text-secondary);margin-top:2px">'+escHtml(s.description)+'</div></div>'
      +'<button class="tsk-act" style="'+(s.loaded?'opacity:.6':'')+'" onclick="aiToggleSkill(\''+escHtml(s.id)+'\','+(s.loaded?'true':'false')+')">'+(s.loaded?'已加载 · 卸载':'加载')+'</button></div></div>';
  }).join('');
}
function aiToggleSkill(id,loaded){
  if(loaded){
    showConfirm({title:'卸载技能',message:'确定卸载技能「'+id+'」吗？',confirmText:'卸载',onConfirm:function(){
      A('DELETE','/api/ai/skills',{id:id}).then(function(){ T('已卸载','o'); aiRenderSkills(); });
    }});
    return;
  }
  T('正在加载技能…','w');
  A('POST','/api/ai/skills',{id:id}).then(function(r){
    if(!r.ok){ T(r.error||'加载失败','e'); return; }
    T('已加载技能（'+r.chars+' 字符）','o');
    aiRenderSkills();
  });
}

/* ═══ 用户询问（AI 弹窗让用户选） ═══ */

function aiShowQuestion(reqID, question, options){
  var opts=options&&options.length?options:['继续','换一种做法','取消'];
  var ov=document.createElement('div');ov.className='modal-overlay';
  ov.innerHTML='<div class="modal-box" style="max-width:360px">'
    +'<div style="font-size:15px;font-weight:800;margin-bottom:10px">'+escHtml(question)+'</div>'
    +opts.map(function(o){
      return '<button class="btn" style="width:100%;padding:13px;margin-bottom:8px;font-size:15px;text-align:left" onclick="aiAnswerQuestion(\''+reqID+'\',this.textContent);closeOverlay(this.closest(\'.modal-overlay\'))">'+escHtml(o)+'</button>';
    }).join('')
    +'<button class="bs-btn bs-btn-cancel" style="width:100%;margin-top:4px" onclick="closeOverlay(this.closest(\'.modal-overlay\'))">暂不回答</button></div>';
  document.body.appendChild(ov);
  ov.addEventListener('click',function(e){if(e.target===ov)closeOverlay(ov)});
}
async function aiAnswerQuestion(reqID,answer){
  await A('POST','/api/ai/answer',{req_id:reqID,answer:answer});
}

/* ═══ 会话 / 存档管理 ═══ */

// 侧边栏抽屉：会话（自动保存）+ 存档（手动）
function aiTimestamp(){
  var d=new Date(); var p=function(n){return (n<10?'0':'')+n;};
  return (d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());
}
// 侧边栏抽屉：会话（自动保存，创建时间命名）+ 改动存档（手动）
function aiOpenSession(){
  var mask=document.createElement('div');
  mask.id='ai-drawer-mask';
  mask.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:1000;opacity:0;transition:opacity .25s';
  var panel=document.createElement('div');
  panel.id='ai-drawer';
  panel.style.cssText='position:fixed;top:0;right:0;bottom:0;width:84%;max-width:340px;padding-top:env(safe-area-inset-top,0px);background:var(--phx-bg,#1e293b);color:var(--phx-text);z-index:1001;transform:translateX(102%);transition:transform .25s;display:flex;flex-direction:column;box-shadow:-4px 0 16px rgba(0,0,0,.4)';
  panel.innerHTML='<div style="padding:14px 16px;font-size:16px;font-weight:800;border-bottom:1px solid rgba(128,128,128,.15);display:flex;align-items:center;flex-shrink:0">'
    +'<span style="flex:1">会话与存档</span>'
    +'<button class="btn" style="width:auto;padding:6px 12px;font-size:13px;margin:0" onclick="aiNewChat()">新建会话</button>'
    +'<button style="background:none;border:none;font-size:22px;color:var(--phx-text-secondary);padding:0 4px;margin-left:6px;cursor:pointer;line-height:1" onclick="aiCloseSession()">×</button></div>'
    +'<div style="padding:12px 16px;font-size:12px;color:var(--phx-text-secondary);border-bottom:1px solid rgba(128,128,128,.1);flex-shrink:0">'
    +'对话会自动保存（创建时间命名），点会话可读回；改动存档由你手动创建。</div>'
    +'<div style="flex:1;overflow-y:auto;padding:0 16px 20px">'
    +'<div style="font-weight:600;font-size:13px;margin:14px 0 6px">我的会话</div>'
    +'<div id="ai-sess-list" style="margin-bottom:8px"></div>'
    +'<div style="font-weight:600;font-size:13px;margin:14px 0 6px">改动存档</div>'
    +'<div style="display:flex;gap:8px;margin-bottom:8px">'
    +'<input id="ai-snap-name" type="text" placeholder="存档名称" style="flex:1;padding:9px;border:2px solid var(--phx-border);border-radius:8px;background:var(--phx-bg);color:var(--phx-text);font-size:14px;box-sizing:border-box;outline:none">'
    +'<button class="btn" style="width:auto;padding:9px 12px;font-size:13px;flex-shrink:0;margin:0" onclick="aiSaveSnapshot()">存档</button></div>'
    +'<div id="ai-snap-list"></div>'
    +'</div>';
  document.body.appendChild(mask); document.body.appendChild(panel);
  requestAnimationFrame(function(){ setTimeout(function(){ mask.style.opacity='1'; panel.style.transform='translateX(0)'; },10); });
  mask.onclick=function(){ aiCloseSession(); };
  aiRenderSessionList();
  aiRenderSnapshotList();
}
function aiCloseSession(){
  var mask=document.getElementById('ai-drawer-mask');
  var panel=document.getElementById('ai-drawer');
  if(!mask)return;
  if(panel)panel.style.transform='translateX(102%)';
  mask.style.opacity='0';
  setTimeout(function(){ if(mask)mask.remove(); if(panel)panel.remove(); },260);
}
function aiNewChat(){
  __ai.messages=[];
  __ai.totalIn=0; __ai.totalOut=0; __ai.liveOut=0; __ai.lastIn=0; __ai.lastOut=0; aiUpdateToken();
  __aiStream={cur:null,acc:'',timer:null,tools:{},thinking:null};
  var chat=document.getElementById('ai-chat'); if(chat)chat.innerHTML='';
  __ai.sessionName=aiTimestamp(); // 新会话以创建时间命名
  aiCloseSession();
}
// 自动保存当前对话到当前会话（创建时间命名）
function aiAutoSave(){
  if(!__ai.messages.length)return;
  if(!__ai.sessionName)__ai.sessionName=aiTimestamp();
  A('POST','/api/ai/sessions',{name:__ai.sessionName,plugin_id:__ai.pluginId,messages:__ai.messages});
}
// 打开页面时读回当前插件最近一个会话（按 plugin_id 隔离，不串到别的插件）
async function aiResume(){
  var r=await A('GET','/api/ai/sessions/recent?plugin_id='+encodeURIComponent(__ai.pluginId||''));
  if(!r.ok||!r.session||!(r.session.messages||[]).length)return;
  __ai.sessionName=r.session.name||aiTimestamp();
  __ai.messages=aiMapSession(r.session.messages||[]);
  __aiStream={cur:null,acc:'',timer:null,tools:{},thinking:null};
  var chat=document.getElementById('ai-chat'); if(chat)chat.innerHTML='';
  __ai.messages.forEach(function(m){ aiRenderArchived(m); });
  aiScrollChat(true);
}
// 读档/恢复：保留 tool_calls / tool_results（会话工具历史不丢）。
function aiMapSession(msgs){
  return (msgs||[]).map(function(m){
    var out={role:m.role==='assistant'?'assistant':'user',content:(m.content||m.text||'')};
    if(m.tool_calls)out.tool_calls=m.tool_calls;
    if(m.tool_results)out.tool_results=m.tool_results;
    return out;
  });
}
async function aiRenderSessionList(){
  var el=document.getElementById('ai-sess-list'); if(!el)return;
  var r=await A('GET','/api/ai/sessions?plugin_id='+encodeURIComponent(__ai.pluginId||''));
  var list=r.ok?(r.sessions||[]):[];
  if(!list.length){el.innerHTML='<div style="font-size:13px;color:var(--phx-text-secondary)">暂无会话</div>';return;}
  el.innerHTML=list.map(function(s){
    var cur=s.name===__ai.sessionName?'<span style="color:var(--phx-primary);font-size:11px">当前</span>':'';
    return '<div style="display:flex;align-items:center;gap:6px;padding:8px 10px;border-radius:8px;background:rgba(128,128,128,.06);margin-bottom:6px">'
      +'<div style="flex:1;min-width:0;font-size:13px;word-break:break-all">'+escHtml(s.name)+cur+'<div style="font-size:11px;color:var(--phx-text-secondary)">'+s.messages+' 条</div></div>'
      +'<button class="tsk-act" onclick="aiRenameSession(\''+escHtml(s.name)+'\')">改名</button>'
      +'<button class="tsk-act" onclick="aiLoadSession(\''+escHtml(s.name)+'\')">读档</button>'
      +'<button class="tsk-act" onclick="aiDeleteSession(\''+escHtml(s.name)+'\')">删</button></div>';
  }).join('');
}
async function aiLoadSession(name){
  var r=await A('POST','/api/ai/sessions/load',{name:name});
  if(!r.ok){T(r.error||'读档失败','e');return;}
  __ai.sessionName=name;
  __ai.messages=aiMapSession(r.session.messages||[]);
  __aiStream={cur:null,acc:'',timer:null,tools:{},thinking:null};
  var chat=document.getElementById('ai-chat'); if(chat)chat.innerHTML='';
  __ai.messages.forEach(function(m){ aiRenderArchived(m); });
  aiScrollChat(true);
  aiRenderSessionList();
  T('已读档会话','o');
}
function aiDeleteSession(name){
  showConfirm({title:'删除会话',message:'确定删除会话「'+name+'」吗？',confirmText:'删除',onConfirm:function(){
    A('DELETE','/api/ai/sessions',{name:name}).then(function(){
      if(__ai.sessionName===name)__ai.sessionName='';
      aiRenderSessionList();
    });
  }});
}
function aiRenameSession(oldName){
  showPrompt({title:'重命名会话',placeholder:'新的会话标题',default:oldName,onConfirm:function(v){
    var n=(v||'').trim();
    if(!n||n===oldName)return;
    A('POST','/api/ai/sessions/rename',{old_name:oldName,new_name:n}).then(function(r){
      if(!r.ok){T(r.error||'改名失败','e');return;}
      if(__ai.sessionName===oldName)__ai.sessionName=n;
      T('已改名','o'); aiRenderSessionList();
    });
  }});
}
async function aiSaveSnapshot(){
  var name=(document.getElementById('ai-snap-name').value||'').trim();
  if(!name){T('请填存档名称','e');return;}
  var r=await A('POST','/api/ai/snapshot',{name:name});
  if(!r.ok){T(r.error||'存档失败','e');return;}
  T('已存档改动','o'); aiRenderSnapshotList();
}
async function aiRenderSnapshotList(){
  var el=document.getElementById('ai-snap-list'); if(!el)return;
  var r=await A('GET','/api/ai/snapshot');
  var list=r.ok?(r.snapshots||[]):[];
  if(!list.length){el.innerHTML='<div style="font-size:13px;color:var(--phx-text-secondary)">暂无存档</div>';return;}
  el.innerHTML=list.map(function(s){
    return '<div style="display:flex;align-items:center;gap:8px;padding:8px 10px;border-radius:8px;background:rgba(128,128,128,.06);margin-bottom:6px">'
      +'<div style="flex:1;min-width:0;font-size:13px">'+escHtml(s.name)+'<div style="font-size:11px;color:var(--phx-text-secondary)">'+s.files+' 个文件</div></div>'
      +'<button class="tsk-act" onclick="aiRestoreSnapshot(\''+escHtml(s.name)+'\')">恢复</button>'
      +'<button class="tsk-act" onclick="aiDeleteSnapshot(\''+escHtml(s.name)+'\')">删</button></div>';
  }).join('');
}
function aiRestoreSnapshot(name){
  showConfirm({title:'恢复存档',message:'确定恢复存档「'+name+'」吗？将覆盖当前插件文件。',confirmText:'恢复',onConfirm:function(){
    A('POST','/api/ai/snapshot/restore',{name:name}).then(function(r){
      if(!r.ok){T(r.error||'恢复失败','e');return;}
      T('已恢复 '+r.restored+' 个文件','o');
    });
  }});
}
function aiDeleteSnapshot(name){
  showConfirm({title:'删除存档',message:'确定删除存档「'+name+'」吗？',confirmText:'删除',onConfirm:function(){
    A('DELETE','/api/ai/snapshot',{name:name}).then(function(){ aiRenderSnapshotList(); });
  }});
}

/* ═══ 聊天（流式） ═══ */

// 流式会话状态：cur=当前 AI 文本气泡，acc=已累积文本，tool=待填充结果的工具卡片。
var __aiStream={cur:null,acc:'',timer:null,tools:{},thinking:null};

// 发送/停止 图标（纯图标，避免文字占宽）。
var AI_ICON_SEND='<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>';
var AI_ICON_STOP='<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="6" width="12" height="12" rx="1"/></svg>';

function aiBubble(role,text){
  var el=document.createElement('div');
  var isUser=role==='user';
  // 助手气泡固定白底深字（任何主题/背景图下都清晰）；用户气泡保持主题主色。
  el.style.cssText='max-width:92%;min-width:0;padding:10px 12px;border-radius:12px;font-size:14px;line-height:1.6;white-space:pre-wrap;word-break:break-word;align-self:'+(isUser?'flex-end':'flex-start')+';background:'+(isUser?'var(--phx-primary)':'#ffffff')+';color:'+(isUser?'#fff':'#1f2937')+';box-shadow:'+(isUser?'none':'0 1px 2px rgba(0,0,0,.08)')+';border:'+(isUser?'none':'1px solid rgba(0,0,0,.06)');
  el.textContent=text;
  el.dataset.role=role;
  return el;
}
function aiAddMsg(role,text){
  var chat=document.getElementById('ai-chat'); if(!chat)return;
  var el=aiBubble(role,text);
  chat.appendChild(el);
  // 助手消息渲染 markdown（读档/续接时也能正常显示代码块、列表等）
  if(role!=='user')aiRenderStream(el,text);
  aiScrollChat();
}

// 读档/续接时渲染一条归档消息:含工具调用的 assistant 消息重绘工具卡,
// 含 tool_results 的 user 消息重绘结果卡。普通文本走 aiBubble。渲染后强制滚到底。
// 归档工具卡为只读展示(不进入流式 __aiStream.tools,避免干扰新回合状态)。
function aiRenderArchived(m){
  var chat=document.getElementById('ai-chat'); if(!chat)return;
  if(m&&m.tool_calls&&m.tool_calls.length){
    m.tool_calls.forEach(function(tc){
      var tid=tc.id||('tc_arc_'+Math.random().toString(36).slice(2));
      var param=(typeof tc.input==='string')?tc.input:JSON.stringify(tc.input||{});
      var card=aiToolCard(tid,tc.name,param);
      if(card){
        aiToolDone(card,'(已执行,结果见下)',false);
        card.body.style.display='none'; card.hint.textContent='查看参数与结果 ▸';
      }
    });
    if(m.content&&m.content.trim()){
      var el2=aiBubble('assistant',m.content); chat.appendChild(el2); aiRenderStream(el2,m.content);
    }
    aiScrollChat(true);
    return;
  }
  if(m&&m.tool_results&&m.tool_results.length){
    m.tool_results.forEach(function(tr){
      var nm = tr.id||'工具';
      var card=aiToolCard(('tc_res_'+Math.random().toString(36).slice(2)),nm,(tr.content||''));
      if(card){ aiToolDone(card,tr.content||'',!!tr.is_error); }
    });
    aiScrollChat(true);
    return;
  }
  aiAddMsg(m.role||'user',m.content||'');
  aiScrollChat(true);
}

// 对 marked 产出的 HTML 做代码高亮（单层 innerHTML，避免 textarea 叠黑影）。
function aiHighlightCode(html){
  var d=document.createElement('div'); d.innerHTML=html;
  d.querySelectorAll('pre code').forEach(function(c){
    var lang=''; var m=(c.className||'').match(/language-(\w+)/); if(m)lang=m[1].toLowerCase();
    var hl=highlightCode(c.textContent, lang==='lua'?'lua':(lang==='json'?'json':null));
    c.innerHTML=hl;
  });
  return d.innerHTML;
}
// 渲染 markdown（含代码高亮）；无 marked 时退回纯文本。
function aiRenderStream(el,text){
  if(typeof marked!=='undefined'&&marked.parse){
    try{ el.innerHTML=aiHighlightCode(marked.parse(text||'')); el.style.whiteSpace='normal'; return; }
    catch(e){}
  }
  el.textContent=text; el.style.whiteSpace='pre-wrap';
}
// 自动滚动到底部：仅在用户靠近底部（<80px）时才滚，用户上滑阅读时不打扰。
// force=true 时强制滚到底(读档/新会话用,避免会话跳/留在顶部)。
function aiScrollChat(force){
  var chat=document.getElementById('ai-chat'); if(!chat)return;
  if(!force&&chat.scrollHeight-chat.scrollTop-chat.clientHeight>80)return;
  chat.scrollTop=chat.scrollHeight;
}
// 新建一个 AI 文本气泡并加入聊天。
function aiStreamBubble(){
  var chat=document.getElementById('ai-chat'); if(!chat)return null;
  var el=aiBubble('assistant','');
  el.style.whiteSpace='pre-wrap';
  chat.appendChild(el); aiScrollChat();
  return el;
}
// 流式渲染节流：每 ~90ms 重渲染一次当前气泡，并跟随滚动到底部。
function aiScheduleRender(){
  var s=__aiStream; if(s.timer||!s.cur)return;
  s.timer=setTimeout(function(){
    s.timer=null;
    if(s.cur)aiRenderStream(s.cur,s.acc);
    aiScrollChat();
  },90);
}
// 结束当前文本气泡（渲染 markdown，空气泡移除）。
function aiFinalizeBubble(){
  var s=__aiStream;
  if(s.timer){clearTimeout(s.timer);s.timer=null;}
  if(s.thinking){
    // flush 残留 buf 并清理定时器,避免跨回合残留 + 未渲染文本丢失
    if(s.thinking.timer){clearTimeout(s.thinking.timer);s.thinking.timer=null;}
    aiThinkingFlush(s.thinking);
    s.thinking=null;
  }
  if(s.cur){
    aiRenderStream(s.cur,s.acc);
    if(!s.cur.textContent.trim()){ s.cur.remove(); }
    s.cur=null;
  }
  s.acc='';
}
// 思考过程块（可折叠，展示模型推理，如 Claude Code）。
// 卡顿修复:文本累积到 buf,用 timer 每 ~100ms flush 一次 DOM(而非每个 delta 全量
// textContent+=,长思考下那会反复重排/强制滚动导致前端卡死).
function aiThinkingBlock(){
  var chat=document.getElementById('ai-chat'); if(!chat)return null;
  var box=document.createElement('div');
  box.style.cssText='align-self:flex-start;max-width:94%;font-size:12px;border:1px solid var(--phx-border-light);border-radius:8px;overflow:hidden;background:var(--phx-bg-card);color:var(--phx-text-secondary)';
  var head=document.createElement('div');
  head.style.cssText='display:flex;align-items:center;gap:6px;padding:6px 10px;cursor:pointer;user-select:none';
  var fold=document.createElement('span'); fold.style.cssText='font-size:11px;flex-shrink:0'; fold.textContent='▸';
  head.innerHTML='<span style="font-weight:600">思考过程</span><span id="ai-think-prev" style="flex:1;min-width:0;margin-left:8px;font-size:11px;color:var(--phx-text-secondary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span>';
  head.appendChild(fold);
  var body=document.createElement('div');
  body.style.cssText='display:none;padding:8px 10px;border-top:1px solid rgba(128,128,128,.12);white-space:pre-wrap;word-break:break-word;line-height:1.5;max-height:38vh;overflow:auto';
  head.onclick=function(){ var open=body.style.display!=='none'; body.style.display=open?'none':'block'; fold.textContent=open?'▸':'▾'; aiThinkingFlush(box._tb); };
  var tb={buf:'',timer:null,body:body,head:head,prev:null,box:box};
  box._tb=tb;
  tb.prev=head.querySelector('#ai-think-prev');
  box.appendChild(head); box.appendChild(body);
  chat.appendChild(box); aiScrollChat();
  // 暴露 emit:累积到 buf 并调度 flush
  tb.emit=function(text){
    this.buf+=text;
    if(!this.timer)this.timer=setTimeout(function(){ tb.timer=null; aiThinkingFlush(tb); },100);
  };
  return tb;
}
// flush 思考块 DOM:把积累的 buf 一次性追加并更新摘要(防长思考卡顿)。
function aiThinkingFlush(tb){
  if(!tb||!tb.buf)return;
  var txt=tb.buf; tb.buf='';
  if(!tb.body){ return; }
  tb.body.textContent+=txt;
  tb.body.scrollTop=tb.body.scrollHeight;
  if(tb.prev){
    var raw=tb.body.textContent.replace(/\s+/g,' ');
    tb.prev.textContent=(raw.length>38?raw.slice(0,38)+'…':raw);
  }
}
// token 用量显示：合并输入+输出，1000 以上用 K 简写（如 1.2K），不显示精确数量。
function aiFmtTokens(n){
  if(n>=1000) return (n/1000).toFixed(1).replace(/\.0$/,'')+'K';
  return String(n);
}
function aiUpdateToken(){
  var el=document.getElementById('ai-token'); if(!el)return;
  var inN=__ai.totalIn||0;
  var outN=(__ai.totalOut||0)+(__ai.liveOut||0);
  if(!inN&&!outN){ el.textContent=''; return; }
  el.textContent='上传 '+aiFmtTokens(inN)+'  下载 '+aiFmtTokens(outN);
}
// 工具卡片（点击头部展开：参数 + 响应）。按 tool_call_id 区分（并行/同名工具各自独立）。
function aiToolCard(id,name,input){
  var chat=document.getElementById('ai-chat'); if(!chat)return null;
  var card=document.createElement('div');
  card.style.cssText='width:100%;box-sizing:border-box;font-size:12px;border-radius:8px;overflow:hidden;background:var(--phx-bg-card);border:1px solid var(--phx-border-light)';
  var head=document.createElement('div');
  head.style.cssText='display:block;padding:12px 14px;cursor:pointer;user-select:none;background:var(--phx-bg)';
  var title=document.createElement('div');
  title.style.cssText='font-weight:700;font-size:13px;word-break:break-all;line-height:1.4';
  title.textContent='调用工具：'+(name||'?');
  var hint=document.createElement('div');
  hint.style.cssText='font-size:11px;opacity:.7;margin-top:2px';
  hint.textContent='查看参数与结果 ▸';
  head.appendChild(title); head.appendChild(hint);
  var body=document.createElement('div');
  body.style.cssText='display:none;padding:10px 14px;border-top:1px solid rgba(128,128,128,.2);white-space:pre-wrap;word-break:break-word;line-height:1.5;text-align:left;max-height:38vh;overflow:auto';
  head.addEventListener('click',function(e){
    e.stopPropagation();
    var open=body.style.display!=='none';
    body.style.display=open?'none':'block';
    hint.textContent=open?'查看参数与结果 ▸':'收起参数与结果 ▾';
    if(!open) head.scrollIntoView({block:'start',behavior:'smooth'});
  });
  card.appendChild(head); card.appendChild(body);
  chat.appendChild(card);
  requestAnimationFrame(aiScrollChat);
  return {card:card,body:body,id:id,name:name,param:input,done:false,hint:hint};
}
// 工具完成：填充卡片内容（参数 + 响应，代码用黑底浅字）。isError 时卡片打"失败"标记。
function aiToolDone(tc,result,isError){
  if(!tc||!tc.body)return;
  var param=tc.param||'';
  var cstyle='display:block;white-space:pre-wrap;word-break:break-word;background:#0d1117;color:#e6edf3;padding:8px 10px;border-radius:6px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px';
  tc.body.innerHTML='<div style="opacity:.7;margin-bottom:4px">参数：</div><code style="'+cstyle+'">'+escHtml(param)+'</code>'
    +'<div style="opacity:.7;margin:6px 0 4px">响应：</div><code style="'+cstyle+'">'+escHtml(result)+'</code>';
  if(isError) tc.card.style.borderColor='#e11d48';
  tc.done=true;
  aiScrollChat();
}
// 标记全部未完成的工具卡为中断（流中断/出错时调用）。
function aiMarkAllInterrupted(){
  var s=__aiStream; if(!s||!s.tools)return;
  Object.keys(s.tools).forEach(function(id){ aiMarkInterrupted(id); });
}
// 标记中断（流中断、或 start 后无 done）的卡片。
function aiMarkInterrupted(id){
  var tc=__aiStream.tools[id];
  if(tc&&!tc.done){
    if(tc.hint)tc.hint.textContent='⚠ 中断（未收到结果）';
    tc.card.style.borderColor='#d97706';
  }
}

// 显示错误卡(含重试按钮)。msg 为错误描述;可重发 __ai.lastPrompt。
function aiShowError(msg){
  var chat=document.getElementById('ai-chat'); if(!chat)return;
  var box=document.createElement('div');
  box.style.cssText='align-self:flex-start;max-width:94%;font-size:13px;border:1px solid #e11d48;border-radius:8px;background:rgba(225,29,72,.08);color:#e11d48;padding:10px 12px;word-break:break-word';
  box.innerHTML='<div style="font-weight:700;margin-bottom:4px">⚠ 请求出错</div>'
    +'<div style="font-size:12px;opacity:.9;white-space:pre-wrap;word-break:break-word">'+escHtml(msg||'')+'</div>';
  var last=__ai.lastPrompt;
  if(last){
    var btn=document.createElement('button');
    btn.className='btn';
    btn.style.cssText='width:auto;padding:7px 14px;font-size:13px;margin-top:8px';
    btn.textContent='重试';
    btn.onclick=function(){
      box.remove();
      var inp=document.getElementById('ai-input'); if(inp)inp.value=last;
      aiSend();
    };
    box.appendChild(btn);
  }
  chat.appendChild(box);
  aiScrollChat(true);
  return box;
}

async function aiSend(){
  var inp=document.getElementById('ai-input');
  var text=(inp.value||'').trim();
  if(!text)return;
  if(!__ai.modelName){T('请先选择模型','e');return;}
  if(__ai.busy){T('正在回复中…','w');return;}
  __ai.busy=true;
  __ai.lastIn=0; __ai.lastOut=0; // 新回合重置 usage 增量跟踪
  __ai.lastPrompt=text; // 供出错重试用
  var sb=document.getElementById('ai-send');
  if(sb){ sb.innerHTML=AI_ICON_STOP; sb.title='停止'; sb.onclick=function(){aiStopResp();}; sb.disabled=false; }
  aiAddMsg('user',text);
  __ai.messages.push({role:'user',content:text});
  var asst={role:'assistant',content:''};
  __ai.messages.push(asst);
  __aiStream={cur:null,acc:'',timer:null,tools:{},thinking:null,curMsg:asst};
  if(!__ai.sessionName)__ai.sessionName=aiTimestamp(); // 首个消息确定会话（创建时间命名）
  var acc='';
  inp.value='';

  var body={model_name:__ai.modelName,plugin_id:__ai.pluginId,mode:__ai.mode,session_name:__ai.sessionName,messages:__ai.messages};
  try{
    var ctrl=new AbortController(); __aiStream.ctrl=ctrl;
    var resp=await fetch('/api/ai/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:ctrl.signal});
    if(!resp.ok){ var j=await resp.json().catch(function(){}); throw new Error((j&&j.error)||('HTTP '+resp.status)); }
    var reader=resp.body.getReader(),dec=new TextDecoder(),buf='';
    for(;;){
      var r=await reader.read(); if(r.done)break;
      buf+=dec.decode(r.value,{stream:true});
      var idx;
      while((idx=buf.indexOf('\n\n'))>=0){
        var block=buf.slice(0,idx); buf=buf.slice(idx+2);
        aiHandleBlock(block,function(x){acc+=x});
      }
    }
  }catch(e){
    var stopped=(e&&e.name==='AbortError');
    aiFinalizeBubble();
    aiMarkAllInterrupted();
    if(!stopped) aiShowError(e&&e.message?e.message:'请求失败');
    __ai.messages[__ai.messages.length-1].content=acc; // 保留已生成部分
    aiCommitToolHistory(); // 中断也把已执行工具写入会话历史
    aiAutoSave();
    aiFinish();
    return;
  }
  // 收尾：渲染 + 自动保存会话
  aiFinalizeBubble();
  __ai.messages[__ai.messages.length-1].content=acc;
  aiCommitToolHistory();
  aiAutoSave();
  aiFinish();
}
// 收尾把本轮工具调用/结果写回 __ai.messages（助手消息带 tool_calls，工具结果回合带 tool_results），
// 会话保存/恢复/发送全链路带上工具历史，模型跨轮可见。
function aiCommitToolHistory(){
  var s=__aiStream; if(!s||!s.curMsg)return;
  if(s.toolCalls&&s.toolCalls.length) s.curMsg.tool_calls=s.toolCalls;
  if(s.toolResults&&s.toolResults.length){
    __ai.messages.push({role:'user',tool_results:s.toolResults});
  }
  s.curMsg=null; s.toolCalls=null; s.toolResults=null;
}
// 处理一个 SSE 块（event: X / data: {…}）
function aiHandleBlock(block,onAcc){
  var lines=block.split('\n'),ev='',data='';
  for(var i=0;i<lines.length;i++){
    var l=lines[i];
    if(l.indexOf('event:')===0)ev=l.slice(6).trim();
    else if(l.indexOf('data:')===0)data=l.slice(5).trim();
  }
  if(!data)return;
  var d; try{d=JSON.parse(data)}catch(e){return}
  if(ev==='ai_chunk'&&d.text){
    if(!__aiStream.cur)__aiStream.cur=aiStreamBubble();
    __aiStream.acc+=d.text; onAcc(d.text);
    // 实时估算已输出 token（约 4 字符/个），让用量边生成边递增
    __ai.liveOut=(__ai.liveOut||0)+Math.max(1,Math.round(d.text.length/4));
    aiUpdateToken(); aiScheduleRender();
  }
  else if(ev==='ai_tool_start'&&d.name){
    aiFinalizeBubble(); // 结束工具调用前的文本段
    var tid=d.id||('tc_'+Math.random().toString(36).slice(2));
    var param=(typeof d.input==='string')?d.input:JSON.stringify(d.input||{});
    __aiStream.tools[tid]=aiToolCard(tid,d.name,param);
    if(!__aiStream.toolCalls)__aiStream.toolCalls=[];
    __aiStream.toolCalls.push({id:tid,name:d.name,input:d.input||{}});
    __aiStream.cur=null; // 有文本时惰性新建气泡，紧跟工具卡之后
  }
  else if(ev==='ai_tool_done'&&d.name){
    var doneId=d.id||(d.name&&Object.keys(__aiStream.tools).find(function(k){return __aiStream.tools[k].name===d.name}));
    var tc=doneId?__aiStream.tools[doneId]:null;
    if(tc){ aiToolDone(tc,d.result||'',!!d.is_error); }
    // 记录工具结果（evidence=executed 表示后端真实执行过；无 evidence 则标为未执行）
    if(d.evidence==='executed'||tc){
      if(!__aiStream.toolResults)__aiStream.toolResults=[];
      __aiStream.toolResults.push({id:doneId||'',content:d.result||'',is_error:!!d.is_error});
    }
    // AI 写入/修改了插件文件 → 失效插件编辑器缓存,返回代码页时重新读取显示新内容
    // (否则编辑器持有旧缓存,必须退出重进才看到改动)。
    if(d.evidence==='executed'&&(d.name==='write_plugin_file'||d.name==='write_file')&&window.__plgEdit){
      window.__plgEdit.content={};
    }
  }
  else if(ev==='ai_thinking'&&d.text){
    if(!__aiStream.thinking)__aiStream.thinking=aiThinkingBlock();
    if(__aiStream.thinking&&__aiStream.thinking.emit){
      __aiStream.thinking.emit(d.text); // 节流累积,防长思考卡顿
    }
  }
  else if(ev==='ai_usage'){
    // 后端可能中途多次推 usage(message_delta 每次递增 output)。按"增量"合并:
    // 记录本轮已知 input/output,只把比上次多的部分累加,避免重复计入。
    // - input:每轮固定,只在增长时累加差量(去重)。
    // - output:同轮递增时加差量;比上次小表示新一轮 output 从 0 重置,加本轮完整 outN。
    var inN=d.input||0, outN=d.output||0;
    if(inN>(__ai.lastIn||0)){ __ai.totalIn+=inN-(__ai.lastIn||0); }
    if(outN>__ai.lastOut){ __ai.totalOut+=outN-__ai.lastOut; }
    else if(outN<__ai.lastOut){ __ai.totalOut+=outN; }
    __ai.lastIn=inN; __ai.lastOut=outN;
    __ai.liveOut=0; aiUpdateToken();
  }
  else if(ev==='ai_session_title'&&d.name){ __ai.sessionName=d.name; }
  else if(ev==='ai_question'){ aiShowQuestion(d.req_id,d.question,d.options); }
  else if(ev==='ai_error'){ aiFinalizeBubble(); aiShowError(d.error||'未知错误'); }
  else if(ev==='ai_done'){ aiFinalizeBubble(); }
}
function aiFinish(){ __ai.busy=false; __aiStream.ctrl=null; var sb=document.getElementById('ai-send'); if(sb){ sb.innerHTML=AI_ICON_SEND; sb.title='发送'; sb.onclick=function(){aiSend();}; sb.disabled=!__ai.modelName; } }
// 停止当前回复（发送按钮在流式时变为停止图标）。
function aiStopResp(){
  if(!__ai.busy)return;
  if(__aiStream.ctrl)__aiStream.ctrl.abort();
  else aiFinish();
}
