local skynet = require "skynet"
local redis = require "skynet.db.redis"
require "skynet.manager"

local db

local function ping()
	while true do
		if db then
			local res = db:set("ping", 1)
			dlog("redis status:",dump(res))
		end
		skynet.sleep(100*60*60)
	end
end

local CMD = {}

function CMD.open( conf )
	db = redis.connect(conf)
	-- skynet.fork(ping)
	skynet.register(conf.name or ("."..conf.database))
end

function CMD.close()
	if db then
		db:disconnect()
		db = nil
	end
end

function CMD.set(key, value)
	return db:set(key, value)
end

function CMD.get(key)
	return db:get(key)
end

function CMD.exist(key)
	return db:exist(key)
end

function CMD.setNx(key, value)
	return db:set(key, value, "NX")
end

function CMD.expire(key, ttl)
	db:expire(key, ttl)
end

function CMD.incrbyfloat(key,value)
	return db:incrbyfloat(key,value)
end

function CMD.incrby(key,value)
	return db:incrby(key,value)
end

function CMD.decrbyfloat(key,value)
	return db:decrbyfloat(key,value)
end

function CMD.decrby(key,value)
	return db:decrby(key,value)
end

function CMD.del(key)
	db:del(key)
end

-- hash
function CMD.hgetall(key)
	local data = db:hgetall(key)
	local rs = {}
    if data ~= nil then
        for k,v in pairs(data) do
            if k % 2 == 1 then
                rs[v] = data[k+1]
            end
        end
    end
	return rs
end

function CMD.hget(key,field)
	return db:hget(key,field)
end


function CMD.hmget(key,fields)
	return db:hmget(key,table.unpack(fields))
end
function CMD.mget(keys)
    if not keys or #keys == 0 then
        return {}
    end
    
    -- 调用原生mget
    local result = db:mget(table.unpack(keys))
    return result or {}
end

function CMD.hincrby(key,field,value)
	return db:hincrby(key,field,value)
end

function CMD.hset(key,field,value)
	return db:hset(key,field,value)
end

function CMD.hmset(key,fields)
	-- 这是人写的？
	-- for k,v in pairs(fields) do
	-- 	CMD.hset(key,k,v)
	-- end

	local tb  = {}
	for k,v in pairs(fields) do
		table.insert(tb,k)
		table.insert(tb,v)
	end
	return db:hmset(key, table.unpack(tb))
end

function CMD.hdel(key, field)
	return db:hdel(key, field)
end


------list------
-- 移除并返回列表key的头元素
function CMD.lpop(key)
	return db:lpop(key)
end

function CMD.lpush(key, value)
	return db:lpush(key, value)
end

-- 只能将一个值value插入到列表key的表尾
function CMD.rpush(key, value)
	return db:rpush(key, value)
end

function CMD.lrem(key, value)
	return db:lrem(key, 0, value)
end

function CMD.llen(key)
	return db:llen(key)
end

-------set------
function CMD.sadd(key, value)
	return db:sadd(key, value)
end

function CMD.sismember(key, member)
	return db:sismember(key, member)
end

function CMD.smembers(key)
	return db:smembers(key)
end

----- zsort
function CMD.zadd(key, uid, value)
	return db:zadd(key, value, uid)
end

function CMD.zrevrank(key, uid)
	return db:zrevrank(key, uid)
end

function CMD.zcard(key)
	return db:zcard(key)
end

function CMD.zrank(key, uid)
	return db:zrank(key, uid)
end

function CMD.zrem(key, uid)
	return db:zrem(key, uid)
end

function CMD.zrangebyscore(key, min, max)
	local data = db:zrangebyscore(key,min,max)
	-- tlog(dump(data))
	if data ~= nil then  
        return data[1]
    end
	return nil
end

function CMD.zrange(key,min,max)
	local data = db:zrange(key,min,max)
	local rs = {}
	if data ~= nil then
        for k,v in ipairs(data) do
			rs[math.ceil(v)] = k
        end
    end
	return rs
end

function CMD.zrevrange(key,min,max)
	local data = db:zrevrange(key,min,max)
	local rs = {}
	if data ~= nil then
        for k,v in ipairs(data) do
			rs[math.ceil(v)] = k
        end
    end
	return rs
end

function CMD.publish(channel, data)
	db:publish(channel, data)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, ...)
		print("redis pool cmd",cmd)
		local f = CMD[cmd]
		if not f then
            skynet.ret(skynet.pack(db[cmd](db,...)))
            return
        end
        local ok, ret = xpcall(f, debug.traceback, ...)
        if not ok then
			print("redis error",cmd,ret)
            skynet.ret(skynet.pack(nil, ret))
        else
            skynet.ret(skynet.pack(ret))
        end
	end)
end)

