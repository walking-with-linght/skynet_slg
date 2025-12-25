local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local cjson   = require "cjson"
require "skynet.manager"

local pool = {}
local maxconn
local index = 1
local function getconn()
	local db
	db = pool[index]
	assert(db)
	index = index + 1
	if index > maxconn then
		index = 2
	end
	return db
end

local function ping()
	while true do
		for _,db in pairs(pool) do
			local res = db:query("select version();")
			dlog("mysql_db status:",cjson.encode(res))
		end
		skynet.sleep(100*60*60)
	end
end

local CMD = {}

function CMD.open( conf )
	maxconn = tonumber(skynet.getenv("mysql_maxconn")) or 10
	assert(maxconn >= 2)
	for i = 1, maxconn do
		local db = mysql.connect(conf)
		if db then
			table.insert(pool, db)
		else
			skynet.error("mysql connect error")
		end
	end
	skynet.fork(ping)
	skynet.register(conf.name or ("."..conf.database))
end

function CMD.close( )
	for _, db in pairs(pool) do
		db:disconnect()
	end
	pool = {}
end

local function query(db, sql)
	return db:query(sql)
end

function CMD.execute(sql)
	-- dlog('sql: ',sql)
	local db = getconn()
    local ok, rs = pcall(query, db, sql)
	if ok == false or (rs.errno ~=nil and tonumber(rs.errno) > 0 )then
		ok = false
		elog("error_sql: ".. sql .."----- result:----'%s'",cjson.encode(rs))
	end
	return ok,rs
end


function CMD.insert( tablename, rows )
	local cols = {}
	local vals = {}
	for k, v in pairs(rows) do
		table.insert(cols, k)
		if type(v) == "string" then
			v = mysql.quote_sql_str(v)
		end
		table.insert(vals, v)
	end
	local vals_str = table.concat(vals, ",")
	local cols_str = table.concat(cols, "`,`") 
	local sql = string.format("insert into %s(`%s`) values(%s);", tablename, cols_str, vals_str)
	local ret,result = CMD.execute(sql)
	return ret,result and result.insert_id or 0
end

function CMD.insertAll( tablename, rows )
	local columns = {}
	local cols = {}
	for k, v in pairs(rows[1]) do
		table.insert(cols, k)
	end
	local cols_str = table.concat(cols, "`,`")
	for _, row in ipairs(rows) do
		local vals = {}
		for _,k in ipairs(cols) do
			local v = row[k]
			-- table.insert(cols, v)
			if type(v) == "string" then
				v = mysql.quote_sql_str(v)
			end
			table.insert(vals, v)
		end
		local vals_str = table.concat(vals, ",")
		table.insert(columns,vals_str)
	end

	local sql = string.format("insert into %s(`%s`) values ", tablename, cols_str)

	for _,value in ipairs(columns) do
		sql = sql .. string.format("(%s),",value)
	end
	sql = string.sub(sql, 0, -2)
	local ret,result = CMD.execute(sql)
	return ret,result
end

function CMD.delete( tablename, key, value )
	local sql = string.format("delete from %s where %s = %s;", tablename, key, mysql.quote_sql_str(tostring(value)))
	local ret, result = CMD.execute(sql)
	return ret
end

function CMD.update( tablename, key, value, row )
	local t = {}
	for k,v in pairs(row) do
		if type(v) == "string" then
			v = mysql.quote_sql_str(v)
		end
		table.insert(t, "`"..k.."`="..v)
	end
	local setvalues = table.concat(t, ",")
	local sql = string.format("update %s set %s where %s = '%s';", tablename, setvalues, key, value)
	local ret,result = CMD.execute(sql)
	return ret
end

function CMD.update_add( tablename, key, value, row )
	local t = {}
	for k,v in pairs(row) do
		if type(v) == "string" then
			v = mysql.quote_sql_str(v)
		end
		table.insert(t, k.."="..k..'+'..v)
	end
	local setvalues = table.concat(t, ",")
	local sql = string.format("update %s set %s where %s = '%s';", tablename, setvalues, key, value)
	skynet.error(sql)
	local ret,result = CMD.execute(sql)
	return ret
end

function CMD.update_decr( tablename, key, value, row )
	local t = {}
	for k,v in pairs(row) do
		if type(v) == "string" then
			v = mysql.quote_sql_str(v)
		end
		table.insert(t, k.."="..k..'-'..v)
	end
	local setvalues = table.concat(t, ",")
	local sql = string.format("update %s set %s where %s = '%s';", tablename, setvalues, key, value)
	local ret,result = CMD.execute(sql)
	return ret
end

function CMD.select_by_key( tablename, key, value )
	local sql = string.format("select * from %s where %s = '%s';", tablename, key, value)
	local ret,result = CMD.execute(sql)
	return ret,result
end

function CMD.select_one_by_key( tablename, key, value )
	local sql = string.format("select * from %s where %s = '%s';", tablename, key, value)
	local ret, result = CMD.execute(sql)
	return ret, result and result[1]
end

function CMD.select_one_by_conditions( tablename, condition )
	local t = {}
	for k,v in pairs(condition) do
		if type(v) == "string" then
			v = mysql.quote_sql_str(v)
		end
		table.insert(t, "`"..k.."`="..v)
	end
	local where = table.concat(t, " and ")
	local sql = string.format("select * from %s where %s", tablename, where)
	local ret, result = CMD.execute(sql)
	return ret, result and result[1]
end


function CMD.select_by_conditions( tablename, condition, orders, offset, limit)
	-- where
	local t = {}
	for k,v in pairs(condition) do
		if type(v) == "string" then
			v = mysql.quote_sql_str(v)
		end
		table.insert(t, "`"..k.."`="..v)
	end
	local where = table.concat(t, " and ")
	local sql = string.format("select * from %s where %s", tablename, where)

	if orders then
		local orderstr = " order by "
		for field,sort in pairs(orders) do
			orderstr = orderstr .. field .. " " .. sort
		end
		sql = sql .. orderstr
	end

	if limit and offset then
		sql = sql .. string.format(" limit %d,%d",offset ,limit)
	end
	local ret,result = CMD.execute(sql)
	if ret then
		return ret, result or nil
	end
	return ret
end

function CMD.select_all( tablename )
	local sql = string.format("select * from %s;", tablename)
	local ret,result = CMD.execute(sql)
	if ret then
		return ret, result
	end
	return false
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, ...)
		local f = assert(CMD[cmd], "can't not find cmd :"..(cmd or "empty"))
		if session == 0 then
			f(...)
		else
			skynet.ret(skynet.pack(f(...)))
		end
	end)
end)

