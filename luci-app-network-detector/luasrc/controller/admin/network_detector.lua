--[[
LuCI Controller - 网络检测器
路径: /usr/lib/lua/luci/controller/admin/network_detector.lua
URL:  /cgi-bin/luci/admin/services/network_detector
--]]

module("luci.controller.admin.network_detector", package.seeall)

function index()
    entry({"admin", "services", "network_detector"},
        alias("admin", "services", "network_detector", "status"),
        translate("网络检测器"), 40)

    entry({"admin", "services", "network_detector", "status"},
        template("network_detector/status"),
        translate("运行状态"), 10)

    entry({"admin", "services", "network_detector", "settings"},
        cbi("network_detector"),
        translate("配置"), 20)

    -- API: 获取 Clash 代理策略组名称列表 (JSON)
    entry({"admin", "services", "network_detector", "proxy_groups"},
        call("action_proxy_groups")).leaf = true

    -- API: 获取最近日志 (纯文本)
    entry({"admin", "services", "network_detector", "log"},
        call("action_log")).leaf = true

    -- API: 立即运行一次检测 (后台执行)
    entry({"admin", "services", "network_detector", "run"},
        call("action_run")).leaf = true

    -- API: 清除日志
    entry({"admin", "services", "network_detector", "clearlog"},
        call("action_clearlog")).leaf = true

    -- API: 自动检测 OpenClash Secret (不保存到 UCI，仅返回给前端回填)
    entry({"admin", "services", "network_detector", "detectsecret"},
        call("action_detectsecret")).leaf = true

    -- API: 下载完整日志文件
    entry({"admin", "services", "network_detector", "downloadlog"},
        call("action_downloadlog")).leaf = true

    -- API: 获取当日计数器
    entry({"admin", "services", "network_detector", "counters"},
        call("action_counters")).leaf = true
end

function action_proxy_groups()
    local http = require("luci.http")
    local uci  = require("luci.model.uci").cursor()

    http.prepare_content("application/json")

    local api = uci:get("network-detector", "@clash[0]", "api_url") or "http://127.0.0.1:9090"
    local secret = uci:get("network-detector", "@clash[0]", "secret") or ""

    local esc = function(s) return (s:gsub('"', '\\"')) end

    -- Shell 管道: 输出符合条件的策略组名称，一行一个
    local cmd = string.format(
        [[PROXIES=$(curl -s --max-time 5 -H "Authorization: Bearer %s" "%s/proxies" 2>/dev/null)
if [ -z "$PROXIES" ]; then exit 0; fi
if printf '%%s' "$PROXIES" | grep -qE 'Unauthorized|Forbidden'; then exit 0; fi
printf '%%s\n' "$PROXIES" | jsonfilter -e '@.proxies[*]' 2>/dev/null | while IFS= read -r proxy; do
    tp=$(printf '%%s\n' "$proxy" | jsonfilter -e '@.type' 2>/dev/null)
    case "$tp" in
        Selector|URLTest|Fallback)
            printf '%%s\n' "$proxy" | jsonfilter -e '@.name' 2>/dev/null
            ;;
    esac
done]],
        esc(secret), esc(api)
    )

    local h = io.popen(cmd)
    if not h then
        http.write('[]')
        return
    end
    local raw = h:read("*a")
    h:close()

    if not raw or raw == "" then
        http.write('[]')
        return
    end

    -- 解析行，构造 JSON 数组
    local result = {}
    for name in raw:gmatch("[^\r\n]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then
            result[#result + 1] = string.format('"%s"', name:gsub('\\', '\\\\'):gsub('"', '\\"'))
        end
    end

    http.write("[" .. table.concat(result, ",") .. "]")
end

function action_log()
    local http = require("luci.http")
    local fs   = require("nixio.fs")
    local nixio = require("nixio")

    http.prepare_content("text/plain; charset=utf-8")

    local logfile = "/var/log/network-detector.log"
    if not fs.access(logfile) then
        http.write("暂无日志")
        return
    end

    -- 返回最近 60 行（正序输出）
    local f = io.open(logfile, "r")
    if not f then
        http.write("暂无日志")
        return
    end

    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()

    local start = math.max(1, #lines - 59)
    local result = {}
    for i = start, #lines do
        result[#result + 1] = lines[i]
    end

    http.write(table.concat(result, "\n"))
end

function action_run()
    local http = require("luci.http")
    http.prepare_content("application/json")

    -- 后台运行检测脚本 (不阻塞请求)
    os.execute("(/usr/bin/network-detector > /dev/null 2>&1) &")

    http.write('{"status":"ok","message":"检测已启动"}')
end

function action_clearlog()
    local http = require("luci.http")
    http.prepare_content("application/json")

    local logfile = "/var/log/network-detector.log"
    local f = io.open(logfile, "w")
    if f then f:close() end
    os.execute("logger -t 'network-detector' '日志已通过 Web UI 清除'")

    http.write('{"status":"ok","message":"日志已清除"}')
end

function action_detectsecret()
    local http = require("luci.http")
    http.prepare_content("application/json")

    -- 1) 尝试从 OpenClash UCI 读取
    local secret = luci.sys.exec("uci -q get openclash.@config[0].dashboard_password 2>/dev/null"):match("^(%S+)")
    if secret and secret ~= "" then
        http.write(string.format('{"secret":"%s"}', secret:gsub('"', '\\"')))
        return
    end

    -- 2) 尝试从 OpenClash YAML 配置读取
    local confs = luci.sys.exec("ls /etc/openclash/config/*.yaml /etc/openclash/*.yaml 2>/dev/null")
    for conf in confs:gmatch("[^\r\n]+") do
        local s = luci.sys.exec("grep -m1 '^secret:' " .. conf .. " 2>/dev/null | sed \"s/^secret:[[:space:]]*['\\\"]\\?//;s/['\\\"]$//\"")
        s = s:match("^(%S+)")
        if s and s ~= "" then
            http.write(string.format('{"secret":"%s"}', s:gsub('"', '\\"')))
            return
        end
    end

    http.write('{"secret":""}')
end

function action_downloadlog()
    local http = require("luci.http")
    local fs   = require("nixio.fs")

    local logfile = "/var/log/network-detector.log"

    if not fs.access(logfile) then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("暂无日志")
        return
    end

    local stat = fs.stat(logfile)
    local f    = io.open(logfile, "r")
    if not f then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("无法读取日志文件")
        return
    end
    local content = f:read("*a")
    f:close()

    local filename = "network-detector-" .. os.date("%Y%m%d-%H%M%S") .. ".log"

    http.prepare_content("application/octet-stream")
    http.header("Content-Disposition", "attachment; filename=\"" .. filename .. "\"")
    http.header("Content-Length", tostring(#content))
    http.write(content)
end

function action_counters()
    local http = require("luci.http")
    http.prepare_content("application/json")

    local counter_file = "/var/lib/network-detector/counters"
    local today = os.date("%Y-%m-%d")

    local result = {}
    local f = io.open(counter_file, "r")
    if f then
        for line in f:lines() do
            if line:match("^%s*$") then
                -- skip empty
            else
                local name, date, reconn, fail = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
                if name and date and reconn and fail then
                    if date == today then
                        result[name] = { reconnect = tonumber(reconn) or 0, fail = tonumber(fail) or 0 }
                    end
                end
            end
        end
        f:close()
    end

    -- 转义 JSON
    local parts = {}
    for name, v in pairs(result) do
        local escaped_name = name:gsub('\\', '\\\\'):gsub('"', '\\"')
        parts[#parts + 1] = string.format('"%s":{"reconnect":%d,"fail":%d}',
            escaped_name, v.reconnect, v.fail)
    end
    http.write("{" .. table.concat(parts, ",") .. "}")
end
