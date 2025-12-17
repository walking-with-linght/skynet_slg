local skynet = require "skynet"
local reference_client = require "reference.client"
local base = require "base"

local DATA = base.DATA -- 本服务使用的表
local CMD = base.CMD -- 供其他服务调用的接口
local PUBLIC = base.PUBLIC -- 本服务调用的接口

local ld = base.LocalData("agent_manager")
local lf = base.LocalFunc("agent_manager")

local roles = {}

local role_agent = 0
local prepool = {}
local presize = 2
local in_prepare

local QUIT = nil

local function thread_prepareagent(sz)
	for _ = #prepool + 1, sz or presize do
		table.insert(prepool, skynet.newservice("agent"))
	end
end

local function new_agent(rid)
	local agent = table.remove(prepool)
	if not agent then agent = skynet.newservice("agent") end
	role_agent = role_agent + 1
	if not in_prepare then
		in_prepare = true
		skynet.fork(function()
			local ok, err = pcall(thread_prepareagent)
			in_prepare = nil
			if not ok then error(err) end
		end)
	end
	local ok, err = pcall(skynet.call, agent, "lua", "load", rid)
	if not ok then
		skynet.send(agent, "lua", "stop_service")
		error(err)
	end
	return agent
end


local assign_in, assign_all, assign_time = 0, 0, 0
local assigning = {}
local function agent_load(rid)
	assert(not QUIT)
	local agent = roles[rid]
	if agent then return agent end
	local waitlist = assigning[rid]
	if waitlist then
		table.insert(waitlist, (coroutine.running()))
		skynet.wait()
		agent = roles[rid]
		if not agent then error("agent load failure " .. rid) end
		return agent
	else
		waitlist = {}
		assigning[rid] = waitlist
		assign_in = assign_in + 1
		local ti = skynet.hpc()
		local ok
		ok, agent = pcall(new_agent, rid)
		assign_in, assign_all = assign_in - 1, assign_all + 1
		assign_time = assign_time + (skynet.hpc() - ti) // 1000000
		assigning[rid] = nil

		for _, co in ipairs(waitlist) do skynet.wakeup(co) end

		if not ok then
			error(agent)
		else
			roles[rid] = agent
		end
		return agent
	end
end
local function query_agent(rid)
	rid = assert(tonumber(rid))
	while true do
		local agent = roles[rid]
		if agent then
			local ref = reference_client.ref(agent, true)
			if ref then return ref end
			skynet.yield()
		else
			-- if role == nil then
			-- 	role = {
			-- 		rid = d[1],
			-- 		nickname = d[2],
			-- 		create_ti = d[3]
			-- 	}
			-- end
			agent_load(rid)
		end
	end
end

lf.agent_load = agent_load
lf.query_agent = query_agent


local function query_agent_loaded(rid)
	local agent = roles[rid]
	if agent then
		local ref = reference_client.ref(agent, true)
		if ref then return ref end
	end
end

lf.query_agent_loaded = query_agent_loaded

-- function lf.prepareagent()
-- 	thread_prepareagent(1)
-- 	skynet.fork(thread_prepareagent)
-- end



function CMD.agent_call_loaded(rid, ...)
	local ref <close> = query_agent_loaded(rid)
	if ref then return skynet.call(ref.addr, ...) end
end

function CMD.agent_call(rid, ...)
	local ref <close> = query_agent(rid)
	return skynet.call(ref.addr, ...)
end


function CMD.agent_send(rid, ...)
	local ref <close> = query_agent(rid)
	return skynet.send(ref.addr, ...)
end


function CMD.agent_send_loaded(rid, ...)
	local ref <close> = query_agent_loaded(rid)
	if ref then skynet.send(ref.addr, ...) end
end

function CMD.agent_online_send(rid, ...)
	CMD.agent_send_loaded(rid, "lua", "online_send", ...)
end

function CMD.agent_send_online_all(...)
	local copy = {}
	for rid in pairs(roles) do copy[rid] = true end
	for rid in pairs(copy) do _LUA.agent_online_send(rid, ...) end
end

function CMD.dispatch_agent_send(cmd, rid, ...)
	local agent = roles[rid]
	if agent then skynet.call(agent, "lua", cmd, ...) end
end

function CMD.dispatch_call_agent(cmd, rid, ...)
	local agent = roles[rid]
	if agent then
		return true, skynet.call(agent, "lua", cmd, ...)
	else
		return false
	end
end

function CMD.agent_exit(fd, rid, addr)
	if rid then
		if roles[rid] then
			roles[rid] = nil
			role_agent = role_agent - 1
		end
	end
	-- if fd then CMD.detachagent(fd, rid) end
	if addr then
		for idx, agent in ipairs(prepool) do
			if agent == addr then
				table.remove(prepool, idx)
				break
			end
		end
	end
end
