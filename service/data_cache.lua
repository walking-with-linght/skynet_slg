-- data_cache_v2.lua
local skynet = require "skynet"
local cjson = require "cjson"
require "skynet.manager"

local CMD = {}

-- 服务引用
local mysql_service
local redis_service

-- 配置
local config = {
    -- 默认缓存时间（秒）
    default_ttl = 3600,
    -- 是否启用异步保存
    async_save = true,
    -- 异步保存批次大小
    batch_size = 100,
}

-- 数据结构定义
local schema = {
    -- 用户表结构
    user = {
        redis_key = function(id) return string.format("user:%d", id) end,
        mysql_table = "user",
        primary_key = "uid",
        fields = {
            "uid", "name", "level", "exp", "gold", "diamond", "vip_level",
            "last_login", "create_time", "status"
        },
        -- 需要序列化的字段
        json_fields = {"equipment", "bag", "skills"}
    },
    
    -- 物品表结构
    item = {
        redis_key = function(id) return string.format("item:%d", id) end,
        mysql_table = "items",
        primary_key = "item_id",
        fields = {
            "item_id", "owner_id", "item_type", "item_num", "bind_status",
            "expire_time", "create_time"
        },
        json_fields = {"attributes", "enchantments"}
    },
    
    -- 邮件表结构
    mail = {
        redis_key = function(id) return string.format("mail:%d", id) end,
        mysql_table = "mails",
        primary_key = "mail_id",
        fields = {
            "mail_id", "receiver_id", "sender_id", "title", "content",
            "attachments", "read_status", "receive_time", "expire_time"
        },
        json_fields = {"attachments"}
    },
    
    -- 可以继续添加其他表...
}

-- 待写入队列
local write_queue = {}
local queue_size = 0

-- 初始化服务
function CMD.init(mysql_svc, redis_svc)
    mysql_service = mysql_svc
    redis_service = redis_svc
    
    -- 启动异步保存协程
    if config.async_save then
        skynet.fork(function()
            CMD.async_write_loop()
        end)
    end
end

-- 序列化JSON字段
local function serialize_json_fields(data, table_schema)
    if not table_schema.json_fields then
        return data
    end
    
    local result = {}
    for k, v in pairs(data) do
        result[k] = v
    end
    
    for _, field in ipairs(table_schema.json_fields) do
        if result[field] and type(result[field]) == "table" then
            result[field] = cjson.encode(result[field])
        end
    end
    
    return result
end

-- 反序列化JSON字段
local function deserialize_json_fields(data, table_schema)
    if not table_schema.json_fields then
        return data
    end
    
    local result = {}
    for k, v in pairs(data) do
        result[k] = v
    end
    
    for _, field in ipairs(table_schema.json_fields) do
        if result[field] and type(result[field]) == "string" then
            local ok, decoded = pcall(cjson.decode, result[field])
            if ok then
                result[field] = decoded
            end
        end
    end
    
    return result
end

-- 从Redis哈希表加载数据
local function load_from_redis(table_name, id)
    local table_schema = schema[table_name]
    if not table_schema then
        return nil, "unknown table"
    end
    
    local redis_key = table_schema.redis_key(id)
    local redis_data = skynet.call(redis_service, "lua", "hgetall", redis_key)
    
    if not redis_data or #redis_data == 0 then
        return nil, "not_found_in_redis"
    end
    
    -- 将Redis哈希表转换为Lua表
    local data = {}
    for i = 1, #redis_data, 2 do
        local key = redis_data[i]
        local value = redis_data[i+1]
        if value ~= cjson.null then
            data[key] = value
        end
    end
    
    -- 检查是否有数据
    if not next(data) then
        return nil, "empty_data"
    end
    
    -- 反序列化JSON字段
    data = deserialize_json_fields(data, table_schema)
    
    return data, "from_redis"
end

-- 保存数据到Redis哈希表
local function save_to_redis(table_name, data, ttl)
    local table_schema = schema[table_name]
    if not table_schema then
        return false
    end
    
    local id = data[table_schema.primary_key]
    if not id then
        return false
    end
    
    local redis_key = table_schema.redis_key(id)
    
    -- 序列化JSON字段
    local redis_data = serialize_json_fields(data, table_schema)
    
    -- 转换为Redis HMSET需要的数组格式
    local fields_array = {}
    for k, v in pairs(redis_data) do
        table.insert(fields_array, k)
        if v == nil then
            table.insert(fields_array, "")
        else
            table.insert(fields_array, tostring(v))
        end
    end
    
    -- 保存到Redis
    if ttl and ttl > 0 then
        skynet.call(redis_service, "lua", "hmsetex", redis_key, ttl, fields_array)
    else
        skynet.call(redis_service, "lua", "hmset", redis_key, fields_array)
    end
    
    return true
end

-- 通用查询：先查Redis哈希表，再查MySQL
function CMD.query(table_name, id, options)
    options = options or {}
    local force_refresh = options.force_refresh or false
    local cache_ttl = options.cache_ttl or config.default_ttl
    
    local table_schema = schema[table_name]
    if not table_schema then
        return nil, "unknown_table"
    end
    
    -- 1. 先尝试从Redis加载
    if not force_refresh then
        local data, source = load_from_redis(table_name, id)
        if data then
            -- 更新过期时间
            if cache_ttl > 0 then
                local redis_key = table_schema.redis_key(id)
                skynet.call(redis_service, "lua", "expire", redis_key, cache_ttl)
            end
            return data, source
        end
    end
    
    -- 2. Redis未命中，查询MySQL
    local ok, result = skynet.call(mysql_service, "lua", "select_one_by_key", 
        table_schema.mysql_table, table_schema.primary_key, id)
    
    if not ok or not result then
        -- 可以在Redis中设置一个特殊标记防止缓存穿透
        return nil, "not_found"
    end
    
    -- 3. 保存到Redis
    save_to_redis(table_name, result, cache_ttl)
    
    return result, "from_mysql"
end

-- 批量查询
function CMD.batch_query(table_name, ids, options)
    options = options or {}
    local cache_ttl = options.cache_ttl or config.default_ttl
    
    local table_schema = schema[table_name]
    if not table_schema then
        return {}, "unknown_table"
    end
    
    local results = {}
    local miss_ids = {}
    
    -- 1. 批量从Redis加载
    for _, id in ipairs(ids) do
        local data, _ = load_from_redis(table_name, id)
        if data then
            results[id] = data
            -- 更新过期时间
            if cache_ttl > 0 then
                local redis_key = table_schema.redis_key(id)
                skynet.call(redis_service, "lua", "expire", redis_key, cache_ttl)
            end
        else
            table.insert(miss_ids, id)
        end
    end
    
    -- 2. 查询MySQL获取未命中的数据
    if #miss_ids > 0 then
        -- 构建IN查询
        local id_str = table.concat(miss_ids, ",")
        local sql = string.format("SELECT * FROM %s WHERE %s IN (%s)", 
            table_schema.mysql_table, table_schema.primary_key, id_str)
        
        local ok, db_results = skynet.call(mysql_service, "lua", "execute", sql)
        
        if ok and db_results then
            for _, row in ipairs(db_results) do
                local id = row[table_schema.primary_key]
                results[id] = row
                -- 保存到Redis
                save_to_redis(table_name, row, cache_ttl)
            end
        end
    end
    
    return results, #miss_ids == 0 and "all_from_cache" or "partial_from_db"
end

-- 保存数据
function CMD.save(table_name, data, options)
    options = options or {}
    local is_new = options.is_new or false
    local async = options.async or config.async_save
    local cache_ttl = options.cache_ttl or config.default_ttl
    
    local table_schema = schema[table_name]
    if not table_schema then
        return false, "unknown_table"
    end
    
    local id = data[table_schema.primary_key]
    if not id then
        return false, "no_primary_key"
    end
    
    -- 1. 更新Redis
    save_to_redis(table_name, data, cache_ttl)
    
    -- 2. 保存到MySQL
    if async then
        -- 异步保存
        local write_op = {
            type = is_new and "insert" or "update",
            table_schema = table_schema,
            data = data,
            timestamp = skynet.now(),
            is_new = is_new
        }
        
        table.insert(write_queue, write_op)
        queue_size = queue_size + 1
        
        -- 触发批量保存
        if queue_size >= config.batch_size then
            skynet.fork(function()
                CMD.flush_write_queue()
            end)
        end
    else
        -- 同步保存
        return CMD.save_to_mysql(table_schema, data, is_new)
    end
    
    return true, "saved_to_cache"
end

-- 保存到MySQL
function CMD.save_to_mysql(table_schema, data, is_new)
    if is_new then
        -- 新增数据
        return skynet.call(mysql_service, "lua", "insert", 
            table_schema.mysql_table, data)
    else
        -- 更新数据
        local update_data = {}
        for k, v in pairs(data) do
            if k ~= table_schema.primary_key then
                update_data[k] = v
            end
        end
        
        return skynet.call(mysql_service, "lua", "update",
            table_schema.mysql_table, table_schema.primary_key, 
            data[table_schema.primary_key], update_data)
    end
end

-- 删除数据
function CMD.delete(table_name, id, options)
    options = options or {}
    local async = options.async or config.async_save
    
    local table_schema = schema[table_name]
    if not table_schema then
        return false, "unknown_table"
    end
    
    local redis_key = table_schema.redis_key(id)
    
    -- 1. 删除Redis缓存
    skynet.call(redis_service, "lua", "del", redis_key)
    
    -- 2. 删除MySQL数据
    if async then
        local write_op = {
            type = "delete",
            table_schema = table_schema,
            id = id,
            timestamp = skynet.now()
        }
        
        table.insert(write_queue, write_op)
        queue_size = queue_size + 1
    else
        return skynet.call(mysql_service, "lua", "delete",
            table_schema.mysql_table, table_schema.primary_key, id)
    end
    
    return true, "deleted_from_cache"
end

-- 更新特定字段（原子操作）
function CMD.update_field(table_name, id, field_updates, options)
    options = options or {}
    local async = options.async or config.async_save
    local cache_ttl = options.cache_ttl or config.default_ttl
    
    local table_schema = schema[table_name]
    if not table_schema then
        return false, "unknown_table"
    end
    
    local redis_key = table_schema.redis_key(id)
    
    -- 1. 更新Redis（原子操作）
    for field, value in pairs(field_updates) do
        -- 如果是JSON字段，需要序列化
        local is_json = false
        if table_schema.json_fields then
            for _, json_field in ipairs(table_schema.json_fields) do
                if json_field == field then
                    is_json = true
                    break
                end
            end
        end
        
        local final_value = value
        if is_json and type(value) == "table" then
            final_value = cjson.encode(value)
        end
        
        skynet.call(redis_service, "lua", "hset", redis_key, field, tostring(final_value))
    end
    
    -- 更新过期时间
    if cache_ttl > 0 then
        skynet.call(redis_service, "lua", "expire", redis_key, cache_ttl)
    end
    
    -- 2. 异步更新MySQL
    if async then
        local write_op = {
            type = "update_fields",
            table_schema = table_schema,
            id = id,
            field_updates = field_updates,
            timestamp = skynet.now()
        }
        
        table.insert(write_queue, write_op)
        queue_size = queue_size + 1
    else
        -- 同步更新
        return skynet.call(mysql_service, "lua", "update",
            table_schema.mysql_table, table_schema.primary_key, id, field_updates)
    end
    
    return true, "field_updated"
end

-- 清空写入队列
function CMD.flush_write_queue()
    if queue_size == 0 then
        return true
    end
    
    local batch = write_queue
    write_queue = {}
    queue_size = 0
    
    for _, write_op in ipairs(batch) do
        if write_op.type == "delete" then
            skynet.call(mysql_service, "lua", "delete",
                write_op.table_schema.mysql_table, 
                write_op.table_schema.primary_key, 
                write_op.id)
        elseif write_op.type == "update_fields" then
            skynet.call(mysql_service, "lua", "update",
                write_op.table_schema.mysql_table,
                write_op.table_schema.primary_key,
                write_op.id,
                write_op.field_updates)
        else
            CMD.save_to_mysql(write_op.table_schema, write_op.data, write_op.is_new)
        end
    end
    
    return true
end

-- 异步写入循环
function CMD.async_write_loop()
    while true do
        skynet.sleep(100)  -- 每1秒检查一次
        
        if queue_size > 0 then
            CMD.flush_write_queue()
        end
    end
end

-- 直接操作Redis字段
function CMD.hget(table_name, id, field)
    local table_schema = schema[table_name]
    if not table_schema then
        return nil
    end
    
    local redis_key = table_schema.redis_key(id)
    local value = skynet.call(redis_service, "lua", "hget", redis_key, field)
    
    -- 如果是JSON字段，尝试反序列化
    if value and table_schema.json_fields then
        for _, json_field in ipairs(table_schema.json_fields) do
            if json_field == field then
                local ok, decoded = pcall(cjson.decode, value)
                if ok then
                    return decoded
                end
                break
            end
        end
    end
    
    return value
end

function CMD.hset(table_name, id, field, value)
    local table_schema = schema[table_name]
    if not table_schema then
        return false
    end
    
    local redis_key = table_schema.redis_key(id)
    
    -- 如果是JSON字段，序列化
    local final_value = value
    if table_schema.json_fields then
        for _, json_field in ipairs(table_schema.json_fields) do
            if json_field == field and type(value) == "table" then
                final_value = cjson.encode(value)
                break
            end
        end
    end
    
    return skynet.call(redis_service, "lua", "hset", redis_key, field, tostring(final_value))
end

-- 添加新表定义
function CMD.register_table(table_name, table_schema)
    if not table_schema.redis_key or not table_schema.mysql_table or not table_schema.primary_key then
        return false, "invalid_schema"
    end
    
    schema[table_name] = table_schema
    return true
end

-- 预热缓存
function CMD.warm_up(table_name, ids)
    return CMD.batch_query(table_name, ids, {cache_ttl = config.default_ttl})
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd], string.format("data_cache_v2: unknown command %s", cmd))
        if session == 0 then
            f(...)
        else
            skynet.ret(skynet.pack(f(...)))
        end
    end)
    
    skynet.register(".data_cache_v2")
end)
