local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local cjson = require "cjson"
local urllib = require "http.url"
require "utils"
local protocol,handle_path = ...
protocol = protocol or "http"
local handle = require(handle_path)


-- 正常的功能性请求
local METHOD_NORMAL = {
    POST = true,
    GET = true,
}

local common_header = {
    -- 跨域访问支持
    ["Access-Control-Allow-Origin"] = "*", -- 这里写允许访问的域名就可以了，允许所有人访问的话就写*
    ["Access-Control-Allow-Credentials"] = false,   
    ["Access-Control-Allow-Headers"] = "*",
    -- ["Content-Type"] = "application/json;charset=utf-8",
}

local function response(id, write, ...)
    local ok, err = httpd.write_response(write, ...)
    if not ok then
        -- if err == sockethelper.socket_error , that means socket closed.
        skynet.error(string.format("fd = %d, %s", id, err))
    end
    skynet.error("fd=", id)
end

local function handle_request(id, url, method, header, body, interface)
    local path, query_str = urllib.parse(url)
    local query
    if query_str then
        query = urllib.parse_query(query_str)
    else
        query = {}
    end
    -- rlog("handle_request",cjson.encode({path, method, header, body, query}))
    local code, ret, new_header = handle(path, method, header, body, query)
    if type(ret) == 'table' then
        ret = cjson.encode(ret)
    end
    if new_header and type(new_header) == "table" then
        table.merge(new_header, common_header)
    end
    -- print(dump(new_header or common_header))
    response(id, interface.write, code or 404, ret or "", new_header or common_header)

end

local SSLCTX_SERVER = nil
local function gen_interface(protocol, fd)
    if protocol == "http" then
        return {
            init = nil,
            close = nil,
            read = sockethelper.readfunc(fd),
            write = sockethelper.writefunc(fd),
        }
    elseif protocol == "https" then
        local tls = require "http.tlshelper"
        if not SSLCTX_SERVER then
            SSLCTX_SERVER = tls.newctx()
            -- gen cert and key
            -- openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout server-key.pem -out server-cert.pem
            local certfile = skynet.getenv("certfile") or "./server-cert.pem"
            local keyfile = skynet.getenv("keyfile") or "./server-key.pem"
            rlog(certfile, keyfile)
            SSLCTX_SERVER:set_cert(certfile, keyfile)
        end
        local tls_ctx = tls.newtls("server", SSLCTX_SERVER)
        return {
            init = tls.init_responsefunc(fd, tls_ctx),
            close = tls.closefunc(tls_ctx),
            read = tls.readfunc(fd, tls_ctx),
            write = tls.writefunc(fd, tls_ctx),
        }
    else
        error(string.format("Invalid protocol: %s", protocol))
    end
end

local function close(id, interface)
    socket.close(id)
    if interface.close then
        interface.close()
    end
end

skynet.start(function()
    skynet.dispatch("lua", function (_,_,id)
        socket.start(id)
        skynet.error("start id:", id)
        local interface = gen_interface(protocol, id)
        if interface.init then
            local ok, err = pcall(interface.init)
            if not ok then
                skynet.error("init error", err)
                close(id, interface)
                return
            end
        end
        -- limit request body size to 8192 (you can pass nil to unlimit)
        local code, url, method, header, body = httpd.read_request(interface.read, nil)
        skynet.error(code, url, method)
        if not code then
            if url == sockethelper.socket_error then
                skynet.error("socket closed")
            else
                skynet.error(url)
            end
            close(id, interface)
            return
        end

        if code ~= 200 then
            response(id, interface.write, code)
            close(id, interface)
            return
        end
        -- 不是正常性功能请求， 则只需要返回头信息
        if not METHOD_NORMAL[method] then
            response(id, interface.write, 200, "",common_header)
            close(id, interface)
            return
        end
        if url == "/favicon.ico" then
            response(id, interface.write, 200, "",common_header)
            close(id, interface)
            return
        end
    
        local ok, error = pcall(handle_request,id, url, method, header, body, interface)
        if not ok then
            elog(error)
        end
        close(id, interface)
    end)
end)

