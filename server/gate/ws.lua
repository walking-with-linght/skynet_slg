--[[
 $ @Author: 654146770@qq.com
 $ @Date: 2024-06-05 21:52:14
 $ @LastEditors: 654146770@qq.com
 $ @LastEditTime: 2024-07-21 16:39:39
 $ @FilePath: \my_skynet_lib\server\gate_server\logic\service\ws\ws.lua
]]


local skynet = require "skynet"
local base = require "base"
local socket = require "skynet.socket"

local CMD=base.CMD
local PUBLIC=base.PUBLIC
local DATA=base.DATA

local client_number = 0
local maxclient -- max client
local protocol

DATA.ws_agents = {}
DATA.fd_agent = {}
DATA.clientid_agent = {}

function CMD.kick(fd)
	if DATA.fd_agent[fd] then
		skynet.send(DATA.fd_agent[fd],"lua","kick_client_fd",fd)
	end
end
function CMD.kick_client(clientid)
	if DATA.clientid_agent[clientid] then
		skynet.send(DATA.clientid_agent[clientid],"lua","kick_client",clientid)
	end
end

function CMD.broadcast_agent(...)
	for i,v in pairs(DATA.ws_agents) do
		skynet.send(v,"lua",...)
	end
end

-- 重新加载协议
function CMD.reload_sproto()
	CMD.broadcast_agent("reload_sproto")
end

-- 向所有的 client 发送请求
function CMD.broadcast_client(_name,_data)
	CMD.broadcast_agent("broadcast_client",_name,_data)
end

function CMD.stop_service()
	skynet.timeout(10,function ()
		skynet.exit()
	end)

	return "ok"
end

function CMD.update_fd(fd,id,agent)
	print("update_fd",fd,id,agent)
	DATA.fd_agent[fd] = agent
	DATA.clientid_agent[id] = agent
end
function CMD.disconnect(fd,id)
	if fd and DATA.fd_agent[fd] then
		DATA.fd_agent[fd] = nil
	end
	if id and DATA.clientid_agent[id] then
		DATA.clientid_agent[id] = nil
	end
	print("disconnect",fd,id)
	client_number = client_number - 1
end

function CMD.get_max_client()
    return client_number
end
function CMD.client_connected()
    client_number = client_number + 1
end
function CMD.start( conf)
    print(dump(conf))
    local instance = conf.instance or 8
    assert(instance > 0)
    -- skynet.send("monitor","lua","add_service","ws",skynet.self())
	maxclient = conf.maxclient
    local balance = 1
    for i=1,instance do
        table.insert(DATA.ws_agents, skynet.newservice("ws_agent"))
    end
	
    for i=1,instance do
        local s = DATA.ws_agents[i]
        skynet.call(s, "lua", "start", skynet.self(),"ws_client",conf)
    end
    local address = conf.address or "0.0.0.0"
    local port = assert(conf.port)
    protocol = conf.protocol or "ws"
    local _fd = socket.listen(address, port)
    rlog(string.format("Listen websocket port:%s protocol:%s", port, protocol))
    socket.start(_fd, function(fd, addr)
        if client_number > maxclient then
            error("client_number max" .. client_number .. ":" .. maxclient)
            return
        end
        rlog(string.format("accept client socket_fd: %s addr:%s", fd, addr))

        local s = DATA.ws_agents[balance]
        balance = balance + 1
        if balance > #DATA.ws_agents then
            balance = 1
        end
        local ok, err = skynet.call(s, "lua", "accept", fd, addr)
		
        if not ok then
            elog(string.format("invalid client (fd = %d) error = %s", fd, err))
        end
    end)
end


-- 启动服务
-- 服务主入口
skynet.start(function()
    skynet.dispatch("lua", function(session, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.ret(skynet.pack(nil, "command not found"))
            return
        end
        
        local ok, ret,ret2,ret3,ret4 = pcall(f, ...)
        if not ok then
            rlog("error",ret)
        end
        if session ~= 0 then
            if ok  then
                skynet.retpack(ret,ret2,ret3,ret4)
            else
                skynet.ret(skynet.pack(nil, ret))
            end
        end
    end)
end)
