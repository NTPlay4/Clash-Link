--[[
LuCI CBI 配置模型 - 网络检测器
路径: /usr/lib/lua/luci/model/cbi/network_detector.lua
--]]

local m, s, o

local ver = luci.sys.exec("cat /usr/share/network-detector/version 2>/dev/null"):match("^(%S+)") or ""
m = Map("network-detector", translate("网络检测器") .. (ver ~= "" and (" v" .. ver) or ""),
        translate("基于Clash代理的网络可达性检测工具，支持自动节点切换与Webhook通知。"))

-- 保存后自动重载服务
function m.on_after_commit(self)
    luci.sys.call("/etc/init.d/network-detector reload > /dev/null 2>&1 &")
end

-- =============================================================
-- 全局设置
-- =============================================================
s = m:section(TypedSection, "main", translate("全局设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用服务"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "interval_value", translate("检测间隔"))
o.default = "60"
o.datatype = "uinteger"
o.rmempty = false
o.description = translate("自定义检测间隔时间，配合右侧单位使用。默认 60 秒（即每 1 分钟执行一次）")

o = s:option(ListValue, "interval_unit", translate("间隔单位"))
o:value("s", translate("秒"))
o:value("m", translate("分"))
o:value("h", translate("时"))
o.default = "s"
o.rmempty = false
o.description = translate("选择间隔数值的单位。秒级最小粒度 1 秒（<60 秒通过内部循环实现），分/时为标准 cron 调度")

o = s:option(Value, "log_retention_days", translate("日志保留天数"))
o.default = "3"
o.datatype = "uinteger"
o.rmempty = false

-- =============================================================
-- Clash API 设置
-- =============================================================
s = m:section(TypedSection, "clash", translate("Clash API 设置"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "api_url", translate("API 地址"))
o.default = "http://127.0.0.1:9090"
o.placeholder = "http://127.0.0.1:9090"
o.rmempty = false
o.description = translate("Clash 外部控制 API 地址，通常为 http://127.0.0.1:9090")

o = s:option(Value, "secret", translate("API 密钥 (Secret)"))
o.password = true
o.placeholder = "API Secret"
o.rmempty = true
o.description = translate("在 Clash 配置文件中 external-controller 下设置的 secret 值。留空将自动尝试从 OpenClash 配置中获取")

o = s:option(ListValue, "proxy_type", translate("代理类型"))
o:value("http", "HTTP")
o:value("socks5", "SOCKS5")
o.default = "http"
o.rmempty = false
o.description = translate("选择本地代理协议类型，需与 Clash 设置一致")

o = s:option(Value, "local_proxy", translate("代理地址"))
o.default = "127.0.0.1:7890"
o.placeholder = "127.0.0.1:7890"
o.rmempty = false
o.description = translate("本地代理 IP:端口，HTTP 和 SOCKS5 共用此地址")

-- =============================================================
-- Webhook 通知设置
-- =============================================================
s = m:section(TypedSection, "webhook", translate("Webhook 通知设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用 Webhook 通知"))
o.default = "0"
o.rmempty = false
o.description = translate("开启后将在：①检测失败→切换节点→恢复正常时通知 ②所有节点尝试均失败时通知")

o = s:option(Value, "url", translate("Webhook URL"))
o.placeholder = "https://api.day.app/yourDeviceKey"
o.rmempty = true
o.description = translate([[GET 请求格式: Webhook地址/通知标题/通知内容
兼容 Bark / 企业微信 / 钉钉 / 飞书等 Webhook 服务
示例: https://api.day.app/key 或 https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx]])

-- =============================================================
-- 检测任务列表 (支持动态添加删除)
-- =============================================================
s = m:section(TypedSection, "task", translate("检测任务列表"),
        translate("可添加多个检测任务，每个任务独立配置检测目标与节点切换策略"))
s.template = "cbi/tblsection"
s.addremove = true
s.anonymous = true
s.sortable = true

o = s:option(Flag, "enabled", translate("启用"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "name", translate("任务名称"))
o.placeholder = translate("例如: 网站检测")
o.rmempty = false

o = s:option(Value, "proxy_group", translate("策略组名称"))
o.placeholder = translate("例如: Proxy")
o.rmempty = false

o = s:option(Value, "test_url", translate("检测目标 URL"))
o.placeholder = "https://example.com/"
o.rmempty = false

o = s:option(Value, "banned_keyword", translate("被封关键词 (可选)"))
o.rmempty = true

o = s:option(Value, "max_tries", translate("最大尝试次数"))
o.default = "5"
o.datatype = "uinteger"
o.rmempty = false

-- =============================================================
-- 任务字段说明
-- =============================================================
s = m:section(TypedSection, "main", translate("字段说明"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"

local task_hint = s:option(DummyValue, "_task_hint", "")
task_hint.rawhtml = true
task_hint.value = string.format(
    '<div style="font-size:12px;color:#666;line-height:1.7">' ..
    '• <b>%s</b> %s<br>' ..
    '• <b>%s</b> %s<br>' ..
    '• <b>%s</b> %s<br>' ..
    '• <b>%s</b> %s</div>',
    translate("策略组名称："), translate("Clash 中的代理策略组名称，需与配置文件一致"),
    translate("检测目标 URL："), translate("通过代理访问此 URL 来判定节点是否可用（如 Google、YouTube 等）"),
    translate("被封关键词："), translate("页面中出现此关键词则判定 IP 被封，即触发节点切换。留空则仅检查 HTTP 连通性"),
    translate("最大尝试次数："), translate("连续切换节点的最大次数，超出后停止避免死循环（范围 1~20）")
)

-- =============================================================
-- 日志查看区域 (Dummy TypedSection，避免 SimpleSection 保存时 section 为 nil)
-- =============================================================
s = m:section(TypedSection, "main", translate("运行日志"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"

local log_view = s:option(TextValue, "_logview", translate("最近日志"))
log_view.readonly = true
log_view.rows = 22

local logfile = "/var/log/network-detector.log"
log_view.cfgvalue = function(self, section)
    local f = io.open(logfile, "r")
    if not f then
        return translate("暂无日志文件")
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    if #lines == 0 then
        return translate("日志为空")
    end
    local start = math.max(1, #lines - 79)
    local result = {}
    for i = start, #lines do
        result[#result + 1] = lines[i]
    end
    return table.concat(result, "\n")
end

log_view.write = function(self, section, value) end

-- 清除日志 + 下载日志按钮
local clear_btn_html = s:option(DummyValue, "_clear_log_dummy", "")
clear_btn_html.rawhtml = true
clear_btn_html.value = '<button type="button" class="cbi-button cbi-button-reset" id="btn-clear-log">' .. translate("清除日志") .. '</button> ' ..
    '<button type="button" class="cbi-button cbi-button-download" id="btn-download-log" onclick="window.location.href=window.location.href.replace(/\\/(settings|status)(\\?.*)?(#.*)?$/, \'/downloadlog\')">&#x2b07; ' .. translate("下载日志") .. '</button>'

-- =============================================================
-- 操作按钮
-- =============================================================
s = m:section(TypedSection, "main", translate("快捷操作"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"

local run_now_html = s:option(DummyValue, "_run_now_dummy", "")
run_now_html.rawhtml = true
run_now_html.value = '<button type="button" class="cbi-button cbi-button-reload" id="btn-run-now">&#x25b6; ' .. translate("立即检测") .. '</button>'

-- =============================================================
-- 页面增强脚本 (策略组下拉、排序按钮、日志置底)
-- =============================================================
s = m:section(TypedSection, "main", "")
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"
local enh = s:option(DummyValue, "_enhance", "")
enh.rawhtml = true
enh.value = [[<script type="text/javascript">
(function(){
    var DONE_SORT=0, DONE_LOG=0;

    // ====== 1. 排序按钮: 上传/下载 → 上移/下移 ======
    //     扫描所有 input（submit/image/button），覆盖 value/alt/title 三种属性
    function fixSortBtns(){
        var all=document.querySelectorAll('input');
        for(var i=0;i<all.length;i++){
            var el=all[i];
            if(el.value==='\u4e0a\u4f20'){ el.value='\u4e0a\u79fb'; el.setAttribute('value','\u4e0a\u79fb'); }
            if(el.value==='\u4e0b\u8f7d'){ el.value='\u4e0b\u79fb'; el.setAttribute('value','\u4e0b\u79fb'); }
            if(el.getAttribute('value')==='\u4e0a\u4f20') el.setAttribute('value','\u4e0a\u79fb');
            if(el.getAttribute('value')==='\u4e0b\u8f7d') el.setAttribute('value','\u4e0b\u79fb');
            if(el.alt==='\u4e0a\u4f20'){ el.alt='\u4e0a\u79fb'; el.setAttribute('alt','\u4e0a\u79fb'); }
            if(el.alt==='\u4e0b\u8f7d'){ el.alt='\u4e0b\u79fb'; el.setAttribute('alt','\u4e0b\u79fb'); }
            if(el.getAttribute('alt')==='\u4e0a\u4f20') el.setAttribute('alt','\u4e0a\u79fb');
            if(el.getAttribute('alt')==='\u4e0b\u8f7d') el.setAttribute('alt','\u4e0b\u79fb');
            if(el.title==='\u4e0a\u4f20'){ el.title='\u4e0a\u79fb'; el.setAttribute('title','\u4e0a\u79fb'); }
            if(el.title==='\u4e0b\u8f7d'){ el.title='\u4e0b\u79fb'; el.setAttribute('title','\u4e0b\u79fb'); }
        }
    }
    var sortTries=0, sortTimer=setInterval(function(){
        sortTries++; fixSortBtns();
        if(sortTries>=60) clearInterval(sortTimer);
    }, 150);
    setTimeout(fixSortBtns, 50);
    setTimeout(fixSortBtns, 300);

    // ====== 1.5 立即检测按钮 (AJAX, 不跳转不刷新, 冷却30秒) ======
    var _runBtnDone=false, _runBtnCooldown=false;
    function setupRunBtn(){
        if(_runBtnDone) return;
        var btn=document.getElementById('btn-run-now');
        if(!btn) return;
        _runBtnDone=true;
        btn.addEventListener('click', function(e){
            e.preventDefault();
            if(_runBtnCooldown) return;
            _runBtnCooldown=true;
            btn.disabled=true;
            btn.innerHTML='⏳ 启动中...';
            var apiUrl=window.location.href.replace(/\/(settings|status)(\?.*)?(#.*)?$/, '/run?_='+Date.now());
            var xhr=new XMLHttpRequest();
            xhr.open('GET', apiUrl, true);
            xhr.onload=function(){
                btn.innerHTML='▶ 立即检测';
                // 冷却倒计时 (30秒)
                var cd=30;
                btn.innerHTML='⏳ ' + cd + '秒后可再次检测';
                btn.disabled=true;
                var timer=setInterval(function(){
                    cd--;
                    if(cd<=0){ btn.innerHTML='▶ 立即检测'; btn.disabled=false; _runBtnCooldown=false; clearInterval(timer); }
                    else{ btn.innerHTML='⏳ ' + cd + '秒后可再次检测'; }
                }, 1000);
            };
            xhr.onerror=function(){ btn.disabled=false; btn.innerHTML='▶ 立即检测'; _runBtnCooldown=false; };
            xhr.send();
        });
    }
    setTimeout(setupRunBtn, 200);
    setTimeout(setupRunBtn, 800);

    // ====== 1.6 清除日志按钮 (AJAX, 不刷新页面) ======
    var _clearBtnDone=false;
    function setupClearBtn(){
        if(_clearBtnDone) return;
        var btn=document.getElementById('btn-clear-log');
        if(!btn) return;
        _clearBtnDone=true;
        btn.addEventListener('click', function(e){
            e.preventDefault();
            if(!confirm('确认清除所有日志？')) return;
            btn.disabled=true;
            btn.textContent='清除中...';
            var apiUrl=window.location.href.replace(/\/(settings|status)(\?.*)?(#.*)?$/, '/clearlog?_='+Date.now());
            var xhr=new XMLHttpRequest();
            xhr.open('GET', apiUrl, true);
            xhr.onload=function(){
                btn.disabled=false;
                btn.textContent='清除日志';
                if(xhr.status==200){
                    try{ var r=JSON.parse(xhr.responseText); if(r.status==='ok'){
                        var ta=document.querySelector('textarea[name*="_logview"]');
                        if(ta){ ta.value=''; lastLogText=''; }
                    } }catch(e){}
                }
            };
            xhr.onerror=function(){ btn.disabled=false; btn.textContent='清除日志'; };
            xhr.send();
        });
    }
    setTimeout(setupClearBtn, 200);
    setTimeout(setupClearBtn, 800);

    // ====== 2. 日志区域自动滚动到最底部 + 自动刷新日志 ======
    var logArea=null;
    var logTimer=setInterval(function(){
        logArea=document.querySelector('textarea[name*="_logview"]');
        if(logArea){ logArea.scrollTop=logArea.scrollHeight; clearInterval(logTimer); DONE_LOG=1; }
    }, 200);
    setTimeout(function(){ if(!DONE_LOG) clearInterval(logTimer); }, 5000);

    // 日志自动刷新（每 5 秒 AJAX 拉取，不刷新页面）
    var lastLogText='';
    var autoLogRefresh=null;
    function startLogRefresh(){
        var logUrl=window.location.href.replace(/\/(settings|status)(\?.*)?(#.*)?$/, '/log?_=' + Date.now());
        autoLogRefresh=setInterval(function(){
            var url=logUrl.replace(/_=\d+/, '_='+Date.now());
            var xhr=new XMLHttpRequest();
            xhr.open('GET', url, true);
            xhr.onload=function(){
                if(xhr.status==200){
                    var text=xhr.responseText||'';
                    // 防止 LuCI 错误页面 HTML 被灌入日志区
                    if(/^\s*<!DOCTYPE|<html|<body/i.test(text)) return;
                    if(text!==lastLogText){
                        lastLogText=text;
                        var ta=document.querySelector('textarea[name*="_logview"]');
                        if(ta){
                            if(text==='') text='\u6682\u65e0\u65e5\u5fd7';
                            ta.value=text;
                            ta.scrollTop=ta.scrollHeight;
                        }
                    }
                }
            };
            xhr.send();
        }, 5000);
    }
    // 等 textarea 就绪后启动
    setTimeout(function(){
        if(document.querySelector('textarea[name*="_logview"]')){
            startLogRefresh();
        }else{
            var waitT=setInterval(function(){
                var ta=document.querySelector('textarea[name*="_logview"]');
                if(ta){
                    clearInterval(waitT);
                    startLogRefresh();
                }
            }, 300);
            setTimeout(function(){ clearInterval(waitT); }, 8000);
        }
    }, 800);

    // ====== 2.5 自动检测 OpenClash Secret ======
    setTimeout(function(){
        // 查找 API 密钥输入框 (id=cbid.network-detector.clash.secret 或 name*="secret")
        var secInput=document.querySelector('input[id*="secret"][type="password"],input[name*="secret"][type="password"]');
        if(!secInput) return;
        // 仅当字段为空时才自动检测
        if(secInput.value && secInput.value.trim()!=='') return;

        var apiUrl=window.location.href.replace(/\/(settings|status)(\?.*)?(#.*)?$/, '/detectsecret?_=' + Date.now());
        var xhr=new XMLHttpRequest();
        xhr.open('GET', apiUrl, true);
        xhr.onload=function(){
            if(xhr.status==200){
                try{
                    var r=JSON.parse(xhr.responseText);
                    if(r && r.secret && r.secret!==''){
                        secInput.value=r.secret;
                        secInput.style.borderColor='#27ae60';
                        setTimeout(function(){ secInput.style.borderColor=''; }, 3000);
                    }
                }catch(e){}
            }
        };
        xhr.send();
    }, 1000);

    // ====== 3. 策略组下拉选择（隐藏手动输入框） ======
    var pgTimer=setInterval(function(){
        var pgInputs=document.querySelectorAll('input[name*="proxy_group"]');
        if(!pgInputs.length) return;

        // 排除已是 hidden 的（避免重复处理）
        var realInputs=[];
        for(var i=0;i<pgInputs.length;i++){
            if(pgInputs[i].type!=='hidden') realInputs.push(pgInputs[i]);
        }
        if(!realInputs.length) return;

        clearInterval(pgTimer);

        // 构造 API URL
        var apiUrl=window.location.href;
        apiUrl=apiUrl.replace(/\/(settings|status)(\?.*)?(#.*)?$/, '/proxy_groups?_=' + Date.now());
        if(apiUrl===window.location.href) return;

        var selects=[];
        var savedVals=[];   // ★ 并行数组：XHR 前保存 pgInput.value（UCI 已有值）
        for(var i=0;i<realInputs.length;i++){
            (function(pgInput, idx){
                pgInput.type='hidden';
                pgInput.style.display='none';

                var container=pgInput.closest('td')||pgInput.parentNode;
                if(!container) return;

                var sel=document.createElement('select');
                sel.style.cssText='display:block;margin-top:2px;max-width:100%;padding:3px 6px;';
                sel.innerHTML='<option value="">-- \u52a0\u8f7d\u4e2d... --</option>';
                selects[idx]=sel;
                savedVals[idx]=pgInput.value||'';   // ★ UCI 保存的值

                container.insertBefore(sel, null);

                sel.onchange=function(){
                    if(sel.value){ pgInput.value=sel.value; }
                };
            })(realInputs[i], i);
        }
        if(!selects.length) return;

        // 共享 XHR 获取策略组
        var xhr=new XMLHttpRequest();
        xhr.open('GET', apiUrl, true);
        xhr.onload=function(){
            var groups=[];
            if(xhr.status==200){
                try{ groups=JSON.parse(xhr.responseText)||[]; }catch(e){}
            }
            if(!Array.isArray(groups)) groups=[];

            for(var s=0;s<selects.length;s++){
                var sel=selects[s];
                var restoreVal=savedVals[s]||'';   // ★ 用保存的值而不是 sel.value
                sel.innerHTML='<option value="">-- \u8bf7\u9009\u62e9\u7b56\u7565\u7ec4 --</option>';
                if(groups.length>0){
                    for(var k=0;k<groups.length;k++){
                        var opt=document.createElement('option');
                        opt.value=groups[k];
                        opt.textContent=groups[k];
                        if(groups[k]===restoreVal) opt.selected=true;
                        sel.appendChild(opt);
                    }
                }else{
                    var hint=document.createElement('option');
                    hint.disabled=true;
                    hint.textContent='(\u65e0\u6cd5\u8fde\u63a5Clash API\u6216\u65e0\u7b56\u7565\u7ec4)';
                    sel.appendChild(hint);
                }
                if(restoreVal) sel.value=restoreVal;   // ★ 直接用保存值回显
            }
        };
        xhr.onerror=function(){
            for(var s=0;s<selects.length;s++){
                selects[s].innerHTML='<option value="">-- \u8bf7\u9009\u62e9\u7b56\u7565\u7ec4 --</option>';
                var hint=document.createElement('option');
                hint.disabled=true;
                hint.textContent='(API\u8fde\u63a5\u5931\u8d25)';
                selects[s].appendChild(hint);
            }
        };
        xhr.send();
    }, 500);
    // 超时兜底
    setTimeout(function(){ clearInterval(pgTimer); }, 10000);
})();
</script>]]

return m
