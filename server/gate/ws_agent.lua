
local skynet = require "skynet"
local basefunc = require "basefunc"
local base = require "base"
local Timer = require "utils.timer"
local cluster = require "skynet.cluster"
local socketdriver = require "skynet.socketdriver"
local websocket = require "http.websocket"
local base_client = nil -- require("ws.ws_client")

local CMD = base.CMD
local PUBLIC = base.PUBLIC
local DATA = base.DATA
local LF = base.LocalFunc("websocket")


DATA.conf = nil
DATA.gate=nil
DATA.connection = {}
-- 客户端 id 表： id -> client
-- 此表作用： 避免 login server 踢出同一 gate 上玩家的多次登录时混淆
local id_clients = {}

local accept_fd = {}

-- 客户端 fd 表 ： fd -> client
local fd_clients = basefunc.listmap.new()

local function refresh_config()
	DATA.max_request_rate = tonumber(skynet.getenv("max_request_rate")) or 300 -- 每个客户端 5 秒内最大的请求数
end

local function error_handle(msg)
	print(tostring(msg) .. ":\n" .. tostring(debug.traceback()))
	return msg
end
---------------------------public----------------------------------------
-- 来自客户端的请求
function PUBLIC.request(fd,msg,sz)

	--TODO websocket需要调用skynet.trash吗 答：不需要
	local client = fd_clients:at(fd)
	if not client then
		print(string.format("error: message from fd (%d), not connected!", fd,msg))
		return
	end
	client:on_request(msg,sz)
end
--更新fd和id
function PUBLIC.gate_update(fd,id)
	skynet.send(DATA.gate,"lua","update_fd",fd,id,skynet.self())
end
function PUBLIC.disconnect(fd)

	local _client = fd_clients:at(fd)
	if _client then
		-- 移除映射
		fd_clients:erase(fd)
		id_clients[_client.id] = nil

		_client:on_disconnect()
	end
	skynet.send(DATA.gate,"lua","disconnect",fd,(_client or {}).id)
end
------------------------public 消息结束---------------------------------------

--[[
	public 必须要实现的函数
	connect
	handshake
	message
	close
	error
	warning

	connect handshake

]]
function LF.message(fd,msg,op)
	if op ~= "binary" then
		elog("必须是binary类型消息",fd,msg,op)
		return
	end
	PUBLIC.request(fd,msg,#msg)
end
function LF.warning(fd)
	elog("LF.warning",fd)
end
function LF.error(fd,why)
	elog("LF.error",fd,why)
	PUBLIC.disconnect(fd)
end
function LF.close(fd, code, reason)
	rlog("LF.close",fd, code, reason)
	PUBLIC.disconnect(fd, code, reason)
end
function LF.handshake(fd, header, url)
	-- local addr = websocket.addrinfo(fd)
	-- rlog("ws handshake from: " .. tostring(fd), "url", url, "addr:", addr)
	-- elog("LF.handshake",fd, header, url)
	return true
end
function LF.connect(fd)
	if DATA.conf.nodelay then
		socketdriver.nodelay(fd)
	end
	local addr = websocket.addrinfo(fd)

	local c = fd_clients:at(fd)
	if c then
		-- 此种可能性很小：前一个断开 事件还未来。 这时 旧的 client 必须废弃，否则消息会互串
		print(string.format("error:addr %s, fd %d  connected,client: ", addr, fd),c.id)

		fd_clients:erase(fd)
		id_clients[c.id] = nil
	end

	c = base_client.new()
	fd_clients:push_back(fd,c)
	id_clients[c.id] = c
	PUBLIC.gate_update(fd,c.id)
	skynet.send(DATA.gate,"lua","client_connected")
	c:on_connect(fd,addr)
end

-------------------------websocket消息结束------------------------------



-------------------------对外命令---------------------------------------
function CMD.update_game_agent(client_id, agent, rid)
	if not client_id then
		elog("gate_agent CMD.update_game_agent client_id is nil :"..tostring(client_id) )
		return
	end

	local _client = id_clients[client_id]

	if not _client then
		elog(string.format("gate_agent CMD.update_game_agent client_id '%s' is not exists !",tostring(client_id)))
		return
	end

	_client:update_game_agent(agent, rid)
end

function CMD.send2client(client_id,data)
	if not client_id then
		print("gate_agent CMD.send2client client_id is nil :"..tostring(client_id) ,data.name)
		return
	end

	local _client = id_clients[client_id]

	if not _client then
		print(string.format("gate_agent CMD.send2client client_id '%s' is not exists ! %s",tostring(client_id),data.name))
		return
	end

	_client:send2client(data)
end

function CMD.update_login_queue(now_size,last_deal_index,deal_index)
	DATA.deal_index = deal_index
	DATA.login_size = now_size
	DATA.login_deal_index = last_deal_index
	-- print("收到当前排队信息",now_size,last_deal_index,deal_index)
end
function CMD.login_callback(client_id,error_code,agent_link,arg3)
	local _client = id_clients[client_id]
	if _client then
		_client:login_callback(error_code,agent_link,arg3)
	else
		-- 登录成功，但是连接已经断开
		if error_code and agent_link then
			cluster.send(agent_link.node,agent_link.addr,"disconnect",agent_link.pid)
		else
			print("登录失败，正好连接也断开了，就不管了")
		end
	end
end

function CMD.accept(fd,addr)
	local ret,err = websocket.accept(fd, LF, DATA.conf.protocol, addr)
	rlog("accept",ret,err)
	return ret
end

-- 踢出某个客户端
function CMD.kick_client_fd(fd)
	websocket.close(fd)
end

-- 踢出某个客户端
function CMD.kick_client(_id,_call_event)

	local _client = id_clients[_id]
	if _client then

		if _client.fd then

			fd_clients:erase(_client.fd)
			websocket.close(_client.fd)
		end

		id_clients[_id] = nil

		if _call_event then
			_client:on_disconnect()
		end
	else
		print("kick_client is nil:",_id,_call_event)
	end
end

-- 更新函数，一秒一次
local function update(dt)
	local cur = fd_clients.list:front_item()
	while cur do

		-- 用 xpcall 隔离每个 client 的异常
		local ok,err = xpcall(cur[1].update,error_handle,cur[1],dt)
		if not ok then
			print(string.format("client update error,client id:%d,err:%s",err,cur[1].id,tostring(err)))
		end

		cur = cur.next
	end
end

function CMD.reload_sproto()
	base_client.load_sproto()
end

function CMD.broadcast_client(name,data)

	local cur = fd_clients.list:front_item()
	while cur do

		cur[1]:request_client(name,data)

		cur = cur.next
	end

end



function CMD.start(gate,gate_client_name,conf)

	-- base.set_hotfix_file("fix_gate_agent")

	-- print("start",gate,gate_client_name,conf)
	DATA.conf = conf
	base_client = require(gate_client_name)
	DATA.gate = gate
	-- 执行 update
	Timer.runEvery(1 * 100,update)

	refresh_config()
	
	Timer.runEvery(5 * 100,refresh_config)

	base_client.init()
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
			rlog(ret)
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
