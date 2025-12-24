local skynet = require "skynet"
local base = require "base"
local Timer = require "utils.timer"

local REFS = {}

local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST



local function release(obj, addr, ver)
	if not obj or ver ~= obj.ver then return end
	if obj.ref == 0 then
		obj.ref = -1
		skynet.call(addr, "lua", "stop_service")
		rlog("没有引用，发送回收",addr)
	end
end

local function check(addr)
	local obj = REFS[addr]
	if not obj then return end
	local ref = obj.ref
	if ref == 0 then
		local ver = obj.ver + 1
		local delay = obj.delay
		obj.ver = ver
		if delay then
			obj.timer = Timer.runAfter(delay, function()
				release(REFS[addr], addr, ver)
			end)
		else
			release(obj, addr, ver)
		end
	end
end

function CMD.ref(addr, wait)
	local obj = REFS[addr]
	if obj then
		local ref = obj.ref
		if ref ~= -1 then
			obj.ref = ref + 1
			return true
		else
			if wait then
				local waitlist = obj.waitlist
				if not waitlist then
					waitlist = {}
					obj.waitlist = waitlist
				end
				-- table.insert(waitlist, skynet.response())
				-- return service.NORET

				local co = coroutine.running()
				table.insert(waitlist, co)
				skynet.wait(co)
				return nil, "quited"
			else
				return nil, "quiting"
			end
		end
	else
		return nil, "nofound"
	end
end

function CMD.unref(addr, n)
	local obj = assert(REFS[addr])
	local ref = obj.ref
	if ref ~= -1 then
		ref = ref - (n or 1)
		assert(ref >= 0)
		obj.ref = ref
		if ref == 0 then skynet.fork(check, addr) end
	end
	return ref
end

function CMD.init(addr, delay)
	assert(not REFS[addr])
	REFS[addr] = { ref = 0, delay = delay, ver = 0 }
	if delay then skynet.fork(check, addr) end
end

function CMD.release_mark(addr)
	local obj = assert(REFS[addr])
	obj.ref = -1
end

function CMD.release(addr)
	local obj = assert(REFS[addr])
	REFS[addr] = nil
	local waitlist = obj.waitlist
	if waitlist then
		for _, resp in ipairs(waitlist) do
			-- resp(true, nil, "quited")
			skynet.wakeup(resp)
		end
	end

end

base.start_service(".refd")
