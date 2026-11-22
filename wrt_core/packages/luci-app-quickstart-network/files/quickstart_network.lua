local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local ltn12 = require "luci.ltn12"
local nixio = require "nixio"
local template = require "luci.template"
local uci = require "luci.model.uci"

module("luci.controller.quickstart_network", package.seeall)

local allowed = {
    ["network/interface/config"] = { GET = true, POST = true },
    ["u/network/status"] = { GET = true },
    ["guide/pppoe"] = { GET = true, POST = true },
    ["guide/client-mode"] = { GET = true, POST = true },
    ["guide/lan"] = { GET = true },
    ["guide/gateway-router"] = { POST = true }
}

function index()
    entry({"admin", "network_guide"}, call("guide_index"), "网络向导", 2)
    local pages = {"admin", "network_guide", "pages", "network"}
    entry(pages, call("show_page", true))
    for _, step in ipairs({"pppoe", "dhcp", "gateway"}) do
        entry({"admin", "network_guide", "pages", "network", step}, call("show_page", true))
    end
    entry({"admin", "network", "interfaceconfig"}, call("show_page", false), "网口配置", 11)
    entry({"admin", "quickstart_network_api"}, call("network_api")).leaf = true
end

function guide_index()
    http.redirect(dispatcher.build_url("admin", "network_guide", "pages", "network"))
end

function show_page(guide)
    local lang = uci.cursor():get("luci", "main", "lang") or "auto"
    template.render("quickstart/network-only", {
        prefix = guide and dispatcher.build_url("admin", "network_guide", "pages")
            or dispatcher.build_url("admin", "network"),
        language = lang:match("^zh") and "zh-cn" or (lang == "auto" and "" or "en"),
        csrf = dispatcher.context.authtoken or ""
    })
end

local function fail(code, message)
    http.status(code, message)
    http.prepare_content("text/plain")
    http.write(message)
end

local function cgi(name)
    local value = http.getenv(name)
    if not value or value:find("[%c]") then return nil end
    return value
end

function network_api(...)
    local path = table.concat({...}, "/"):gsub("/$", "")
    local methods = allowed[path]
    if not methods then return fail(404, "Not Found") end
    local method = http.getenv("REQUEST_METHOD")
    if not methods[method] then return fail(405, "Method Not Allowed") end

    local sid, token = dispatcher.context.authsession, dispatcher.context.authtoken
    if not sid or not sid:match("^[a-f0-9]+$") or #sid ~= 32
        or not token or not token:match("^[a-f0-9]+$") then
        return fail(403, "Forbidden")
    end
    local host = cgi("HTTP_HOST")
    if not host then return fail(400, "Bad Request") end

    local body = ""
    if method == "POST" then
        local csrf = cgi("HTTP_X_CSRF_TOKEN") or http.formvalue("token", true)
        if csrf ~= token then return fail(403, "Forbidden") end
        local ctype = cgi("CONTENT_TYPE") or ""
        if ctype:lower():match("^%s*([^;%s]+)") ~= "application/json" then
            return fail(415, "Unsupported Media Type")
        end
        local size = tonumber(http.getenv("CONTENT_LENGTH")) or 0
        if size <= 0 then return fail(400, "Bad Request") end
        if size > 65536 then return fail(413, "Content Too Large") end
        body = http.content()
        if type(body) ~= "string" or #body ~= size then return fail(400, "Bad Request") end
    end

    -- Use HTTP/1.0 so the Go server returns a close-delimited or fixed-size body.
    local sock = nixio.connect("127.0.0.1", 3038)
    if not sock then return fail(502, "Bad Gateway") end
    sock:setopt("socket", "rcvtimeo", 30)
    sock:setopt("socket", "sndtimeo", 30)
    local request = {
        method .. " /cgi-bin/luci/istore/" .. path .. "/ HTTP/1.0",
        "Host: " .. host,
        "X-Forwarded-Sid: " .. sid,
        "X-Forwarded-Token: " .. token,
        "Content-Type: application/json",
        "Content-Length: " .. #body
    }
    local origin, site = cgi("HTTP_ORIGIN"), cgi("HTTP_SEC_FETCH_SITE")
    if origin then request[#request+1] = "Origin: " .. origin end
    if site then request[#request+1] = "Sec-Fetch-Site: " .. site end
    if not sock:sendall(table.concat(request, "\r\n") .. "\r\n\r\n" .. body) then
        sock:close()
        return fail(502, "Bad Gateway")
    end
    local lines = sock:linesource()
    local statusline = lines() or ""
    local status, reason = statusline:match("^HTTP/%d%.%d (%d%d%d) (.+)$")
    if not status then
        sock:close()
        return fail(502, "Bad Gateway")
    end
    local ctype = "application/json"
    local line = lines()
    while line and line ~= "" do
        local key, value = line:match("^([%w-]+):%s*(.+)$")
        if key and key:lower() == "content-type" then ctype = value end
        line = lines()
    end
    http.status(tonumber(status), reason)
    http.header("Cache-Control", "no-store")
    http.header("X-Content-Type-Options", "nosniff")
    http.prepare_content(ctype)
    local buffered = lines(true) or ""
    ltn12.pump.all(ltn12.source.cat(ltn12.source.string(buffered), sock:blocksource()), http.write)
    sock:close()
end
