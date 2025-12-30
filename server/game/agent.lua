
local skynet = require "skynet"
local base = require "base"
local Timer = require "utils.timer"
local cluster = require "skynet.cluster"
local queue = require "skynet.queue"()
local reference_server = require "reference.server"
local event = require "event"
require "mods.init"

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST


local ld = base.LocalData("agent")
local lf = base.LocalFunc("agent")

DATA.role = {}


local role_state = {
	unload = 1,
	loaded = 2,
	online = 3,
}

local ROLE = DATA.role
local debug_traceback = debug.traceback


function PUBLIC.get_db_key(rid)
	return string.format("game_rid:%s",rid or ROLE.rid)
end

function CMD.send2client(data)
	if ROLE and ROLE.fd then
		local gate_link = ROLE.gate_link
    	CMD.cluster_send(gate_link.node, gate_link.addr, "send2client", gate_link.client,data)
	end
end


function CMD.kick(why)
	why = why or "Unknown error"
	-- CMD.send2client(kick,{why = why})
	elog("kick",why)
	return true
end

function lf.load(rid)
	reference_server.init(30000) --保留五分钟
	ROLE.agent = skynet.self()
	ROLE.rid = rid
	skynet.fork(queue,function()
		assert(ROLE.STATE == role_state.unload)
		ROLE.STATE = role_state.loaded
	end)
	print("agent_load",dump(ROLE))
	event:dispatch("load",ROLE)
	event:dispatch("loaded",ROLE)
	ROLE.STATE = role_state.unload
	print("agent_load end")
	return
end

function lf.enter(args,gate_link)
	print("agent_enter",dump(args),dump(gate_link))
	assert(ROLE.STATE == role_state.loaded or ROLE.STATE == role_state.online)

	local fd = gate_link.fd
	-- assert(fd ~= ROLE.fd) -- 重登有可能不一样，所以这里不判断
	reference_server.ref()
	if ROLE.fd then
		CMD.kick("reenter")
		ROLE.fd = nil
		reference_server.unref()
	end
	ROLE.fd = fd
	ROLE.rid = args.rid
	ROLE.uid = args.uid
	ROLE.gate_link = gate_link
	ROLE.ip = gate_link.ip
	ROLE.online = true
	event:dispatch("enter",ROLE, args.seq)
	ROLE.STATE = role_state.online
	rlog(string.format("agent_enter(nickname:%s,rid:%s,uid:%s,fd:%s) ", ROLE.nickname, ROLE.rid,ROLE.uid,
		ROLE.fd or 0))

	CMD.cluster_send(gate_link.node, gate_link.addr, "update_game_link", gate_link.client, {
		node = skynet.getenv("cluster_name"),
		addr = skynet.self(),
	}, args.rid)
	-- 发送角色数据

	return true
end

function CMD.load(rid)
	queue(function()
		assert(not next(ROLE))
		lf.load(rid)
		-- print(dump(ROLE))
	end)

end

function CMD.enter(args, gate_link)
	if not gate_link.fd then return true end
	return queue(lf.enter,args,gate_link)
end


function lf.do_request(data, gate_link)
	ROLE.gate_link = gate_link
	local f = REQUEST[data.name]
	rlog("收到请求",data.name, f)
	if f then
		local ok, ret = xpcall(f, debug_traceback, ROLE,data)
		if not ok then
			elog("执行客户端请求失败",ret)
			return
		end
		-- dlog("协议处理结果",sdump(ret))
		if ret then
			ret.seq = data.seq
			ret.name = data.name
			CMD.send2client(ret)
		end
	else
		elog("not found function", data.name)
	end
end

function CMD.client_request(data, gate_link)
	queue(lf.do_request, data, gate_link)
end


local afk_timer
local function on_afk(self, fd)
	if not ROLE.fd then return end
	-- if ROLE.fd ~= fd then return end
	ROLE.fd = nil
	if ROLE.STATE == role_state.online then
		if afk_timer then
			if Timer.delete(afk_timer) then
				afk_timer = nil
				reference_server.unref()
			end
		end
		afk_timer = Timer.runAfter(100, function()
			afk_timer = nil
			queue(function()
				if ROLE.STATE == role_state.online then
					ROLE.STATE = role_state.loaded
					event:dispatch("leave",ROLE)
					reference_server.unref()
				end
			end)
		end)
	end
end

function CMD.disconnect(fd)
	queue(on_afk, fd)
	-- ROLE.fd = nil
	-- ROLE.online = false
	-- ROLE.offline = os.time()
	-- event:dispatch("leave",ROLE)
end

function PUBLIC.on_close_service()
	skynet.call("agent_manager", "lua", "agent_exit", ROLE.fd, ROLE.rid, skynet.self())
end

base.start_service()
